import Foundation

/// A Wine prefix plus Aqua's bookkeeping: one per store and engine (`steam`, `epic`, `epic-crossover`).
public struct Bottle: Sendable, Hashable {
    public let name: String
    public let paths: AquaPaths

    public init(name: String, paths: AquaPaths = .shared) {
        self.name = name
        self.paths = paths
    }

    public static func forStore(_ store: Store, engine: WineEngine, paths: AquaPaths = .shared) -> Bottle {
        Bottle(name: store.rawValue + engine.bottleSuffix, paths: paths)
    }

    public var engine: WineEngine { WineEngine.of(bottleName: name) }
    public var wine: URL { paths.wine(engine) }
    public var wineserver: URL { paths.wineserver(engine) }

    public static func == (lhs: Bottle, rhs: Bottle) -> Bool { lhs.root == rhs.root }
    public func hash(into hasher: inout Hasher) { hasher.combine(root) }

    public var root: URL { paths.bottle(name) }
    public var prefix: URL { root.appendingPathComponent("prefix", isDirectory: true) }
    public var driveC: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }
    var readyMarker: URL { root.appendingPathComponent("ready.json") }
    var rendererMarker: URL { root.appendingPathComponent("renderer.txt") }
    var windowsVersionMarker: URL { root.appendingPathComponent("windows-version.txt") }
    var retinaMarker: URL { root.appendingPathComponent("retina.txt") }

    public var isReady: Bool { FileManager.default.fileExists(atPath: readyMarker.path) }

    /// Converts a Windows path (`C:\...`, `D:\...`) into its Mac location using the bottle's drive links.
    public func unixPath(forWindowsPath path: String) -> URL {
        var relative = path.replacingOccurrences(of: "\\", with: "/")
        guard relative.count >= 2, relative.dropFirst().first == ":" else { return driveC.appendingPathComponent(relative) }
        let letter = relative.prefix(1).lowercased()
        relative.removeFirst(min(3, relative.count))
        let link = prefix.appendingPathComponent("dosdevices/\(letter):")
        let root = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
            .map { URL(fileURLWithPath: $0, relativeTo: link.deletingLastPathComponent()).standardizedFileURL } ?? driveC
        return root.appendingPathComponent(relative)
    }

    /// Drive letter for the games location. Wine assigns newly mounted Mac volumes letters from
    /// D: upward and would take over a low letter, so this one sits far above them.
    public static let gamesDrive: Character = "S"

    /// Points a Windows drive letter at a Mac folder.
    public func mapDrive(_ letter: Character, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = prefix.appendingPathComponent("dosdevices/\(letter.lowercased()):")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == folder.path { return }
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: folder.path)
    }

    private func log(_ name: String) -> URL { paths.logs.appendingPathComponent("bottle-\(self.name)-\(name).log") }

    /// Creates the Windows environment once. Safe to call before every launch.
    public func prepare(using runtime: WineRuntime, progress: (@Sendable (String) -> Void)? = nil) async throws {
        if isReady { try restoreBuiltinGraphicsDLLs(); return }
        try paths.ensure(root)
        var env = runtime.environment(bottle: self, recipe: .defaults, settings: AquaSettings())
        // No renderer DLLs exist yet; let wineboot use Wine's own.
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=;mscoree,mshtml="

        progress?("Creating Windows environment…")
        try await Shell.run(wine, ["wineboot", "--init"], environment: env, timeout: 300, log: log("setup"))
        try await waitForServer(env)
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
            throw AquaError("Wine didn't finish creating the Windows environment. See \(log("setup").path).")
        }

        // Wine links Documents, Desktop etc. to the Mac home folder. Keep games' files inside the bottle.
        let users = driveC.appendingPathComponent("users")
        for user in (try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            for item in (try? FileManager.default.contentsOfDirectory(at: user, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
            where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try FileManager.default.removeItem(at: item)
                try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
            }
        }

        progress?("Configuring Windows…")
        try await setWindowsVersion("win10", using: runtime, force: true)
        // Controllers through SDL (the engine's winebus), like CrossOver.
        for key in ["Enable SDL", "Map Controllers"] {
            try await reg(["add", #"HKLM\System\CurrentControlSet\Services\WineBus"#, "/v", key, "/t", "REG_DWORD", "/d", "1", "/f"], using: runtime)
        }
        try await waitForServer(runtime.baseEnvironment(engine: engine).merging(["WINEPREFIX": prefix.path]) { $1 })

        try JSONEncoder().encode(["created": ISO8601DateFormatter().string(from: Date()), "engine": engine.component.version])
            .write(to: readyMarker, options: .atomic)
        progress?("Windows environment ready")
    }

    func reg(_ args: [String], using runtime: WineRuntime) async throws {
        var env = runtime.baseEnvironment(engine: engine)
        env["WINEPREFIX"] = prefix.path
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=;mscoree,mshtml="
        try await Shell.run(wine, ["reg"] + args, environment: env, timeout: 120, log: log("setup"))
    }

    public func setWindowsVersion(_ version: String, using runtime: WineRuntime, force: Bool = false) async throws {
        let current = try? String(contentsOf: windowsVersionMarker, encoding: .utf8)
        if !force, current == version { return }
        guard ["win7", "win8", "win81", "win10", "win11"].contains(version) else { throw AquaError("Unsupported Windows version \(version)") }
        var env = runtime.baseEnvironment(engine: engine)
        env["WINEPREFIX"] = prefix.path
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=;mscoree,mshtml="
        try await Shell.run(wine, ["winecfg", "-v", version], environment: env, timeout: 120, log: log("setup"))
        try version.write(to: windowsVersionMarker, atomically: true, encoding: .utf8)
    }

    /// Retina mode renders at the display's full pixel resolution instead of half and upscaled:
    /// sharper, but games push 4x the pixels. Paired with 200% Windows scaling (192 DPI) so
    /// DPI-aware apps keep their size, like CrossOver's High Resolution Mode.
    /// Wine reads both when a process starts.
    public func setRetinaMode(_ enabled: Bool, using runtime: WineRuntime) async throws {
        let value = enabled ? "y" : "n"
        if (try? String(contentsOf: retinaMarker, encoding: .utf8)) == value { return }
        try await reg(["add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode", "/t", "REG_SZ", "/d", value, "/f"], using: runtime)
        try await reg(["add", #"HKCU\Control Panel\Desktop"#, "/v", "LogPixels", "/t", "REG_DWORD", "/d", enabled ? "192" : "96", "/f"], using: runtime)
        try value.write(to: retinaMarker, atomically: true, encoding: .utf8)
    }

    /// Wine can return before its server has flushed the registry to disk.
    func waitForServer(_ env: [String: String]) async throws {
        var env = env
        env["WINEPREFIX"] = prefix.path
        try await Shell.run(wineserver, ["-w"], environment: env, timeout: 120, allowedStatus: [0, 1])
    }

    /// Early Aqua builds copied renderer DLLs into system32. Renderers are now chosen per launch
    /// through the environment, so put Wine's own DLLs back if an old bottle still has copies.
    func restoreBuiltinGraphicsDLLs() throws {
        guard FileManager.default.fileExists(atPath: rendererMarker.path) else { return }
        let fm = FileManager.default
        let windows = driveC.appendingPathComponent("windows")
        let builtin = paths.engine(engine).appendingPathComponent("lib/wine")
        for (arch, dir) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
            for dll in Set(Renderer.allCases.flatMap(\.dlls)) {
                let target = windows.appendingPathComponent("\(dir)/\(dll).dll")
                let source = builtin.appendingPathComponent("\(arch)/\(dll).dll")
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: target) }
            }
        }
        try fm.removeItem(at: rendererMarker)
    }

    /// DXVK ships plain Windows DLLs, which Wine won't load from a search path, so on engines
    /// without Sikarugir's renderer variables they live in the bottle as native DLLs. Other
    /// renderers set those DLLs to builtin, so the copies are ignored unless DXVK is selected.
    func installDXVK() throws {
        let source = paths.frameworks.appendingPathComponent("renderer/dxvk/wine")
        let windows = driveC.appendingPathComponent("windows")
        for (arch, folder) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
            for dll in Renderer.dxvk.dlls {
                let file = source.appendingPathComponent("\(arch)/\(dll).dll")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let target = windows.appendingPathComponent("\(folder)/\(dll).dll")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: file, to: target)
            }
        }
    }

    /// Per-launch setup shared by all stores.
    func prepareLaunch(recipe: GameRecipe, settings: AquaSettings, using runtime: WineRuntime) async throws {
        try await prepare(using: runtime)
        try mapDrive(Bottle.gamesDrive, to: settings.gamesURL)
        try await setRetinaMode(settings.retinaMode, using: runtime)
        if recipe.renderer == .dxvk, !engine.usesRendererVariables { try installDXVK() }
        try await DisplaySettingsWriter.apply(recipe.settingsFiles, size: .main(retina: settings.retinaMode), bottle: self, runtime: runtime)
    }

    /// Stops every Windows process in this bottle (Steam, games, helpers).
    public func stop(using runtime: WineRuntime) async throws {
        var env = runtime.baseEnvironment(engine: engine)
        env["WINEPREFIX"] = prefix.path
        try await Shell.run(wineserver, ["-k"], environment: env, timeout: 30, allowedStatus: [0, 1])
        try await Shell.run(wineserver, ["-w"], environment: env, timeout: 60, allowedStatus: [0, 1])
    }

    /// True while any Wine process for this bottle is alive.
    public func isRunning(using runtime: WineRuntime) async -> Bool {
        var env = runtime.baseEnvironment(engine: engine)
        env["WINEPREFIX"] = prefix.path
        // `wineserver -w` blocks while clients exist; a short timeout means something is running.
        do {
            try await Shell.run(wineserver, ["-w"], environment: env, timeout: 1.5, allowedStatus: [0, 1])
            return false
        } catch {
            return true
        }
    }

    /// Runs any Windows program in this bottle (installers, tools).
    @discardableResult
    public func run(_ program: String, _ args: [String] = [], recipe: GameRecipe = .defaults, settings: AquaSettings,
                    using runtime: WineRuntime, logName: String) throws -> Process {
        let env = runtime.environment(bottle: self, recipe: recipe, settings: settings)
        return try Shell.spawn(self.wine, [program] + args, environment: env, workingDirectory: driveC,
                               log: paths.logs.appendingPathComponent("\(logName).log"))
    }
}
