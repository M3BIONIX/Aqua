import Foundation

public struct SteamGame: Identifiable, Hashable, Sendable {
    public var id: String { appID }
    public let appID: String
    public let name: String
    public let installDir: String
    public let libraryPath: URL
    public let state: State
    public let sizeOnDisk: Int64
    public let bytesDownloaded: Int64
    public let bytesToDownload: Int64

    public enum State: String, Sendable { case installed, downloading, updateRequired, notInstalled, unknown }

    public var downloadFraction: Double? {
        bytesToDownload > 0 ? min(1, Double(bytesDownloaded) / Double(bytesToDownload)) : nil
    }
    public var coverURL: URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_600x900.jpg") }
    public var heroURL: URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_hero.jpg") }
    public var headerURL: URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg") }

    /// Steam "tools" (runtimes, redistributables) that shouldn't appear as games.
    var isTool: Bool {
        ["228980", "1070560", "1391110", "1628350", "1826330", "2180100", "1493710"].contains(appID)
            || name.hasPrefix("Steamworks") || name.hasPrefix("Proton")
    }
}

/// The official Windows Steam client running in Aqua's `steam` bottle.
public final class SteamStore: @unchecked Sendable {
    public let paths: AquaPaths
    public let wine: WineRuntime
    public static let installerURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!

    public init(paths: AquaPaths = .shared, wine: WineRuntime) {
        self.paths = paths
        self.wine = wine
    }

