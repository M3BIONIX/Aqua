import Foundation
import AquaCore

let usage = """
aqua-cli: test harness for Aqua's core

  doctor                       Check this Mac and what's installed
  setup                        Download and install the Wine runtime
  steam install                Create the Steam bottle and install Steam
  steam open                   Open the Steam client
  steam games                  List installed Steam games
  steam owned                  List every game the signed-in Steam account owns
  steam get <appid>            Ask Steam to install a game (adds free games to the library)
  steam play <appid>           Launch a Steam game
  steam stop                   Stop Steam and its games
  epic login [code]            Sign in (prints the login URL if no code given)
  epic logout
  epic status
  epic games                   List owned Epic games
  epic install <app_name>      Install an Epic game
  epic play <app_name>         Launch an Epic game
  epic plan <app_name>         Show the launch command without running it
  epic stop                    Stop all Epic games
  recipe <steam|epic> <id>     Show the effective recipe for a game

Set AQUA_HOME to use a different data folder.
"""

let service = AquaService()

func say(_ s: String) { print(s); fflush(stdout) }
func bar(_ fraction: Double?) -> String {
    guard let fraction else { return "" }
    let filled = Int(fraction * 30)
    return "[" + String(repeating: "#", count: filled) + String(repeating: "-", count: 30 - filled) + "] " + String(format: "%5.1f%%", fraction * 100)
}
func formatBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

func epicGame(_ name: String) async throws -> EpicGame {
    let games = try await service.epic.library()
    guard let game = games.first(where: { $0.appName == name || $0.title.caseInsensitiveCompare(name) == .orderedSame }) else {
        throw AquaError("No owned Epic game named \(name). Run `aqua-cli epic games`.")
    }
    return game
}

