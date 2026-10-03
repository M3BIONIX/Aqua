import SwiftUI
import AquaCore

/// A game from either store, as shown in the library.
struct LibraryGame: Identifiable, Hashable {
    enum Source: Hashable {
        case steam(SteamGame)
        case epic(EpicGame)
    }

    let source: Source
    var id: String { "\(store.rawValue):\(storeID)" }
    var store: Store { if case .steam = source { return .steam }; return .epic }
    var storeID: String {
        switch source {
        case .steam(let g): return g.appID
        case .epic(let g): return g.appName
        }
    }
    var title: String {
        switch source {
        case .steam(let g): return g.name
        case .epic(let g): return g.title
        }
    }
    var coverURL: URL? {
        switch source {
        case .steam(let g): return g.coverURL
        case .epic(let g): return g.coverURL
        }
    }
    var heroURL: URL? {
        switch source {
        case .steam(let g): return g.heroURL
        case .epic(let g): return g.heroURL ?? g.coverURL
        }
    }
    var isInstalled: Bool {
        switch source {
        case .steam(let g): return g.state == .installed || g.state == .updateRequired
        case .epic(let g): return g.install != nil
        }
    }
    var installedBytes: Int64 {
        switch source {
        case .steam(let g): return isInstalled ? g.sizeOnDisk : 0
        case .epic(let g): return g.install?.sizeBytes ?? 0
        }
    }
    var isWindowsGame: Bool {
        if case .epic(let g) = source { return g.isWindowsGame }
        return true
    }
}

struct TaskProgress: Equatable {
    var message: String
    var fraction: Double?
}

struct GameActivity: Codable, Equatable {
    var lastPlayed: Date
    var seconds: Double
}

enum Route: Hashable {
    case library
    case downloads
    case settings
    case game(String)
}

enum GameStatus: Equatable {
    case running
    case launching
    case transferring(DownloadItem)
    case waiting(DownloadItem)
    case failed(String)
    case installed
    case notInstalled
}

enum LibraryFilter: String, CaseIterable {
    case all = "All games"
    case installed = "Installed"
    case downloading = "Downloading"
}

enum LibrarySort: String, CaseIterable {
    case recent = "Recently played"
    case name = "Name"
    case size = "Size on disk"
}

@MainActor
final class AppModel: ObservableObject {
    let service = AquaService()
    let downloads = DownloadCenter()

    @Published var route: Route = .library
    @Published var onboardingStep = 1
    @Published var host: HostCheck?
    @Published var runtimeInstalled = false
    @Published var runtimeProgress: TaskProgress?

    @Published var steamInstalled = false
    @Published var steamAccount: String?
    @Published var steamGames: [SteamGame] = []
    @Published var steamProgress: TaskProgress?
    @Published var steamAwaitingSignIn = false
    @Published var steamOwned: [SteamOwnedGame] = []
    @Published var steamLibraryStatus: String?
    @Published var steamLibraryLoading = false
    @Published var hasSteamAPIKey = SteamAPIKey.load() != nil

    @Published var epicAccount: String?
    @Published var epicChecked = false
    @Published var epicGames: [EpicGame] = []
    @Published var epicLoading = false

    @Published var launching: Set<String> = []
    @Published var running: Set<String> = []
    @Published var activity: [String: GameActivity] = [:]

    @Published var settings: AquaSettings
    @Published var errorMessage: String?
    @Published var showEpicLogin = false
    @Published var searchText = ""
    @Published var libraryFilter: LibraryFilter = .all
    @Published var librarySort: LibrarySort = .recent

    private var lastSteamLibraryAttempt = Date.distantPast
    private var steamLibraryIsLive = false
    private var lastPoll = Date()
    private var pollTimer: Timer?

