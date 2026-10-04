import SwiftUI
import AquaCore

struct DownloadItem: Identifiable, Equatable {
    enum State: Equatable {
        case preparing(String)
        case downloading
        case queued
        case paused
        case failed(String)
        case finished
    }

    let id: String
    let title: String
    let store: Store
    let storeID: String
    let artURL: URL?
    var state: State
    var fraction: Double = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var networkBytesPerSecond: Double = 0
    var diskBytesPerSecond: Double = 0
    var secondsRemaining: Int?
    var finishedAt: Date?
    var order: Int
    /// Bytes finished before the current legendary run; a resumed run reports only what's left.
    var resumedBytes: Int64 = 0

    var isTransferring: Bool {
        switch state {
        case .downloading, .preparing: return true
        default: return false
        }
    }

    var isPending: Bool {
        switch state {
        case .finished, .failed: return false
        default: return true
        }
    }
}

struct ThroughputSample {
    let time: Date
    let network: Double
    let disk: Double
}

/// Every download in one queue. Epic downloads run through legendary one at a time and are
/// paused by stopping legendary, which resumes from its own resume data. Steam downloads stay
/// in Steam's queue and are mirrored here and controlled through the running client.
@MainActor
final class DownloadCenter: ObservableObject {
    @Published private(set) var items: [DownloadItem] = [] {
        didSet { saveQueueIfChanged() }
    }
    @Published private(set) var samples: [ThroughputSample] = []
    @Published private(set) var sessionBytes: Double = 0

    weak var model: AppModel?
    private var service: AquaService { model!.service }
    private var epicTask: Task<Void, Never>?
    private var epicActiveID: String?
    private var nextOrder = 0
    private var steamState = SteamDownloadState.empty
    private var steamPolling = false
    private var steamReachable = false
    private var timer: Timer?
    private static let sampleLimit = 6 * 3600

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var pending: [DownloadItem] { items.filter(\.isPending) }
    var active: DownloadItem? { items.first { $0.isTransferring } ?? items.first { $0.state == .paused } }
    var isAnyTransferring: Bool { items.contains(where: \.isTransferring) }

    func item(for id: String) -> DownloadItem? { items.first { $0.id == id } }

