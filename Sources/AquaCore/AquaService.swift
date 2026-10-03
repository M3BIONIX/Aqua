import Foundation

/// Entry point shared by the app and the CLI.
public final class AquaService: @unchecked Sendable {
    public let paths: AquaPaths
    public let runtime: RuntimeInstaller
    public let wine: WineRuntime
    public let steam: SteamStore
    public let epic: EpicStore
    public let steamLibrary: SteamLibrary

    public init(paths: AquaPaths = .shared) {
        self.paths = paths
        runtime = RuntimeInstaller(paths: paths)
        wine = WineRuntime(paths: paths)
        steam = SteamStore(paths: paths, wine: wine)
        epic = EpicStore(paths: paths, wine: wine)
        steamLibrary = SteamLibrary(steam: steam)
    }

    public var settings: AquaSettings { AquaSettings.load(paths) }
    public var recipes: RecipeBook { RecipeBook.load(paths: paths) }

    public func recipe(for store: Store, id: String) -> GameRecipe { recipes.recipe(for: store, id: id) }

    public func requireRuntime() throws {
        guard runtime.isInstalled else { throw AquaError("Set up the Aqua runtime first.") }
    }

    public func launch(steamGame: SteamGame) async throws {
        try requireRuntime()
        try await steam.launch(steamGame, recipe: recipe(for: .steam, id: steamGame.appID), settings: settings)
    }

    @discardableResult
    public func launch(epicGame: EpicGame, progress: (@Sendable (RuntimeProgress) -> Void)? = nil) async throws -> Process {
        try requireRuntime()
        let recipe = recipe(for: .epic, id: epicGame.appName)
        try await runtime.install(recipe.engine ?? .default, progress: progress)
        return try await epic.launch(epicGame, recipe: recipe, settings: settings)
    }
}
