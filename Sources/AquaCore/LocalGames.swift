import Foundation

/// A Windows game added from a file on this Mac rather than a store: a DRM-free download,
/// a GOG or itch.io installer, an old disc.
public struct LocalGame: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    /// Mac path of the game's .exe.
    public var executable: String
    public var arguments: [String]?
    /// A Steam app with the same name, used only for cover art.
    public var steamAppID: String?
    public var addedAt: Date

    public init(id: String = UUID().uuidString, title: String, executable: String, arguments: [String]? = nil,
                steamAppID: String? = nil, addedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.executable = executable
        self.arguments = arguments
        self.steamAppID = steamAppID
        self.addedAt = addedAt
    }

    public var executableURL: URL { URL(fileURLWithPath: executable) }
    public var folder: URL { executableURL.deletingLastPathComponent() }
    public var exists: Bool { FileManager.default.fileExists(atPath: executable) }
    public var coverURL: URL? { steamAppID.flatMap { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\($0)/library_600x900.jpg") } }
    public var heroURL: URL? { steamAppID.flatMap { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\($0)/library_hero.jpg") } }
}

/// Games added from .exe files. They run in their own bottle (`local`), with the games
/// location mapped as S: like the store bottles.
public final class LocalLibrary: @unchecked Sendable {
    public let paths: AquaPaths
    public let wine: WineRuntime

    public init(paths: AquaPaths = .shared, wine: WineRuntime) {
        self.paths = paths
        self.wine = wine
    }

    private var file: URL { paths.root.appendingPathComponent("local-games.json") }

    public func bottle(for engine: WineEngine) -> Bottle { Bottle.forStore(.local, engine: engine, paths: paths) }

    public var bottles: [Bottle] {
        WineEngine.allCases.map(bottle(for:)).filter { FileManager.default.fileExists(atPath: $0.prefix.path) }
    }

    // MARK: Library

    public func games() -> [LocalGame] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LocalGame].self, from: data)) ?? []
    }

    public func save(_ games: [LocalGame]) throws {
        try paths.ensure(paths.root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(games).write(to: file, options: .atomic)
    }

    @discardableResult
    public func add(_ game: LocalGame) throws -> LocalGame {
        var all = games().filter { $0.id != game.id }
        all.append(game)
        try save(all)
        return game
    }

    /// Takes a game off the library. Its files stay where they are.
    public func remove(id: String) throws {
        try save(games().filter { $0.id != id })
    }

    // MARK: Installers

    /// Folders installers usually write games to: the bottle's Program Files and per-user
    /// Programs folders, and the games location (S: inside Windows).
    public func installRoots(bottle: Bottle, settings: AquaSettings) -> [URL] {
        let c = bottle.driveC
        var roots = [c.appendingPathComponent("Program Files"), c.appendingPathComponent("Program Files (x86)"),
                     c.appendingPathComponent("GOG Games"), c.appendingPathComponent("Games"), settings.gamesURL]
        let users = c.appendingPathComponent("users")
        for user in (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? [] {
            roots.append(users.appendingPathComponent(user).appendingPathComponent("AppData/Local/Programs"))
        }
        return roots
    }

    /// Every .exe under `roots`, skipping store libraries, which never hold a local install.
    public static func executables(in roots: [URL], maxDepth: Int = 6) -> Set<String> {
        var found = Set<String>()
        let skip: Set<String> = ["steamlibrary", "epic", "windows", "steamapps",
                                 // Wine's own stand-ins for Windows programs.
                                 "windows nt", "internet explorer", "windows media player", "common files"]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if enumerator.level > maxDepth { enumerator.skipDescendants(); continue }
                if enumerator.level == 1, skip.contains(url.lastPathComponent.lowercased()) { enumerator.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "exe" { found.insert(url.standardizedFileURL.path) }
            }
        }
        return found
    }

    /// Runs an installer and returns the programs it added, best guess at the game first.
    public func install(_ installer: URL, engine: WineEngine = .default, settings: AquaSettings) async throws -> [URL] {
        let bottle = bottle(for: engine)
        // Set the bottle up first, so Wine's own files don't look like something the installer added.
        try await bottle.prepareLaunch(recipe: .defaults, settings: settings, using: wine)
        let roots = installRoots(bottle: bottle, settings: settings)
        let before = Self.executables(in: roots)
        try await runInstaller(installer, bottle: bottle, settings: settings)
        return Self.gameCandidates(Self.executables(in: roots).subtracting(before))
    }

    /// Runs an installer in the bottle and waits for it and anything it started to finish.
    func runInstaller(_ installer: URL, bottle: Bottle, settings: AquaSettings) async throws {
        let env = wine.environment(bottle: bottle, recipe: .defaults, settings: settings)
        let isMSI = installer.pathExtension.lowercased() == "msi"
        let arguments = isMSI ? ["msiexec", "/i", installer.path] : [installer.path]
        AquaLog.write("installer started \(installer.lastPathComponent)", paths: paths)
        try await Shell.run(bottle.wine, arguments, environment: env, workingDirectory: installer.deletingLastPathComponent(),
                            timeout: nil, allowedStatus: nil, log: paths.logs.appendingPathComponent("local-installer.log"))
        // Installers often hand off to a second process and exit early; wait for the bottle to go quiet.
        var serverEnv = wine.baseEnvironment(engine: bottle.engine)
        serverEnv["WINEPREFIX"] = bottle.prefix.path
        try? await Shell.run(bottle.wineserver, ["-w"], environment: serverEnv, timeout: nil, allowedStatus: nil)
        AquaLog.write("installer finished \(installer.lastPathComponent)", paths: paths)
    }

    /// The likely game executables among files an installer created, best first:
    /// helpers like uninstallers, redistributables and crash reporters are left out.
    public static func gameCandidates(_ paths: Set<String>) -> [URL] {
        let helpers = ["unins", "uninst", "setup", "install", "redist", "vcredist", "vc_redist", "dxsetup", "directx",
                       "dotnet", "crashreport", "crashhandler", "unitycrashhandler", "updater", "launcherpatcher",
                       "cefprocess", "helper", "easyanticheat", "battleye", "ue4prereq", "prereq", "touchup", "reporter"]
        let size = { (path: String) -> Int64 in
            ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value) ?? 0
        }
        return paths.filter { path in
            let name = (path as NSString).lastPathComponent.lowercased()
            return !helpers.contains { name.hasPrefix($0) || name.contains($0) }
        }
        .sorted { size($0) > size($1) }
        .map { URL(fileURLWithPath: $0) }
    }

    /// A readable name from the game's folder, skipping generic build folders.
    public static func suggestedTitle(for executable: URL) -> String {
        let generic: Set<String> = ["bin", "bin64", "binaries", "win64", "win32", "x64", "x86", "game", "release", "shipping", "exe"]
        var folder = executable.deletingLastPathComponent()
        while generic.contains(folder.lastPathComponent.lowercased()), folder.pathComponents.count > 2 {
            folder = folder.deletingLastPathComponent()
        }
        let name = folder.lastPathComponent
        let fallback = executable.deletingPathExtension().lastPathComponent
        let candidate = ["Program Files", "Program Files (x86)", "drive_c", "Downloads", "Desktop"].contains(name) ? fallback : name
        return candidate.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Running

    @discardableResult
    public func launch(_ game: LocalGame, recipe: GameRecipe, settings: AquaSettings) async throws -> Process {
        guard game.exists else { throw AquaError("\(game.title)'s .exe is missing:\n\(game.executable)") }
        let bottle = bottle(for: recipe.engine ?? .default)
        try await bottle.prepareLaunch(recipe: recipe, settings: settings, using: wine)
        if let version = recipe.windowsVersion { try await bottle.setWindowsVersion(version, using: wine) }
        let env = wine.environment(bottle: bottle, recipe: recipe, settings: settings)
        return try Shell.spawn(bottle.wine, [game.executable] + (game.arguments ?? []) + (recipe.arguments ?? []),
                               environment: env, workingDirectory: game.folder,
                               log: paths.logs.appendingPathComponent("local-\(game.id).log"))
    }

    public func stopAll() async throws {
        for bottle in bottles { try await bottle.stop(using: wine) }
    }

    // MARK: Cover art

    /// A Steam app whose name matches `title`, for its cover art. Nil if nothing matches closely.
    public static func steamArtwork(for title: String, session: URLSession = .shared) async -> String? {
        var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        components.queryItems = [.init(name: "term", value: title), .init(name: "l", value: "english"), .init(name: "cc", value: "US")]
        guard let url = components.url,
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return nil }
        return bestMatch(for: title, in: items.compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            return (String(id), name)
        })
    }

    static func bestMatch(for title: String, in results: [(id: String, name: String)]) -> String? {
        let wanted = normalized(title)
        guard !wanted.isEmpty else { return nil }
        if let exact = results.first(where: { normalized($0.name) == wanted }) { return exact.id }
        return results.first { normalized($0.name).hasPrefix(wanted) || wanted.hasPrefix(normalized($0.name)) }?.id
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