    init() {
        settings = AquaSettings.load()
        if let data = try? Data(contentsOf: service.paths.activityFile),
           let saved = try? JSONDecoder().decode([String: GameActivity].self, from: data) {
            activity = saved
        }
        downloads.model = self
        Task { await refreshAll() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    // MARK: Library

    /// Every owned game from both stores as one library. A game owned on both stores
    /// appears once, preferring the installed copy (then Steam's).
    var allGames: [LibraryGame] {
        let all = steamGames.map { LibraryGame(source: .steam($0)) } + epicGames.map { LibraryGame(source: .epic($0)) }
        var seen: [String: LibraryGame] = [:]
        for game in all {
            let key = Self.normalizedTitle(game.title)
            if let existing = seen[key], existing.isInstalled || !game.isInstalled { continue }
            seen[key] = game
        }
        return Array(seen.values)
    }

    var visibleGames: [LibraryGame] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = allGames.filter { game in
            guard query.isEmpty || game.title.localizedCaseInsensitiveContains(query) else { return false }
            switch libraryFilter {
            case .all: return true
            case .installed: return game.isInstalled
            case .downloading: return downloads.item(for: game.id)?.isPending ?? false
            }
        }
        return filtered.sorted { a, b in
            switch librarySort {
            case .name:
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .size:
                if a.installedBytes != b.installedBytes { return a.installedBytes > b.installedBytes }
            case .recent:
                let da = activity[a.id]?.lastPlayed ?? .distantPast, db = activity[b.id]?.lastPlayed ?? .distantPast
                if da != db { return da > db }
                if a.isInstalled != b.isInstalled { return a.isInstalled }
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// The installed game played most recently, or any installed game if nothing has been played.
    var featuredGame: LibraryGame? {
        let installed = allGames.filter(\.isInstalled)
        return installed.max { (activity[$0.id]?.lastPlayed ?? .distantPast) < (activity[$1.id]?.lastPlayed ?? .distantPast) }
    }

    var largestGame: LibraryGame? { allGames.filter { $0.installedBytes > 0 }.max { $0.installedBytes < $1.installedBytes } }

    static func normalizedTitle(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    func game(id: String) -> LibraryGame? {
        (steamGames.map { LibraryGame(source: .steam($0)) } + epicGames.map { LibraryGame(source: .epic($0)) }).first { $0.id == id }
    }

    func recipe(for game: LibraryGame) -> GameRecipe { service.recipe(for: game.store, id: game.storeID) }

    func status(of game: LibraryGame) -> GameStatus {
        if running.contains(game.id) { return .running }
        if launching.contains(game.id) { return .launching }
        if let item = downloads.item(for: game.id) {
            switch item.state {
            case .downloading, .preparing: return .transferring(item)
            case .queued, .paused: return .waiting(item)
            case .failed(let message): return .failed(message)
            case .finished: break
            }
        }
        return game.isInstalled ? .installed : .notInstalled
    }

    /// Play for installed games, install for the rest.
    func primaryAction(_ game: LibraryGame) {
        switch status(of: game) {
        case .installed: play(game)
        case .notInstalled, .failed: install(game)
        case .transferring, .waiting: route = .downloads
        case .running, .launching: break
        }
    }

    var hasAnyAccount: Bool { steamAccount != nil || epicAccount != nil }

    // MARK: Storage

    var storageUsedBytes: Int64 {
        let root = settings.gamesURL.standardizedFileURL.path
        let steam = steamGames.filter { $0.state != .notInstalled && $0.libraryPath.standardizedFileURL.path.hasPrefix(root) }
            .reduce(Int64(0)) { $0 + $1.sizeOnDisk }
        let epic = epicGames.compactMap(\.install).filter { $0.path.hasPrefix(root) }.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return steam + epic
    }

    var storageLimitBytes: Int64? { settings.storageLimitGB.map { Int64($0) * 1_000_000_000 } }

    func storageAllows(additionalBytes: Int64) -> Bool {
        guard let limit = storageLimitBytes else { return true }
        return storageUsedBytes + additionalBytes <= limit
    }

    var freeBytesAtGamesLocation: Int64 { GamesLocation.freeSpace(settings.gamesURL) }

    // MARK: Refresh

    func refreshAll() async {
        host = await HostCheck.current()
        runtimeInstalled = service.runtime.isInstalled
        refreshSteam()
        if settings.onboarded { ensureRuntime() }
        async let steam: Void = refreshSteamLibrary()
        async let epic: Void = refreshEpic()
        _ = await (steam, epic)
    }

    func refreshSteam() {
        steamInstalled = service.steam.isInstalled
        if steamAccount == nil, service.steam.remembersAccount { steamAccount = service.steam.accountName }
        if steamOwned.isEmpty, let cached = service.steamLibrary.cached() { steamOwned = cached.games }
        steamGames = service.steam.library(owned: steamOwned)
    }

    /// Fetches owned Steam games for the account signed in to Aqua's Steam.
    func refreshSteamLibrary() async {
        lastSteamLibraryAttempt = Date()
        guard service.steam.steamID64 != nil else {
            steamLibraryStatus = service.steam.isInstalled ? "Sign in inside the Steam window to load your library." : nil
            return
        }
        steamLibraryLoading = true
        defer { steamLibraryLoading = false }
        do {
            let result = try await service.steamLibrary.fetch()
            steamOwned = result.games
            steamLibraryIsLive = result.source != .cache
            let via: String
            switch result.source {
            case .webAPI: via = "Steam Web API"
            case .steamClient: via = "Steam client"
            case .publicProfile: via = "public profile"
            case .cache: via = "saved copy, Steam wasn't reachable"
            }
            steamLibraryStatus = "\(result.games.count) games via \(via)"
            refreshSteam()
        } catch {
            steamLibraryStatus = (error as? AquaError)?.message ?? error.localizedDescription
        }
    }

    func refreshLibraries() {
        Task {
            async let steam: Void = refreshSteamLibrary()
            async let epic: Void = refreshEpic(refreshLibrary: true)
            _ = await (steam, epic)
        }
    }

    func saveSteamAPIKey(_ key: String) {
        do {
            try SteamAPIKey.save(key)
            hasSteamAPIKey = SteamAPIKey.load() != nil
            Task { await refreshSteamLibrary() }
        } catch { report(error) }
    }

    func refreshEpic(refreshLibrary: Bool = false) async {
        do {
            if !service.epic.isToolInstalled { try await service.epic.installTool() }
            epicAccount = try await service.epic.status().account
            epicChecked = true
            if epicAccount != nil {
                epicLoading = true
                defer { epicLoading = false }
                epicGames = try await service.epic.library(refresh: refreshLibrary)
            } else {
                epicGames = []
            }
        } catch {
            epicChecked = true
            report(error)
        }
    }

    private func poll() {
        let elapsed = Date().timeIntervalSince(lastPoll)
        lastPoll = Date()
        trackPlaytime(elapsed)
        guard runtimeInstalled, steamInstalled else { return }
        let latest = service.steam.library(owned: steamOwned)
        if latest != steamGames { steamGames = latest }
        if steamAccount == nil || steamAwaitingSignIn {
            Task {
                guard let account = await service.steam.signedInAccount() else { return }
                steamAccount = service.steam.accountName ?? account
                steamAwaitingSignIn = false
                await refreshSteamLibrary()
            }
        } else if !steamLibraryIsLive, !steamLibraryLoading, Date().timeIntervalSince(lastSteamLibraryAttempt) > 30 {
            Task { await refreshSteamLibrary() }
        }
        for game in steamGames where game.state != .notInstalled {
            let id = LibraryGame(source: .steam(game)).id
            if service.steam.isGameRunning(appID: game.appID) { running.insert(id) } else if running.contains(id) { running.remove(id) }
        }
    }

    private func trackPlaytime(_ seconds: TimeInterval) {
        guard !running.isEmpty else { return }
        for id in running {
            var entry = activity[id] ?? GameActivity(lastPlayed: Date(), seconds: 0)
            entry.lastPlayed = Date()
            entry.seconds += seconds
            activity[id] = entry
        }
        saveActivity()
    }

    private func saveActivity() {
        try? JSONEncoder().encode(activity).write(to: service.paths.activityFile, options: .atomic)
    }

    func report(_ error: Error) {
        if error is CancellationError { return }
        errorMessage = (error as? AquaError)?.message ?? error.localizedDescription
        AquaLog.write("error: \(errorMessage ?? "")")
    }

    // MARK: Setup

    /// Installs Wine and the graphics layers in the background. Safe to call repeatedly.
    func ensureRuntime() {
        guard !runtimeInstalled, runtimeProgress == nil, host?.problems.isEmpty ?? false else { return }
        runtimeProgress = TaskProgress(message: "Setting up Aqua", fraction: 0)
        Task {
            do {
                try await installRuntime()
            } catch {
                report(error)
            }
        }
    }

    private func installRuntime() async throws {
        defer { runtimeProgress = nil }
        runtimeProgress = TaskProgress(message: "Setting up Aqua", fraction: 0)
        try await service.runtime.install { p in
            Task { @MainActor in self.runtimeProgress = TaskProgress(message: "Setting up Aqua", fraction: p.fraction) }
        }
        runtimeInstalled = true
    }

    func finishOnboarding() {
        settings.onboarded = true
        saveSettings()
        route = .library
        ensureRuntime()
    }

    // MARK: Steam

    /// Sets up Aqua and Steam if needed, then opens Steam for the user to sign in.
    func connectSteam() {
        guard steamProgress == nil else { return }
        steamProgress = TaskProgress(message: "Preparing…")
        Task {
            defer { steamProgress = nil }
            do {
                if !runtimeInstalled {
                    while runtimeProgress != nil { try await Task.sleep(nanoseconds: 500_000_000) }
                    if !service.runtime.isInstalled {
                        runtimeProgress = TaskProgress(message: "Setting up Aqua", fraction: 0)
                        try await service.runtime.install { p in
                            Task { @MainActor in
                                self.runtimeProgress = TaskProgress(message: "Setting up Aqua", fraction: p.fraction)
                                self.steamProgress = TaskProgress(message: "Setting up Aqua", fraction: p.fraction)
                            }
                        }
                        runtimeProgress = nil
                    }
                    runtimeInstalled = true
                }
                if !service.steam.isInstalled {
                    try await service.steam.install(settings: settings) { message in
                        Task { @MainActor in self.steamProgress = TaskProgress(message: message) }
                    }
                }
                refreshSteam()
                steamProgress = TaskProgress(message: "Opening Steam…")
                try await service.steam.openClient(settings: settings)
                steamAwaitingSignIn = true
            } catch {
                runtimeProgress = nil
                report(error)
            }
        }
    }

    func openSteam() {
        Task {
            do { try await service.steam.openClient(settings: settings) } catch { report(error) }
        }
    }

    func stopSteam() {
        Task {
            do { try await service.steam.bottle.stop(using: service.wine) } catch { report(error) }
            running = running.filter { !$0.hasPrefix("steam:") }
        }
    }

    // MARK: Epic

    func completeEpicLogin(code: String) {
        Task {
            do {
                try await service.epic.login(authorizationCode: code)
                await refreshEpic(refreshLibrary: true)
            } catch {
                report(error)
            }
        }
    }

    func logoutEpic() {
        Task {
            do {
                try await service.epic.logout()
                epicAccount = nil
                epicGames = []
            } catch { report(error) }
        }
    }

    // MARK: Games

    func install(_ game: LibraryGame) {
        AquaLog.write("install \(game.id) (\(game.title)) to \(settings.gamesLocation)")
        guard runtimeInstalled || game.store == .epic else {
            errorMessage = "Aqua is still setting up. Installs can start once that finishes."
            return
        }
        guard storageAllows(additionalBytes: 0) else {
            errorMessage = "The space you set aside for games is full. Raise it in Settings or uninstall a game."
            return
        }
        downloads.enqueue(game)
    }

    func uninstall(_ game: LibraryGame) {
        guard case .epic(let g) = game.source else { return }
        Task {
            do {
                try await service.epic.uninstall(g)
                await refreshEpic()
            } catch { report(error) }
        }
    }

    func play(_ game: LibraryGame) {
        guard !launching.contains(game.id) else { return }
        AquaLog.write("play \(game.id) (\(game.title))")
        launching.insert(game.id)
        activity[game.id, default: GameActivity(lastPlayed: Date(), seconds: 0)].lastPlayed = Date()
        saveActivity()
        let id = game.id
        Task {
            defer { launching.remove(id) }
            do {
                switch game.source {
                case .steam(let g):
                    try await service.launch(steamGame: g)
                case .epic(let g):
                    let process = try await service.launch(epicGame: g)
                    running.insert(id)
                    Task.detached {
                        process.waitUntilExit()
                        await MainActor.run { _ = self.running.remove(id) }
                    }
                }
            } catch {
                report(error)
            }
        }
    }

    func stop(_ game: LibraryGame) {
        Task {
            do {
                switch game.store {
                case .steam: try await service.steam.bottle.stop(using: service.wine)
                case .epic: try await service.epic.stopAll()
                }
                running.remove(game.id)
            } catch { report(error) }
        }
    }

    func setRenderer(_ renderer: Renderer, for game: LibraryGame) {
        do {
            try RecipeBook.saveOverride(GameRecipe(renderer: renderer), store: game.store, id: game.storeID)
            objectWillChange.send()
        } catch { report(error) }
    }

    func chooseGamesLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for Games"
        panel.message = "Choose the folder Aqua installs Steam and Epic games into"
        panel.directoryURL = settings.gamesURL.deletingLastPathComponent()
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.settings.gamesLocation = url.path
            self.saveSettings()
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }

    func saveSettings() {
        do { try settings.save() } catch { report(error) }
    }

    func revealLogs() {
        try? FileManager.default.createDirectory(at: service.paths.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(service.paths.logs)
    }

    func reveal(path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func installPath(of game: LibraryGame) -> String? {
        switch game.source {
        case .epic(let g): return g.install?.path
        case .steam(let g): return game.isInstalled ? g.libraryPath.appendingPathComponent("steamapps/common/\(g.installDir)").path : nil
        }
    }
}
