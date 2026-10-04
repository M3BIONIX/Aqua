import Foundation

/// Graphics translation layer for Direct3D games.
public enum Renderer: String, Codable, CaseIterable, Sendable {
    /// Apple D3DMetal (Game Porting Toolkit): DX11/DX12. Best default for modern games.
    case d3dmetal
    /// DXMT: DX10/DX11 straight to Metal. Often better for DX11-only titles.
    case dxmt
    /// DXVK over MoltenVK: DX9-DX11 via Vulkan.
    case dxvk
    /// Wine's own OpenGL-based wined3d. Slowest, most compatible fallback.
    case wined3d

    public var displayName: String {
        switch self {
        case .d3dmetal: return "D3DMetal"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .wined3d: return "WineD3D"
        }
    }
}

public enum Store: String, Codable, Sendable, CaseIterable {
    case steam, epic
    public var displayName: String { self == .steam ? "Steam" : "Epic Games" }
}

/// Per-game compatibility settings. All fields are optional so a recipe states only what
/// differs from the defaults. Recipes ship in `recipes.json`; users can add their own in
/// `~/Library/Application Support/Aqua/recipes.json`, which takes precedence.
public struct GameRecipe: Codable, Equatable, Sendable {
    public var engine: WineEngine?
    public var renderer: Renderer?
    public var windowsVersion: String?
    public var environment: [String: String]?
    public var dllOverrides: [String: String]?
    public var arguments: [String]?
    /// Advertise AVX/AVX2 to the game through Rosetta. Needed by many modern engines.
    public var advertiseAVX: Bool?
    /// Game settings written before launch so it renders at the display's resolution.
    public var display: [DisplaySetting]?
    /// Other settings files changed before launch. Bundled and user entries both apply, user last.
    public var files: [DisplaySetting]?
    public var notes: String?

    public init(engine: WineEngine? = nil, renderer: Renderer? = nil, windowsVersion: String? = nil, environment: [String: String]? = nil,
                dllOverrides: [String: String]? = nil, arguments: [String]? = nil, advertiseAVX: Bool? = nil,
                display: [DisplaySetting]? = nil, files: [DisplaySetting]? = nil, notes: String? = nil) {
        self.engine = engine
        self.renderer = renderer
        self.windowsVersion = windowsVersion
        self.environment = environment
        self.dllOverrides = dllOverrides
        self.arguments = arguments
        self.advertiseAVX = advertiseAVX
        self.display = display
        self.files = files
        self.notes = notes
    }

    /// Everything written to game files before launch.
    public var settingsFiles: [DisplaySetting] { (display ?? []) + (files ?? []) }

    public static let defaults = GameRecipe(engine: .default, renderer: .d3dmetal, windowsVersion: "win10", advertiseAVX: true)

    /// Overlays `other` on top of `self`; values present in `other` win.
    public func merged(with other: GameRecipe?) -> GameRecipe {
        guard let other else { return self }
        return GameRecipe(
            engine: other.engine ?? engine,
            renderer: other.renderer ?? renderer,
            windowsVersion: other.windowsVersion ?? windowsVersion,
            environment: (environment ?? [:]).merging(other.environment ?? [:]) { $1 },
            dllOverrides: (dllOverrides ?? [:]).merging(other.dllOverrides ?? [:]) { $1 },
            arguments: other.arguments ?? arguments,
            advertiseAVX: other.advertiseAVX ?? advertiseAVX,
            display: other.display ?? display,
            files: (files ?? []) + (other.files ?? []),
            notes: other.notes ?? notes
        )
    }
}

public struct RecipeBook: Sendable {
    /// Keyed as `steam:<appid>` or `epic:<app_name>`.
    public private(set) var recipes: [String: GameRecipe]

    public init(recipes: [String: GameRecipe]) { self.recipes = recipes }

    public static func key(_ store: Store, _ id: String) -> String { "\(store.rawValue):\(id)" }

    /// Bundled recipes, overlaid with the user's own file and per-game overrides saved by the app.
    public static func load(paths: AquaPaths = .shared) -> RecipeBook {
        var book: [String: GameRecipe] = [:]
        if let url = Bundle.resources(named: "Aqua_AquaCore", fallback: { .module }).url(forResource: "recipes", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let bundled = try? JSONDecoder().decode([String: GameRecipe].self, from: data) {
            book = bundled
        }
        let user = paths.root.appendingPathComponent("recipes.json")
        if let data = try? Data(contentsOf: user),
           let custom = try? JSONDecoder().decode([String: GameRecipe].self, from: data) {
            for (key, recipe) in custom { book[key] = (book[key] ?? GameRecipe()).merged(with: recipe) }
        }
        return RecipeBook(recipes: book)
    }

    /// The recipe Aqua ships for a game, without the user's changes.
    public static func bundled(for store: Store, id: String) -> GameRecipe? {
        guard let url = Bundle.resources(named: "Aqua_AquaCore", fallback: { .module }).url(forResource: "recipes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let bundled = try? JSONDecoder().decode([String: GameRecipe].self, from: data) else { return nil }
        return bundled[key(store, id)]
    }

    /// The user's own changes for a game, as saved in their recipes.json.
    public static func userOverride(for store: Store, id: String, paths: AquaPaths = .shared) -> GameRecipe? {
        guard let data = try? Data(contentsOf: paths.root.appendingPathComponent("recipes.json")),
              let custom = try? JSONDecoder().decode([String: GameRecipe].self, from: data) else { return nil }
        return custom[key(store, id)]
    }

    /// Replaces the user's changes for a game; `nil` goes back to Aqua's own settings.
    public static func setUserOverride(_ recipe: GameRecipe?, store: Store, id: String, paths: AquaPaths = .shared) throws {
        let url = paths.root.appendingPathComponent("recipes.json")
        var custom = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: GameRecipe].self, from: $0) } ?? [:]
        custom[key(store, id)] = recipe
        try paths.ensure(paths.root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(custom).write(to: url, options: .atomic)
    }

    public func recipe(for store: Store, id: String) -> GameRecipe {
        GameRecipe.defaults.merged(with: recipes[Self.key(store, id)])
    }

    /// Saves a user override (e.g. a renderer chosen in the UI) to the user recipe file.
    public static func saveOverride(_ recipe: GameRecipe, store: Store, id: String, paths: AquaPaths = .shared) throws {
        let url = paths.root.appendingPathComponent("recipes.json")
        var custom: [String: GameRecipe] = [:]
        if let data = try? Data(contentsOf: url) {
            custom = (try? JSONDecoder().decode([String: GameRecipe].self, from: data)) ?? [:]
        }
        custom[key(store, id)] = (custom[key(store, id)] ?? GameRecipe()).merged(with: recipe)
        try paths.ensure(paths.root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(custom).write(to: url, options: .atomic)
    }
}

extension Bundle {
    /// A SwiftPM resource bundle from inside the app (Contents/Resources) or, when running from
    /// the build folder, SwiftPM's own lookup. `Bundle.module` alone never looks in Contents/Resources.
    public static func resources(named name: String, fallback: () -> Bundle) -> Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("\(name).bundle"), let bundle = Bundle(url: url) { return bundle }
        return fallback()
    }
}