    /// Most recent first after the pending ones, so the queue reads top to bottom.
    var ordered: [DownloadItem] {
        items.sorted { a, b in
            func rank(_ item: DownloadItem) -> Int {
                switch item.state {
                case .downloading, .preparing: return 0
                case .queued: return 1
                case .paused: return 2
                case .failed: return 3
                case .finished: return 4
                }
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.state == .finished { return (a.finishedAt ?? .distantPast) > (b.finishedAt ?? .distantPast) }
            return a.order < b.order
        }
    }

    // MARK: Adding

    func enqueue(_ game: LibraryGame, paused: Bool = false) {
        if let existing = item(for: game.id), existing.isPending { return }
        items.removeAll { $0.id == game.id }
        nextOrder += 1
        let art: URL?
        switch game.source {
        case .local: return
        case .steam(let g): art = g.headerURL
        case .epic(let g): art = g.heroURL ?? g.coverURL
        }
        let starting: DownloadItem.State = paused ? .paused : (game.store == .steam ? .preparing("Starting Steam…") : .queued)
        items.append(DownloadItem(id: game.id, title: game.title, store: game.store, storeID: game.storeID, artURL: art,
                                  state: starting, order: nextOrder))
        AquaLog.write("download queued \(game.id)")
        if paused { return }
        switch game.source {
        case .local: return
        case .epic: pumpEpic()
        case .steam(let g): startSteam(g, id: game.id)
        }
    }

    // MARK: Controls

    func pause(_ id: String) {
        guard let item = item(for: id) else { return }
        switch item.store {
        case .local: return
        case .epic:
            update(id) { $0.state = .paused; $0.networkBytesPerSecond = 0; $0.diskBytesPerSecond = 0 }
            if epicActiveID == id { epicTask?.cancel() }
        case .steam:
            update(id) { $0.state = .paused; $0.networkBytesPerSecond = 0; $0.diskBytesPerSecond = 0 }
            steamCommand { try await $0.pauseDownload(appID: item.storeID) }
        }
    }

    func resume(_ id: String) {
        guard let item = item(for: id) else { return }
        switch item.store {
        case .local: return
        case .epic:
            update(id) { $0.state = .queued }
            pumpEpic()
        case .steam:
            update(id) { $0.state = .queued }
            steamCommand(openingSteam: true) { try await $0.resumeDownload(appID: item.storeID) }
        }
    }

    func startNow(_ id: String) {
        guard let item = item(for: id) else { return }
        nextOrder += 1
        update(id) { $0.order = -nextOrder; if $0.state == .paused { $0.state = .queued } }
        switch item.store {
        case .local: return
        case .epic:
            if let current = epicActiveID, current != id {
                update(current) { $0.state = .queued; $0.networkBytesPerSecond = 0; $0.diskBytesPerSecond = 0 }
                epicTask?.cancel()
            } else {
                pumpEpic()
            }
        case .steam:
            steamCommand(openingSteam: true) { try await $0.prioritizeDownload(appID: item.storeID) }
        }
    }

    func cancel(_ id: String) {
        guard let item = item(for: id) else { return }
        items.removeAll { $0.id == id }
        switch item.store {
        case .local: return
        case .epic: if epicActiveID == id { epicTask?.cancel() }
        case .steam: steamCommand { try await $0.cancelDownload(appID: item.storeID) }
        }
        AquaLog.write("download cancelled \(id)")
    }

    func pauseAll() { for item in items where item.isPending && item.state != .paused { pause(item.id) } }
    func resumeAll() { for item in items where item.state == .paused { resume(item.id) } }
    func clearFinished() { items.removeAll { !$0.isPending } }

    // MARK: Across launches

    private struct SavedDownload: Codable, Equatable {
        let id: String
        let paused: Bool
    }

    private var queueFile: URL? { model?.service.paths.root.appendingPathComponent("downloads.json") }
    private var savedQueue: [SavedDownload] = []

    /// Unfinished Epic downloads, so the next launch can pick them up.
    private func saveQueueIfChanged() {
        let queue = items.filter { $0.store == .epic && $0.isPending }
            .sorted { $0.order < $1.order }
            .map { SavedDownload(id: $0.id, paused: $0.state == .paused) }
        guard queue != savedQueue, let queueFile else { return }
        savedQueue = queue
        try? JSONEncoder().encode(queue).write(to: queueFile, options: .atomic)
    }

    /// Picks up Epic downloads from the last session: the saved queue, plus any legendary
    /// download left running without Aqua, which is stopped and continued here instead.
    func restore() async {
        guard let model, let queueFile else { return }
        var queue = (try? Data(contentsOf: queueFile)).flatMap { try? JSONDecoder().decode([SavedDownload].self, from: $0) } ?? []
        let downloads = await stopOrphanedEpicDownloads()
        for app in downloads.stopped where !queue.contains(where: { $0.id == "epic:\(app)" }) {
            queue.append(SavedDownload(id: "epic:\(app)", paused: false))
        }
        for saved in queue where !downloads.busy.contains(where: { saved.id == "epic:\($0)" }) {
            guard let game = model.game(id: saved.id), !game.isInstalled else { continue }
            AquaLog.write("resuming download from last session \(saved.id)")
            enqueue(game, paused: saved.paused)
        }
    }

    /// legendary downloads whose Aqua has gone (their parent is launchd). Interrupting legendary
    /// makes it save its resume data, so the download continues from where it was.
    /// `busy` are downloads another running Aqua owns; those are left alone.
    private func stopOrphanedEpicDownloads() async -> (stopped: [String], busy: [String]) {
        guard let legendary = model?.service.paths.legendary.path,
              let output = try? await Shell.run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,ppid=,command="]).output else { return ([], []) }
        var apps: [String] = []
        var busy: [String] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), fields[2].hasPrefix(legendary + " -y install ") else { continue }
            let app = fields[2].dropFirst(legendary.count + " -y install ".count).split(separator: " ").first.map(String.init) ?? ""
            guard !app.isEmpty else { continue }
            guard fields[1] == "1" else { busy.append(app); continue }
            AquaLog.write("stopping leftover legendary download \(app) (pid \(pid))")
            kill(pid, SIGINT)
            for _ in 0..<40 where kill(pid, 0) == 0 { try? await Task.sleep(nanoseconds: 250_000_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGTERM) }
            apps.append(app)
        }
        return (apps, busy)
    }

    /// Called when Aqua quits: stop legendary so it never keeps downloading without Aqua.
    func stopForQuit() {
        saveQueueIfChanged()
        epicTask?.cancel()
    }

    // MARK: Epic

    private func pumpEpic() {
        guard epicActiveID == nil,
              let next = items.filter({ $0.store == .epic && $0.state == .queued }).min(by: { $0.order < $1.order }),
              let game = model?.game(id: next.id), case .epic(let epicGame) = game.source else { return }
        let id = next.id
        epicActiveID = id
        update(id) { $0.state = .preparing("Preparing download…") }
        let settings = model!.settings
        epicTask = Task {
            do {
                try await service.epic.install(epicGame, settings: settings) { progress in
                    Task { @MainActor in self.apply(progress, to: id) }
                }
                update(id) { $0.state = .finished; $0.fraction = 1; $0.finishedAt = Date(); $0.networkBytesPerSecond = 0; $0.diskBytesPerSecond = 0 }
                AquaLog.write("download finished \(id)")
                await model?.refreshEpic()
            } catch {
                // Pausing, reprioritising and cancelling stop legendary on purpose.
                if let item = item(for: id), item.state != .paused, item.state != .queued {
                    let message = (error as? AquaError)?.message ?? error.localizedDescription
                    update(id) { $0.state = .failed(message.components(separatedBy: "\n").first ?? message) }
                    AquaLog.write("download failed \(id): \(message)")
                }
            }
            epicActiveID = nil
            epicTask = nil
            pumpEpic()
        }
    }

    private func apply(_ progress: EpicInstallProgress, to id: String) {
        guard let item = item(for: id), item.isTransferring else { return }
        if let size = progress.installBytes, let model, !model.storageAllows(additionalBytes: size) {
            update(id) { $0.state = .failed("Not enough room in the space you set aside for games") }
            epicTask?.cancel()
            return
        }
        update(id) { item in
            item.state = progress.fraction > 0 || progress.speedMiBps != nil ? .downloading : .preparing(progress.message)
            if let remaining = progress.downloadBytes {
                if item.bytesTotal < remaining { item.bytesTotal = remaining }
                item.resumedBytes = item.bytesTotal - remaining
            }
            if item.bytesTotal > 0 {
                let remaining = item.bytesTotal - item.resumedBytes
                item.bytesDone = item.resumedBytes + Int64(Double(remaining) * progress.fraction)
                item.fraction = Double(item.bytesDone) / Double(item.bytesTotal)
            } else {
                item.fraction = progress.fraction
            }
            item.networkBytesPerSecond = (progress.speedMiBps ?? 0) * 1_048_576
            item.diskBytesPerSecond = (progress.diskMiBps ?? 0) * 1_048_576
            item.secondsRemaining = progress.eta.flatMap(Self.seconds)
        }
    }

    static func seconds(_ eta: String) -> Int? {
        let parts = eta.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    // MARK: Steam

    private func startSteam(_ game: SteamGame, id: String) {
        guard let model else { return }
        let settings = model.settings
        if !model.storageAllows(additionalBytes: 0) {
            update(id) { $0.state = .failed("The space you set aside for games is full") }
            return
        }
        Task {
            do {
                try await service.steam.requestInstall(appID: game.appID, settings: settings)
                update(id) { if case .preparing = $0.state { $0.state = .queued } }
                AquaLog.write("steam install started \(game.appID)")
            } catch {
                items.removeAll { $0.id == id }
                model.report(error)
            }
        }
    }

    private func steamCommand(openingSteam: Bool = false, _ command: @escaping (SteamStore) async throws -> Void) {
        guard let model else { return }
        let steam = service.steam
        let settings = model.settings
        Task {
            do {
                if openingSteam, !(await SteamClientBridge().isAvailable) {
                    try await steam.openClient(settings: settings)
                    try await steam.waitForClient(SteamClientBridge())
                }
                try await command(steam)
            } catch {
                model.report(error)
            }
        }
    }

    /// Mirrors Steam's queue: games Steam lists, plus any whose manifest shows a pending download.
    private func syncSteam() {
        guard let model else { return }
        let manifests = Dictionary(model.steamGames.map { ($0.appID, $0) }, uniquingKeysWith: { a, _ in a })
        var pendingIDs = Set(steamState.items.filter { !$0.completed }.map(\.appID))
        for game in model.steamGames where game.state == .downloading { pendingIDs.insert(game.appID) }
        if let active = steamState.activeAppID { pendingIDs.insert(active) }

        for appID in pendingIDs {
            let id = "steam:\(appID)"
            let manifest = manifests[appID]
            if item(for: id) == nil {
                guard let manifest else { continue }
                nextOrder += 1
                items.append(DownloadItem(id: id, title: manifest.name, store: .steam, storeID: appID, artURL: manifest.headerURL,
                                          state: .queued, order: nextOrder))
            }
            let queueEntry = steamState.items.first { $0.appID == appID }
            let isActive = steamState.activeAppID == appID && !steamState.paused
            update(id) { item in
                if let manifest, manifest.bytesToDownload > 0 {
                    item.bytesDone = manifest.bytesDownloaded
                    item.bytesTotal = manifest.bytesToDownload
                    item.fraction = manifest.downloadFraction ?? item.fraction
                }
                if isActive {
                    if steamState.bytesTotal > 0 {
                        item.bytesDone = steamState.bytesDone
                        item.bytesTotal = steamState.bytesTotal
                        item.fraction = Double(steamState.bytesDone) / Double(steamState.bytesTotal)
                    }
                    item.networkBytesPerSecond = steamState.networkBytesPerSecond
                    item.diskBytesPerSecond = steamState.diskBytesPerSecond
                    item.secondsRemaining = steamState.secondsRemaining
                    item.state = .downloading
                } else {
                    item.networkBytesPerSecond = 0
                    item.diskBytesPerSecond = 0
                    item.secondsRemaining = nil
                    if case .preparing = item.state { return }
                    let paused = !steamReachable || (queueEntry?.paused ?? false) || item.state == .paused
                    item.state = paused ? .paused : .queued
                }
            }
        }

        // Steam items that left the queue: finished if installed, otherwise Steam dropped them.
        for item in items where item.store == .steam && item.isPending && !pendingIDs.contains(item.storeID) {
            if case .preparing = item.state { continue }
            if manifests[item.storeID]?.state == .installed {
                update(item.id) { $0.state = .finished; $0.fraction = 1; $0.finishedAt = Date(); $0.networkBytesPerSecond = 0; $0.diskBytesPerSecond = 0 }
            } else if !steamPolling {
                items.removeAll { $0.id == item.id }
            }
        }
    }

    private func pollSteam() {
        guard let model, !steamPolling, model.steamInstalled else { return }
        let hasWork = items.contains { $0.store == .steam && $0.isPending } || model.steamGames.contains { $0.state == .downloading }
        guard hasWork else { return }
        steamPolling = true
        let steam = service.steam
        Task {
            let state = try? await steam.downloadState()
            steamReachable = state != nil
            steamState = state ?? .empty
            steamPolling = false
            syncSteam()
        }
    }

    // MARK: Sampling

    private func tick() {
        pollSteam()
        let network = items.filter(\.isTransferring).reduce(0) { $0 + $1.networkBytesPerSecond }
        let disk = items.filter(\.isTransferring).reduce(0) { $0 + $1.diskBytesPerSecond }
        sessionBytes += network
        samples.append(ThroughputSample(time: Date(), network: network, disk: disk))
        if samples.count > Self.sampleLimit { samples.removeFirst(samples.count - Self.sampleLimit) }
    }

    private func update(_ id: String, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        change(&item)
        if item != items[index] { items[index] = item }
    }
}
