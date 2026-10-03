import Foundation

public struct EpicGame: Identifiable, Hashable, Sendable {
    public var id: String { appName }
    public let appName: String
    public let title: String
    public let developer: String?
    /// Tall cover art (DieselGameBoxTall) if Epic provides one.
    public let coverURL: URL?
    /// Wide hero art (DieselGameBox).
    public let heroURL: URL?
    public let isWindowsGame: Bool
    public var install: EpicInstall?
}

public struct EpicInstall: Hashable, Sendable {
    public let path: String
    public let executable: String
    public let version: String
    public let sizeBytes: Int64
}

public struct EpicInstallProgress: Sendable {
    public var fraction: Double
    public var downloadedMiB: Double?
    public var speedMiBps: Double?
    public var diskMiBps: Double?
    /// Bytes left to download in this run (less than the full size when resuming).
    public var downloadBytes: Int64?
    /// Size of the installed game.
    public var installBytes: Int64?
    public var eta: String?
    public var message: String

    public init(fraction: Double, message: String) {
        self.fraction = fraction
        self.message = message
    }
}

/// Epic Games Store through legendary (https://github.com/derrod/legendary, GPLv3).
/// legendary is downloaded on first use and runs as a separate program with its own
/// config directory inside Aqua's data folder.
public final class EpicStore: @unchecked Sendable {
    public let paths: AquaPaths
    public let wine: WineRuntime

    /// Epic's login page. After sign-in it shows JSON containing `authorizationCode`.
    public static let loginURL = URL(string: "https://www.epicgames.com/id/login?redirectUrl=https%3A%2F%2Fwww.epicgames.com%2Fid%2Fapi%2Fredirect%3FclientId%3D34a02cf8f4414e29b15921876da36f9a%26responseType%3Dcode")!

    public init(paths: AquaPaths = .shared, wine: WineRuntime) {
        self.paths = paths
        self.wine = wine
    }

    public func bottle(for engine: WineEngine) -> Bottle { Bottle.forStore(.epic, engine: engine, paths: paths) }

    /// Every Epic bottle that exists, for stopping all Epic games.
    public var bottles: [Bottle] {
        WineEngine.allCases.map(bottle(for:)).filter { FileManager.default.fileExists(atPath: $0.prefix.path) }
    }

    public func stopAll() async throws {
        for bottle in bottles { try await bottle.stop(using: wine) }
    }
    public var isToolInstalled: Bool { FileManager.default.isExecutableFile(atPath: paths.legendary.path) }