    public var bottle: Bottle { Bottle.forStore(.steam, engine: .default, paths: paths) }
    public var steamDirectory: URL { bottle.driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true) }
    public var steamExe: URL { steamDirectory.appendingPathComponent("steam.exe") }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: steamExe.path) }
    var sessionFile: URL { bottle.root.appendingPathComponent("steam-session.json") }

    /// Chromium in Steam's UI is unstable under Wine with GPU acceleration and its sandbox.
    /// `-cef-enable-debugging` serves Steam's UI on 127.0.0.1:8080 so Aqua can read the library
    /// (see `SteamClientBridge`).
    static let clientArguments = ["-cef-disable-gpu", "-cef-disable-gpu-compositing", "-no-cef-sandbox", "-cef-enable-debugging"]

    public func install(settings: AquaSettings, progress: (@Sendable (String) -> Void)? = nil) async throws {
        try await bottle.prepare(using: wine, progress: progress)
        if isInstalled { return }
        progress?("Downloading Steam installer…")
        let installer = paths.downloads.appendingPathComponent("SteamSetup.exe")
        try? FileManager.default.removeItem(at: installer) // Valve updates it in place; always fetch fresh.
        try await Downloader.fetch(Self.installerURL, to: installer, sha256: nil)
        try await verifyValveSignature(installer)

        progress?("Installing Steam…")
        // Stage on C: so the installer never resolves a Mac path.
        let staged = bottle.driveC.appendingPathComponent("SteamSetup.exe")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: installer, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        var env = wine.environment(bottle: bottle, recipe: .defaults, settings: settings)
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=;mscoree,mshtml="
        try await Shell.run(bottle.wine, [#"C:\SteamSetup.exe"#, "/S"], environment: env, workingDirectory: bottle.driveC,
                            timeout: 600, log: paths.logs.appendingPathComponent("steam-install.log"))
        try await bottle.waitForServer(env)
        guard isInstalled else { throw AquaError("Steam's installer finished but steam.exe is missing. See Logs/steam-install.log.") }
        progress?("Steam installed")
    }

    /// The download is HTTPS from Valve's CDN; additionally require Valve's Authenticode signer
    /// string so a tampered mirror or proxy can't hand us a different program.
    func verifyValveSignature(_ file: URL) async throws {
        let data = try Data(contentsOf: file)
        guard data.count > 1_000_000, data.prefix(2) == Data("MZ".utf8) else { throw AquaError("SteamSetup.exe is not a Windows program.") }
        guard data.range(of: Data("Valve Corp.".utf8)) != nil || data.range(of: Data("Valve Corporation".utf8)) != nil else {
            throw AquaError("SteamSetup.exe isn't signed by Valve. Nothing was installed.")
        }
    }

    // MARK: Account and library

    /// The most recently signed-in account from `config/loginusers.vdf`, keyed by SteamID64.
    var recentLogin: (steamID: String, entry: VDF)? {
        let file = steamDirectory.appendingPathComponent("config/loginusers.vdf")
        guard let text = try? String(contentsOf: file, encoding: .utf8), let vdf = try? VDF.parse(text) else { return nil }
        let users = vdf["users"]?.pairs ?? []
        guard let recent = users.first(where: { $0.1["MostRecent"]?.string == "1" }) ?? users.first else { return nil }
        return (recent.0, recent.1)
    }

    /// The signed-in Steam account name, if any.
    public var accountName: String? {
        guard let entry = recentLogin?.entry else { return nil }
        return entry["PersonaName"]?.string ?? entry["AccountName"]?.string
    }

    /// The signed-in account's 64-bit Steam ID.
    public var steamID64: String? {
        guard let id = recentLogin?.steamID, id.count == 17, id.allSatisfy(\.isNumber) else { return nil }
        return id
    }

    /// Owned games merged with what's installed. Installed manifests win; owned-only games
    /// appear as `.notInstalled`.
    public func library(owned: [SteamOwnedGame]) -> [SteamGame] {
        var byID = Dictionary(installedGames().map { ($0.appID, $0) }, uniquingKeysWith: { a, _ in a })
        for game in owned where byID[game.appID] == nil {
            byID[game.appID] = SteamGame(appID: game.appID, name: game.name, installDir: "", libraryPath: steamDirectory,
                                         state: .notInstalled, sizeOnDisk: 0, bytesDownloaded: 0, bytesToDownload: 0)
        }
        return byID.values.filter { !$0.isTool }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var libraryFolders: [URL] {
        var folders = [steamDirectory]
        let file = steamDirectory.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: file, encoding: .utf8), let vdf = try? VDF.parse(text) {
            for (_, entry) in vdf["libraryfolders"]?.pairs ?? [] {
                guard let path = entry["path"]?.string else { continue }
                let url = path.contains(":") ? bottle.unixPath(forWindowsPath: path) : URL(fileURLWithPath: path)
                if !folders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { folders.append(url) }
            }
        }
        return folders
    }

    public func installedGames() -> [SteamGame] {
        var games: [SteamGame] = []
        for library in libraryFolders {
            let steamapps = library.appendingPathComponent("steamapps")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: steamapps.path)) ?? []
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: steamapps.appendingPathComponent(file), encoding: .utf8),
                      let game = Self.parseManifest(text, library: library), !game.isTool else { continue }
                games.append(game)
            }
        }
        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func parseManifest(_ text: String, library: URL) -> SteamGame? {
        guard let vdf = try? VDF.parse(text), let state = vdf["AppState"], let appID = state["appid"]?.string else { return nil }
        let flags = Int(state["StateFlags"]?.string ?? "0") ?? 0
        let gameState: SteamGame.State
        if flags & 4 != 0 && flags & (2 | 1024 | 1048576) == 0 { gameState = .installed }
        else if flags & (1024 | 1048576) != 0 { gameState = .downloading }
        else if flags & 2 != 0 { gameState = .updateRequired }
        else { gameState = .unknown }
        return SteamGame(
            appID: appID,
            name: state["name"]?.string ?? "App \(appID)",
            installDir: state["installdir"]?.string ?? "",
            libraryPath: library,
            state: gameState,
            sizeOnDisk: Int64(state["SizeOnDisk"]?.string ?? "0") ?? 0,
            bytesDownloaded: Int64(state["BytesDownloaded"]?.string ?? "0") ?? 0,
            bytesToDownload: Int64(state["BytesToDownload"]?.string ?? "0") ?? 0
        )
    }

    // MARK: Running

    /// Opens the Steam client. If it's already running with a different game recipe, it is
    /// restarted (only when no game is running) so games inherit the right environment.
    public func openClient(recipe: GameRecipe = .defaults, settings: AquaSettings, extraArguments: [String] = []) async throws {
        guard isInstalled else { throw AquaError("Install Steam first.") }
        try await bottle.prepareLaunch(recipe: recipe, settings: settings, using: wine)
        if let version = recipe.windowsVersion, !(await bottle.isRunning(using: wine)) {
            try await bottle.setWindowsVersion(version, using: wine)
        }
        var env = wine.environment(bottle: bottle, recipe: recipe, settings: settings)
        // Read by Aqua's engine patch: Steam's UI renders black unless its browser runs single-process.
        env["AQUA_STEAM_CEF_SINGLE_PROCESS"] = "1"
        let sessionKey = WineRuntime.formatOverrides(env.filter { $0.key.hasPrefix("WINE") || $0.key.hasPrefix("D3DM") || $0.key.hasPrefix("MTL") || $0.key.hasPrefix("DXMT") || $0.key.hasPrefix("AQUA_") })

        if await bottle.isRunning(using: wine) {
            let previous = try? String(contentsOf: sessionFile, encoding: .utf8)
            if previous != sessionKey {
                if isGameRunning() {
                    throw AquaError("Close the running game before starting a game with different graphics settings.")
                }
                try await bottle.stop(using: wine)
            }
        }
        try sessionKey.write(to: sessionFile, atomically: true, encoding: .utf8)
        try Shell.spawn(bottle.wine, [steamExe.path] + Self.clientArguments + extraArguments, environment: env,
                        workingDirectory: steamDirectory, log: paths.logs.appendingPathComponent("steam-client.log"))
    }

    public func launch(_ game: SteamGame, recipe: GameRecipe, settings: AquaSettings) async throws {
        var args = ["-applaunch", game.appID]
        args += recipe.arguments ?? []
        try await openClient(recipe: recipe, settings: settings, extraArguments: args)
    }

    static let libraryFolder = "\(Bottle.gamesDrive):\\SteamLibrary"

    /// Installs a game into the games location's SteamLibrary folder. Steam's own install dialog
    /// often fails to appear under Wine, so Aqua drives the install directly; the user already
    /// chose Install in Aqua.
    public func requestInstall(appID: String, settings: AquaSettings) async throws {
        try await openClient(settings: settings)
        try FileManager.default.createDirectory(at: settings.steamLibrary, withIntermediateDirectories: true)
        let bridge = SteamClientBridge()
        try await waitForClient(bridge)
        guard try await isSignedIn(bridge) else {
            throw AquaError("Sign in to Steam first. The Steam window is open; installs start once you're signed in.")
        }
        let folder = try await ensureLibrary(bridge)
        try await startInstall(appID: appID, folder: folder, bridge: bridge)
    }

    func isSignedIn(_ bridge: SteamClientBridge) async throws -> Bool {
        try await bridge.evaluate("!!(window.App && App.m_CurrentUser && App.m_CurrentUser.strAccountName)") as? Bool ?? false
    }

    func startInstall(appID: String, folder: Int, bridge: SteamClientBridge) async throws {
        guard let id = Int(appID) else { throw AquaError("Invalid Steam app ID \(appID).") }
        let script = """
        (async () => {
          SteamClient.Installs.OpenInstallWizard([\(id)]);
          for (let i = 0; i < 40; i++) {
            const info = await SteamClient.Installs.GetInstallManagerInfo();
            if (info.currentAppID === \(id) && info.eAppError) return "error " + info.eAppError;
            if (info.currentAppID === \(id) && info.eInstallState !== 0) {
              SteamClient.Installs.SetInstallFolder(\(folder));
              SteamClient.Installs.ContinueInstall();
              return "started";
            }
            await new Promise(r => setTimeout(r, 500));
          }
          return "timeout";
        })()
        """
        let result = try await bridge.evaluate(script, timeout: 30) as? String ?? ""
        guard result == "started" else { throw AquaError("Steam didn't start the install (\(result)).") }
    }

    public func waitForClient(_ bridge: SteamClientBridge, timeout: TimeInterval = 90) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ready = try? await bridge.evaluate("typeof SteamClient?.InstallFolder?.GetInstallFolders === 'function'") as? Bool, ready { return }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        throw AquaError("Steam is still starting. Try again in a moment.")
    }

    /// Adds the games-location library to Steam, makes it the default install folder, and returns its index.
    func ensureLibrary(_ bridge: SteamClientBridge) async throws -> Int {
        let script = """
        (async () => {
          const want = \(String(reflecting: Self.libraryFolder)).toLowerCase();
          const find = folders => folders.find(f => f.strFolderPath.toLowerCase() === want);
          let folders = await SteamClient.InstallFolder.GetInstallFolders();
          if (!find(folders)) {
            await SteamClient.InstallFolder.AddInstallFolder(\(String(reflecting: Self.libraryFolder)));
            folders = await SteamClient.InstallFolder.GetInstallFolders();
          }
          const library = find(folders);
          if (!library) return null;
          if (!library.bIsDefaultFolder) await SteamClient.InstallFolder.SetDefaultInstallFolder(library.nFolderIndex);
          return library.nFolderIndex;
        })()
        """
        guard let index = try await bridge.evaluate(script) as? Int else { throw AquaError("Steam didn't accept the games library folder.") }
        return index
    }

    /// Steam records game process starts/stops in `logs/gameprocess_log.txt`.
    public func isGameRunning(appID: String? = nil) -> Bool {
        let log = steamDirectory.appendingPathComponent("logs/gameprocess_log.txt")
        guard let handle = try? FileHandle(forReadingFrom: log) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return Self.runningApps(inProcessLog: text).contains { appID == nil || $0 == appID }
    }

    static func runningApps(inProcessLog text: String) -> Set<String> {
        var running: [String: Set<String>] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            if let range = line.range(of: "Remove ") , line.contains("from running list") {
                let appID = String(line[range.upperBound...].prefix { $0.isNumber })
                running[appID] = []
                continue
            }
            let parts = line.components(separatedBy: "AppID ")
            guard parts.count > 1 else { continue }
            let rest = parts[1]
            let appID = String(rest.prefix { $0.isNumber })
            if let range = rest.range(of: "adding PID ") {
                let pid = String(rest[range.upperBound...].prefix { $0.isNumber })
                running[appID, default: []].insert(pid)
            } else if let range = rest.range(of: "no longer tracking PID ") {
                let pid = String(rest[range.upperBound...].prefix { $0.isNumber })
                running[appID]?.remove(pid)
            }
        }
        return Set(running.filter { !$0.value.isEmpty }.keys)
    }
}
