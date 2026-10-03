import Foundation

/// Every location Aqua reads or writes. Set `AQUA_HOME` to isolate a test run.
public struct AquaPaths: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let custom = ProcessInfo.processInfo.environment["AQUA_HOME"], !custom.isEmpty {
            self.root = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Aqua", isDirectory: true)
        }
    }

    public static let shared = AquaPaths()

    public var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    public var runtime: URL { root.appendingPathComponent("Runtime", isDirectory: true) }
    /// Wine itself: `bin/wine`, `lib/wine/...`.
    public var engine: URL { runtime.appendingPathComponent("Engine", isDirectory: true) }
    /// Sikarugir template frameworks: D3DMetal, MoltenVK, GStreamer and shared dylibs.
    public var frameworks: URL { runtime.appendingPathComponent("Frameworks", isDirectory: true) }
    public var d3dmetal: URL { frameworks.appendingPathComponent("renderer/d3dmetal", isDirectory: true) }
    /// Vulkan driver manifest written at install time (paths in the template's own manifests are relative to its app layout).
    public var vulkanDriverManifest: URL { runtime.appendingPathComponent("vulkan/kosmickrisp_icd.json") }
    public var tools: URL { root.appendingPathComponent("Tools", isDirectory: true) }
    public var legendary: URL { tools.appendingPathComponent("legendary") }
    public var legendaryConfig: URL { root.appendingPathComponent("Epic/legendary", isDirectory: true) }
    public var bottles: URL { root.appendingPathComponent("Bottles", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var activityFile: URL { root.appendingPathComponent("activity.json") }

    public var wine: URL { engine.appendingPathComponent("bin/wine") }
    public var wineserver: URL { engine.appendingPathComponent("bin/wineserver") }

    public func bottle(_ name: String) -> URL { bottles.appendingPathComponent(name, isDirectory: true) }

    public func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// Appends timestamped lines to Logs/aqua.log so app actions and errors can be traced later.
public enum AquaLog {
    private static let lock = NSLock()

    public static func write(_ message: String, paths: AquaPaths = .shared) {
        lock.lock(); defer { lock.unlock() }
        let file = paths.logs.appendingPathComponent("aqua.log")
        try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line); try? handle.close()
        } else {
            try? line.write(to: file)
        }
    }
}

/// User-adjustable settings, persisted as JSON.
public struct AquaSettings: Codable, Sendable, Equatable {
    /// Folder for all games: Epic installs to `Epic/`, Steam uses `SteamLibrary/`.
    /// Bottles see it as drive S:.
    public var gamesLocation: String
    public var metalHUD: Bool
    public var retinaMode: Bool
    /// Set once the first-run setup is finished.
    public var onboarded: Bool
    /// Most disk space installed games may use, in GB. `nil` means no limit.
    public var storageLimitGB: Int?
    /// Physical memory reported to Windows games, in GB. `nil` means all of it.
    public var memoryLimitGB: Int?

    public init(gamesLocation: String? = nil, metalHUD: Bool = false, retinaMode: Bool = false,
                onboarded: Bool = false, storageLimitGB: Int? = nil, memoryLimitGB: Int? = nil) {
        self.gamesLocation = gamesLocation ?? GamesLocation.suggested().path
        self.metalHUD = metalHUD
        self.retinaMode = retinaMode
        self.onboarded = onboarded
        self.storageLimitGB = storageLimitGB
        self.memoryLimitGB = memoryLimitGB
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(gamesLocation: try c.decodeIfPresent(String.self, forKey: .gamesLocation),
                  metalHUD: try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false,
                  retinaMode: try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? false,
                  onboarded: try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? false,
                  storageLimitGB: try c.decodeIfPresent(Int.self, forKey: .storageLimitGB),
                  memoryLimitGB: try c.decodeIfPresent(Int.self, forKey: .memoryLimitGB))
    }

    public var gamesURL: URL { URL(fileURLWithPath: gamesLocation, isDirectory: true) }
    public var epicInstallBase: URL { gamesURL.appendingPathComponent("Epic", isDirectory: true) }
    public var steamLibrary: URL { gamesURL.appendingPathComponent("SteamLibrary", isDirectory: true) }

    public static func load(_ paths: AquaPaths = .shared) -> AquaSettings {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let settings = try? JSONDecoder().decode(AquaSettings.self, from: data) else { return AquaSettings() }
        return settings
    }

    public func save(_ paths: AquaPaths = .shared) throws {
        try paths.ensure(paths.root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: paths.settingsFile, options: .atomic)
    }
}

public enum GamesLocation {
    /// The writable local volume with the most free space: `~/Games/Aqua` on the startup
    /// disk, or `<volume>/Aqua Games` on another one.
    public static func suggested() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/Aqua", isDirectory: true)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeIsReadOnlyKey,
                                         .volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        var best = (url: home, free: freeSpace(home.deletingLastPathComponent()))
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            guard let v = try? volume.resourceValues(forKeys: keys), v.volumeIsReadOnly == false, v.volumeIsLocal == true,
                  v.volumeIsRootFileSystem == false, v.volumeIsBrowsable == true, volume.path.hasPrefix("/Volumes/") else { continue }
            let free = Int64(v.volumeAvailableCapacityForImportantUsage ?? 0)
            if free > best.free { best = (volume.appendingPathComponent("Aqua Games", isDirectory: true), free) }
        }
        return best.url
    }

    public static func freeSpace(_ url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

public enum SystemMemory {
    public static var physicalGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    /// What macOS keeps for itself: 2 GB, or an eighth of memory on larger Macs.
    public static var reservedGB: Int { max(2, physicalGB / 8) }

    /// The most memory games can be given.
    public static var maximumForGamesGB: Int { max(minimumForGamesGB, physicalGB - reservedGB) }

    public static let minimumForGamesGB = 4
}