    public func installTool(progress: Downloader.Progress? = nil) async throws {
        if isToolInstalled { return }
        let component = RuntimeComponents.legendary
        let file = paths.downloads.appendingPathComponent(component.fileName)
        try await Downloader.fetch(component.url, to: file, sha256: component.sha256, progress: progress)
        try paths.ensure(paths.tools)
        try? FileManager.default.removeItem(at: paths.legendary)
        try FileManager.default.copyItem(at: file, to: paths.legendary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.legendary.path)
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-d", "com.apple.quarantine", paths.legendary.path], allowedStatus: [0, 1])
    }

    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LEGENDARY_CONFIG_PATH"] = paths.legendaryConfig.path
        return env
    }

    /// legendary defaults to the Mac platform on macOS, which would hide every Windows-only game.
    /// Aqua's private legendary config pins Windows and turns off legendary's own update nags.
    func writeConfig() throws {
        try paths.ensure(paths.legendaryConfig)
        let file = paths.legendaryConfig.appendingPathComponent("config.ini")
        var lines = (try? String(contentsOf: file, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        // On macOS legendary also auto-detects CrossOver for launches and crashes if none is installed.
        let wanted = ["default_platform": "Windows", "disable_update_check": "true", "disable_update_notice": "true",
                      "disable_auto_crossover": "true"]
        var section = lines.firstIndex(of: "[Legendary]")
        if section == nil { lines.insert(contentsOf: ["[Legendary]", ""], at: 0); section = 0 }
        for (key, value) in wanted.sorted(by: { $0.key < $1.key }) {
            if let index = lines.firstIndex(where: { $0.replacingOccurrences(of: " ", with: "").hasPrefix(key + "=") }) {
                lines[index] = "\(key) = \(value)"
            } else {
                lines.insert("\(key) = \(value)", at: section! + 1)
            }
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func legendary(_ args: [String], timeout: TimeInterval? = 120, onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await installTool()
        try writeConfig()
        // JSON goes to stdout; legendary's log lines go to stderr.
        return try await Shell.run(paths.legendary, args, environment: environment, timeout: timeout,
                                   log: paths.logs.appendingPathComponent("legendary.log"),
                                   separateErrors: true, onLine: onLine).output
    }

    /// Decodes legendary's JSON output, tolerating stray lines around it.
    static func jsonPayload(_ output: String) throws -> Any {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) { return value }
        // Fall back to the first line that starts a JSON document through the last line that closes one.
        let lines = trimmed.components(separatedBy: "\n")
        for first in lines.indices where lines[first].hasPrefix("{") || lines[first].hasPrefix("[") {
            for last in stride(from: lines.count - 1, through: first, by: -1) where lines[last].hasSuffix("}") || lines[last].hasSuffix("]") {
                let candidate = lines[first...last].joined(separator: "\n")
                if let value = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) { return value }
            }
        }
        throw AquaError("legendary returned no JSON.\n\(output.suffix(800))")
    }

    // MARK: Account

    public struct Status: Sendable {
        public let account: String?
        public let gamesAvailable: Int
        public let gamesInstalled: Int
    }

    public func status() async throws -> Status {
        let json = try Self.jsonPayload(try await legendary(["status", "--json", "--offline"])) as? [String: Any] ?? [:]
        let account = json["account"] as? String
        let loggedIn = account.map { !$0.isEmpty && !$0.contains("not logged in") } ?? false
        return Status(account: loggedIn ? account : nil,
                      gamesAvailable: json["games_available"] as? Int ?? 0,
                      gamesInstalled: json["games_installed"] as? Int ?? 0)
    }

    /// Accepts either the raw authorization code or the whole JSON page Epic shows after login.
    public func login(authorizationCode input: String) async throws {
        var code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.hasPrefix("{"), let data = code.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let extracted = json["authorizationCode"] as? String {
            code = extracted
        }
        guard !code.isEmpty, code.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw AquaError("That doesn't look like an Epic authorization code.")
        }
        let output = try await legendary(["auth", "--code", code])
        guard try await status().account != nil else {
            throw AquaError("Epic sign-in failed.\n\(output.suffix(600))")
        }
    }

    public func logout() async throws {
        try await legendary(["auth", "--delete"])
    }

    // MARK: Library

    public func library(refresh: Bool = false) async throws -> [EpicGame] {
        var args = ["list", "--json", "--platform", "Windows"]
        if refresh { args.append("--force-refresh") }
        let owned = try Self.jsonPayload(try await legendary(args, timeout: 300)) as? [[String: Any]] ?? []
        let installed = try await installedGames()
        return owned.compactMap { item -> EpicGame? in
            guard let appName = item["app_name"] as? String else { return nil }
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            let images = metadata["keyImages"] as? [[String: Any]] ?? []
            func image(_ types: [String]) -> URL? {
                for type in types {
                    if let url = images.first(where: { $0["type"] as? String == type })?["url"] as? String {
                        return URL(string: url)
                    }
                }
                return nil
            }
            let assets = item["asset_infos"] as? [String: Any] ?? [:]
            let platforms = (metadata["releaseInfo"] as? [[String: Any]])?.flatMap { $0["platform"] as? [String] ?? [] } ?? []
            return EpicGame(
                appName: appName,
                title: item["app_title"] as? String ?? metadata["title"] as? String ?? appName,
                developer: metadata["developer"] as? String,
                coverURL: image(["DieselGameBoxTall", "OfferImageTall", "Thumbnail"]),
                heroURL: image(["DieselGameBox", "OfferImageWide", "DieselStoreFrontWide"]),
                isWindowsGame: assets["Windows"] != nil || platforms.contains("Windows"),
                install: installed[appName]
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func installedGames() async throws -> [String: EpicInstall] {
        let list = try Self.jsonPayload(try await legendary(["list-installed", "--json"])) as? [[String: Any]] ?? []
        var result: [String: EpicInstall] = [:]
        for item in list {
            guard let appName = item["app_name"] as? String, let path = item["install_path"] as? String else { continue }
            result[appName] = EpicInstall(
                path: path,
                executable: item["executable"] as? String ?? "",
                version: item["version"] as? String ?? "",
                sizeBytes: (item["install_size"] as? NSNumber)?.int64Value ?? 0
            )
        }
        return result
    }

    // MARK: Install

    static func parseProgress(_ line: String, into progress: inout EpicInstallProgress) -> Bool {
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: line).map { String(line[$0]) } }
        }
        if let m = match(#"Progress: ([0-9.]+)% \((\d+)/(\d+)\), Running for [0-9:]+, ETA: ([0-9:]+)"#) {
            progress.fraction = (Double(m[0]) ?? 0) / 100
            progress.eta = m[3]
            progress.message = "Downloading…"
            return true
        }
        if let m = match(#"Downloaded: ([0-9.]+) MiB"#) {
            progress.downloadedMiB = Double(m[0]); return true
        }
        if let m = match(#"\+ Download\s+- ([0-9.]+) MiB/s"#) {
            progress.speedMiBps = Double(m[0]); return true
        }
        if let m = match(#"\+ Disk\s+- ([0-9.]+) MiB/s"#) {
            progress.diskMiBps = Double(m[0]); return true
        }
        if let m = match(#"(Download|Install) size: ([0-9.]+) (KiB|MiB|GiB|TiB)"#) {
            let units: [String: Double] = ["KiB": 1024, "MiB": 1_048_576, "GiB": 1_073_741_824, "TiB": 1_099_511_627_776]
            let scale = units[m[2]] ?? 1
            let bytes = Int64((Double(m[1]) ?? 0) * scale)
            if m[0] == "Download" { progress.downloadBytes = bytes } else { progress.installBytes = bytes }
            return true
        }
        if line.contains("Finished installation") || line.contains("Verifying") || line.contains("Preparing download") {
            progress.message = line.components(separatedBy: "INFO: ").last ?? line
            return true
        }
        return false
    }

    public func install(_ game: EpicGame, settings: AquaSettings,
                        progress: @escaping @Sendable (EpicInstallProgress) -> Void) async throws {
        let base = settings.epicInstallBase
        try paths.ensure(base)
        let state = ProgressBox(EpicInstallProgress(fraction: 0, message: "Preparing download…"))
        progress(state.value)
        do {
            try await legendary(["-y", "install", game.appName, "--base-path", base.path, "--platform", "Windows",
                                 "--skip-sdl", "--skip-dlcs"], timeout: nil) { line in
                var current = state.value
                if Self.parseProgress(line, into: &current) {
                    state.value = current
                    progress(current)
                }
            }
        } catch let error as AquaError {
            throw Self.installFailure(error.message) ?? error
        }
        guard try await installedGames()[game.appName] != nil else {
            throw AquaError("\(game.title) didn't finish installing. Check the legendary log in Aqua's Logs folder.")
        }
        progress(EpicInstallProgress(fraction: 1, message: "Installed"))
    }

    /// legendary's own reason for refusing an install, e.g. "Not enough available disk space! 18 GiB < 63 GiB".
    static func installFailure(_ output: String) -> AquaError? {
        guard let line = output.components(separatedBy: "\n").first(where: { $0.contains("! Failure:") }),
              let range = line.range(of: "Failure:") else { return nil }
        return AquaError(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    public func uninstall(_ game: EpicGame) async throws {
        try await legendary(["-y", "uninstall", game.appName], timeout: 600)
    }

    // MARK: Launch

    public struct LaunchPlan: Sendable {
        public let executable: String
        public let workingDirectory: String
        public let arguments: [String]
        public let environment: [String: String]
    }

    /// Asks legendary for the launch command (including a fresh Epic auth token) without running it.
    public func launchPlan(_ game: EpicGame, engine: WineEngine = .default) async throws -> LaunchPlan {
        // Name Aqua's Wine so legendary never goes looking for CrossOver; Aqua builds the command itself.
        let json = try Self.jsonPayload(try await legendary(["launch", game.appName, "--json", "--wine", paths.wine(engine).path])) as? [String: Any] ?? [:]
        guard let exe = json["game_executable"] as? String, !exe.isEmpty else {
            throw AquaError("legendary didn't return a game executable for \(game.title).")
        }
        let directory = json["game_directory"] as? String ?? (exe as NSString).deletingLastPathComponent
        let working = json["working_directory"] as? String ?? directory
        let fullExe = exe.hasPrefix("/") ? exe : (directory as NSString).appendingPathComponent(exe)
        let args = (json["game_parameters"] as? [String] ?? [])
            + (json["egl_parameters"] as? [String] ?? [])
            + (json["user_parameters"] as? [String] ?? [])
        // legendary adds CrossOver's CX_BOTTLE on macOS; Aqua runs its own Wine.
        let environment = (json["environment"] as? [String: String] ?? [:]).filter { !$0.key.hasPrefix("CX_") }
        return LaunchPlan(executable: fullExe, workingDirectory: working, arguments: args, environment: environment)
    }

    @discardableResult
    public func launch(_ game: EpicGame, recipe: GameRecipe, settings: AquaSettings) async throws -> Process {
        let bottle = bottle(for: recipe.engine ?? .default)
        try await bottle.prepareLaunch(recipe: recipe, settings: settings, using: wine)
        let plan = try await launchPlan(game, engine: bottle.engine)
        if let version = recipe.windowsVersion { try await bottle.setWindowsVersion(version, using: wine) }
        var env = wine.environment(bottle: bottle, recipe: recipe, settings: settings)
        env.merge(plan.environment) { $1 }
        let log = paths.logs.appendingPathComponent("epic-\(game.appName).log")
        return try Shell.spawn(bottle.wine, [plan.executable] + plan.arguments + (recipe.arguments ?? []),
                               environment: env, workingDirectory: URL(fileURLWithPath: plan.workingDirectory), log: log)
    }
}

final class ProgressBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