func run(_ input: [String]) async throws {
    var args = input
    guard let command = args.first else { say(usage); return }
    args.removeFirst()
    let sub = args.first ?? ""

    switch (command, sub) {
    case ("doctor", _):
        let host = await HostCheck.current()
        say("Apple Silicon: \(host.isAppleSilicon)  macOS: \(host.macOSVersion.majorVersion).\(host.macOSVersion.minorVersion)  Rosetta: \(host.rosettaInstalled)")
        host.problems.forEach { say("  ✗ \($0)") }
        say("Data folder: \(service.paths.root.path)")
        say("Runtime: \(service.runtime.isInstalled ? "installed (\(formatBytes(service.runtime.installedSize())))" : "not installed")")
        say("Steam: \(service.steam.isInstalled ? "installed" : "not installed")\(service.steam.accountName.map { ", signed in as \($0)" } ?? "")")
        say("legendary: \(service.epic.isToolInstalled ? "installed" : "not installed")")
        if service.epic.isToolInstalled, let status = try? await service.epic.status() {
            say("Epic: \(status.account.map { "signed in as \($0)" } ?? "not signed in")")
        }

    case ("setup", _):
        let host = await HostCheck.current()
        guard host.problems.isEmpty else { throw AquaError(host.problems.joined(separator: "\n")) }
        try await service.runtime.install { p in
            print("\r\u{1B}[2K\(p.step) \(bar(p.fraction))", terminator: p.fraction == nil ? "\n" : ""); fflush(stdout)
        }
        say("\nRuntime installed.")

    case ("steam", "install"):
        try service.requireRuntime()
        try await service.steam.install(settings: service.settings) { say($0) }
        say("Done. Run `aqua-cli steam open` and sign in.")

    case ("steam", "open"):
        try service.requireRuntime()
        try await service.steam.openClient(settings: service.settings)
        say("Steam is starting. Log: \(service.paths.logs.appendingPathComponent("steam-client.log").path)")

    case ("steam", "games"):
        let games = service.steam.installedGames()
        if games.isEmpty { say("No Steam games installed yet.") }
        for g in games {
            let progress = g.state == .downloading ? " " + bar(g.downloadFraction) : ""
            say("\(g.appID.padding(toLength: 9, withPad: " ", startingAt: 0)) \(g.name)  [\(g.state.rawValue)]\(progress)")
        }

    case ("steam", "owned"):
        say("Steam ID: \(service.steam.steamID64 ?? "not signed in")")
        let result = try await service.steamLibrary.fetch()
        for g in result.games.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            say("\(g.appID.padding(toLength: 9, withPad: " ", startingAt: 0)) \(g.name)")
        }
        say("\(result.games.count) owned games via \(result.source.rawValue)")

    case ("steam", "get"):
        guard args.count > 1 else { throw AquaError("Usage: steam get <appid>") }
        try service.requireRuntime()
        try await service.steam.requestInstall(appID: args[1], settings: service.settings)
        say("Steam is installing app \(args[1]) to the games location.")

    case ("steam", "js"):
        // Debug: evaluate JavaScript in the running Steam client's SharedJSContext.
        guard args.count > 1 else { throw AquaError("Usage: steam js <expression>") }
        let value = try await SteamClientBridge().evaluate(args.dropFirst().joined(separator: " "))
        if let value, JSONSerialization.isValidJSONObject(value) {
            say(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]), as: UTF8.self))
        } else {
            say(String(describing: value ?? "null"))
        }

    case ("steam", "play"):
        guard args.count > 1 else { throw AquaError("Usage: steam play <appid>") }
        let id = args[1]
        guard let game = service.steam.installedGames().first(where: { $0.appID == id }) else { throw AquaError("App \(id) isn't installed in Aqua's Steam.") }
        try await service.launch(steamGame: game)
        say("Launch requested for \(game.name) using \(service.recipe(for: .steam, id: id).renderer?.displayName ?? "default").")

    case ("steam", "stop"):
        try await service.steam.bottle.stop(using: service.wine)
        say("Steam stopped.")

    case ("epic", "login"):
        if args.count > 1 {
            try await service.epic.login(authorizationCode: args.dropFirst().joined(separator: " "))
            say("Signed in as \(try await service.epic.status().account ?? "?").")
        } else {
            say("Open this URL, sign in, then copy the authorizationCode value:\n\n\(EpicStore.loginURL.absoluteString)\n\nThen run: aqua-cli epic login <code>")
        }

    case ("epic", "logout"):
        try await service.epic.logout(); say("Signed out.")

    case ("epic", "status"):
        let s = try await service.epic.status()
        say("Account: \(s.account ?? "not signed in")  available: \(s.gamesAvailable)  installed: \(s.gamesInstalled)")

    case ("epic", "games"):
        let games = try await service.epic.library(refresh: args.contains("--refresh"))
        for g in games {
            let state = g.install != nil ? "installed" : (g.isWindowsGame ? "" : "no Windows build")
            say("\(g.appName.padding(toLength: 34, withPad: " ", startingAt: 0)) \(g.title)  \(state)")
        }
        say("\(games.count) games")

    case ("epic", "install"):
        guard args.count > 1 else { throw AquaError("Usage: epic install <app_name>") }
        let game = try await epicGame(args[1])
        say("Installing \(game.title) to \(service.settings.epicInstallBase.path)…")
        try await service.epic.install(game, settings: service.settings) { p in
            var line = "\(p.message) \(bar(p.fraction))"
            if let speed = p.speedMiBps { line += String(format: "  %.1f MiB/s", speed) }
            if let eta = p.eta { line += "  ETA \(eta)" }
            print("\r\u{1B}[2K" + line, terminator: ""); fflush(stdout)
        }
        say("\nInstalled.")

    case ("epic", "plan"):
        guard args.count > 1 else { throw AquaError("Usage: epic plan <app_name>") }
        let plan = try await service.epic.launchPlan(try await epicGame(args[1]))
        say("exe: \(plan.executable)\ncwd: \(plan.workingDirectory)\nargs: \(plan.arguments.map { $0.contains("AUTH_PASSWORD") ? "-AUTH_PASSWORD=<redacted>" : $0 })\nenv: \(plan.environment)")

    case ("epic", "play"):
        guard args.count > 1 else { throw AquaError("Usage: epic play <app_name>") }
        try service.requireRuntime()
        let game = try await epicGame(args[1])
        say("Preparing the Epic bottle (first time takes a minute)…")
        let process = try await service.launch(epicGame: game) { p in say("\(p.step) \(bar(p.fraction))") }
        say("Started \(game.title) (pid \(process.processIdentifier)) using \(service.recipe(for: .epic, id: game.appName).renderer?.displayName ?? "default"). Log: \(service.paths.logs.appendingPathComponent("epic-\(game.appName).log").path)")

    case ("epic", "stop"):
        try await service.epic.stopAll()
        say("Epic games stopped.")

    case ("env", _):
        // aqua-cli env <bottle> <renderer>: print Aqua's Wine environment as shell exports (debugging).
        guard args.count >= 2, let renderer = Renderer(rawValue: args[1]) else { throw AquaError("Usage: env <steam|epic> <renderer>") }
        let env = service.wine.environment(bottle: Bottle(name: args[0], paths: service.paths), recipe: GameRecipe(renderer: renderer), settings: service.settings)
        for key in env.keys.sorted() where WineRuntime.ownedPrefixes.contains(where: key.hasPrefix) || key.hasPrefix("VK_") || key.hasPrefix("SDL_") {
            say("export \(key)='\(env[key]!.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        say("export AQUA_WINE='\(Bottle(name: args[0], paths: service.paths).wine.path)'")

    case ("exec", _):
        // aqua-cli exec <steam|epic> <d3dmetal|dxmt|dxvk|wined3d> <program.exe> [args…]
        guard args.count >= 3, let renderer = Renderer(rawValue: args[1]) else {
            throw AquaError("Usage: exec <steam|epic> <d3dmetal|dxmt|dxvk|wined3d> <program> [args]")
        }
        try service.requireRuntime()
        let bottle = Bottle(name: args[0], paths: service.paths)
        try await bottle.prepare(using: service.wine) { say($0) }
        var env = service.wine.environment(bottle: bottle, recipe: GameRecipe(renderer: renderer), settings: service.settings)
        // Debug channels, e.g. AQUA_WINEDEBUG=+msgbox,+seh
        if let channels = ProcessInfo.processInfo.environment["AQUA_WINEDEBUG"] { env["WINEDEBUG"] = channels }
        let started = Date()
        defer { say(String(format: "ran for %.1fs", Date().timeIntervalSince(started))) }
        let result = try await Shell.run(bottle.wine, Array(args.dropFirst(2)), environment: env, timeout: 180, allowedStatus: nil)
        say(result.output.split(separator: "\n").filter { !$0.contains("fixme:") }.joined(separator: "\n"))
        say("exit status: \(result.status)")

    case ("recipe", _):
        guard args.count > 1, let store = Store(rawValue: args[0]) else { throw AquaError("Usage: recipe <steam|epic> <id>") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        say(String(decoding: try encoder.encode(service.recipe(for: store, id: args[1])), as: UTF8.self))

    default:
        say(usage)
    }
}

do {
    try await run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
