import XCTest
@testable import AquaCore

final class VDFTests: XCTestCase {
    func testParsesAppManifest() throws {
        let text = """
        "AppState"
        {
        \t"appid"\t\t"1245620"
        \t"name"\t\t"ELDEN RING"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"ELDEN RING"
        \t"SizeOnDisk"\t\t"52345678901"
        \t"BytesToDownload"\t\t"0"
        \t"UserConfig"
        \t{
        \t\t"language"\t\t"english"
        \t}
        }
        """
        let game = try XCTUnwrap(SteamStore.parseManifest(text, library: URL(fileURLWithPath: "/tmp")))
        XCTAssertEqual(game.appID, "1245620")
        XCTAssertEqual(game.name, "ELDEN RING")
        XCTAssertEqual(game.state, .installed)
        XCTAssertEqual(game.sizeOnDisk, 52_345_678_901)
    }

    func testDownloadingState() throws {
        let text = #""AppState" { "appid" "730" "name" "Counter-Strike 2" "StateFlags" "1026" "BytesDownloaded" "50" "BytesToDownload" "200" }"#
        let game = try XCTUnwrap(SteamStore.parseManifest(text, library: URL(fileURLWithPath: "/tmp")))
        XCTAssertEqual(game.state, .downloading)
        XCTAssertEqual(game.downloadFraction, 0.25)
    }

    func testCommentsEscapesAndCaseInsensitiveKeys() throws {
        let vdf = try VDF.parse("// header\n\"Root\" { \"Path\" \"C:\\\\Games\\\\Steam\" }")
        XCTAssertEqual(vdf["root"]?["path"]?.string, #"C:\Games\Steam"#)
    }

    func testRejectsUnterminated() {
        XCTAssertThrowsError(try VDF.parse("\"a\" { \"b\" \"c\""))
    }
}

final class SteamTests: XCTestCase {
    func testRunningAppsFromProcessLog() {
        let log = """
        [2026-10-03 21:00:00] AppID 730 adding PID 100 as a tracked process "cs2.exe"
        [2026-10-03 21:00:01] AppID 1245620 adding PID 200 as a tracked process "eldenring.exe"
        [2026-10-03 21:05:00] AppID 730 no longer tracking PID 100, exit code 0
        """
        XCTAssertEqual(SteamStore.runningApps(inProcessLog: log), ["1245620"])
        XCTAssertEqual(SteamStore.runningApps(inProcessLog: log + "\n[x] Game process removed: AppID 1245620 \"\", ProcID 200\nRemove 1245620 from running list"), [])
    }
}

final class RecipeTests: XCTestCase {
    func testDefaultsAndOverrides() {
        let book = RecipeBook(recipes: ["steam:489830": GameRecipe(renderer: .dxmt, environment: ["A": "1"])])
        let skyrim = book.recipe(for: .steam, id: "489830")
        XCTAssertEqual(skyrim.renderer, .dxmt)
        XCTAssertEqual(skyrim.windowsVersion, "win10")
        XCTAssertEqual(skyrim.environment?["A"], "1")
        XCTAssertEqual(book.recipe(for: .epic, id: "unknown").renderer, .d3dmetal)
    }

    func testBundledRecipesDecode() {
        let book = RecipeBook.load(paths: AquaPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        XCTAssertEqual(book.recipe(for: .steam, id: "730").renderer, .dxmt)
        XCTAssertEqual(book.recipe(for: .steam, id: "292030").arguments, ["--launcher-skip"])
    }

    func testEnvironmentForRenderers() {
        let paths = AquaPaths(root: URL(fileURLWithPath: "/tmp/aqua-test"))
        let wine = WineRuntime(paths: paths)
        let bottle = Bottle(name: "epic", paths: paths)
        let metal = wine.environment(bottle: bottle, recipe: .defaults, settings: AquaSettings())
        XCTAssertTrue(metal["WINEDLLOVERRIDES"]!.contains("d3d11=b"))
        XCTAssertEqual(metal["WINEDLLPATH_PREPEND"], "/tmp/aqua-test/Runtime/Frameworks/renderer/d3dmetal/wine")
        XCTAssertNil(metal["WINEDLLPATH_DXMT"])
        XCTAssertTrue(metal["WINEDLLOVERRIDES"]!.contains("nvapi64="))
        XCTAssertTrue(metal["WINEDLLOVERRIDES"]!.contains("vcruntime140_1=n,b"))
        XCTAssertTrue(metal["WINEDLLOVERRIDES"]!.contains("msvcp140_2=n,b"))
        XCTAssertEqual(metal["WINEPREFIX"], "/tmp/aqua-test/Bottles/epic/prefix")
        XCTAssertEqual(metal["ROSETTA_ADVERTISE_AVX"], "1")

        let fallback = wine.environment(bottle: bottle, recipe: GameRecipe(renderer: .wined3d), settings: AquaSettings())
        XCTAssertTrue(fallback["WINEDLLOVERRIDES"]!.contains("d3d11=b"))
        XCTAssertFalse(fallback["WINEDLLOVERRIDES"]!.contains("d3d11=n,b"))
        XCTAssertNil(fallback["WINEDLLPATH_PREPEND"])

        let dxvk = wine.environment(bottle: bottle, recipe: GameRecipe(renderer: .dxvk), settings: AquaSettings())
        XCTAssertTrue(dxvk["WINEDLLOVERRIDES"]!.contains("d3d9=n,b"))
        XCTAssertEqual(dxvk["VK_DRIVER_FILES"], "/tmp/aqua-test/Runtime/vulkan/kosmickrisp_icd.json")

        let custom = wine.environment(bottle: bottle, recipe: GameRecipe(renderer: .dxmt, dllOverrides: ["d3d12": ""]), settings: AquaSettings())
        XCTAssertTrue(custom["WINEDLLOVERRIDES"]!.contains("winemetal=b"))
        XCTAssertNotNil(custom["WINEDLLPATH_PREPEND"])
        XCTAssertTrue(custom["WINEDLLOVERRIDES"]!.contains("d3d12=;"))
    }
}

final class EpicTests: XCTestCase {
    func testProgressParsing() {
        var p = EpicInstallProgress(fraction: 0, message: "")
        XCTAssertTrue(EpicStore.parseProgress("[DLManager] INFO: = Progress: 12.50% (100/800), Running for 00:01:00, ETA: 00:07:00", into: &p))
        XCTAssertEqual(p.fraction, 0.125, accuracy: 0.0001)
        XCTAssertEqual(p.eta, "00:07:00")
        XCTAssertTrue(EpicStore.parseProgress("[DLManager] INFO:  + Download\t- 21.45 MiB/s (raw) / 30.00 MiB/s (decompressed)", into: &p))
        XCTAssertEqual(p.speedMiBps, 21.45)
        XCTAssertTrue(EpicStore.parseProgress("[DLManager] INFO:  + Disk\t- 40.10 MiB/s (write) / 0.00 MiB/s (read)", into: &p))
        XCTAssertEqual(p.diskMiBps, 40.10)
        XCTAssertTrue(EpicStore.parseProgress("[cli] INFO: Download size: 1.50 GiB (Compression savings: 20.0%)", into: &p))
        XCTAssertEqual(p.downloadBytes, 1_610_612_736)
        XCTAssertTrue(EpicStore.parseProgress("[cli] INFO: Install size: 512.00 MiB", into: &p))
        XCTAssertEqual(p.installBytes, 536_870_912)
        XCTAssertFalse(EpicStore.parseProgress("random noise", into: &p))
    }

    func testInstallFailureReason() {
        let output = "Installation requirements check returned the following results:\n ! Failure: Not enough available disk space! 18.05 GiB < 63.00 GiB\n[cli] CRITICAL: exiting."
        XCTAssertEqual(EpicStore.installFailure(output)?.message, "Not enough available disk space! 18.05 GiB < 63.00 GiB")
        XCTAssertNil(EpicStore.installFailure("all good"))
    }

    func testMemoryLimitReachesWine() {
        let paths = AquaPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("aqua-mem"))
        let bottle = Bottle.forStore(.epic, engine: .aqua, paths: paths)
        var settings = AquaSettings(gamesLocation: "/tmp")
        XCTAssertNil(WineRuntime(paths: paths).environment(bottle: bottle, recipe: .defaults, settings: settings)["AQUA_MEMORY_LIMIT_MB"])
        settings.memoryLimitGB = 12
        XCTAssertEqual(WineRuntime(paths: paths).environment(bottle: bottle, recipe: .defaults, settings: settings)["AQUA_MEMORY_LIMIT_MB"], "12288")
    }

    func testJSONPayloadSkipsLogLines() throws {
        let output = "[cli] INFO: Logging in...\n[{\"app_name\": \"Fortnite\"}]\n[cli] INFO: done"
        let value = try XCTUnwrap(EpicStore.jsonPayload(output) as? [[String: String]])
        XCTAssertEqual(value.first?["app_name"], "Fortnite")
    }
}

final class SteamLibraryTests: XCTestCase {
    func testParsesWebAPI() throws {
        let json = #"{"response":{"game_count":2,"games":[{"appid":480,"name":"Spacewar","playtime_forever":5},{"appid":1245620,"name":"ELDEN RING","playtime_forever":600}]}}"#
        let games = try SteamLibrary.parseWebAPI(Data(json.utf8))
        XCTAssertEqual(games.map(\.appID), ["480", "1245620"])
        XCTAssertEqual(games[1].playtimeMinutes, 600)
    }

    func testPrivateProfileViaWebAPIIsAnError() {
        XCTAssertThrowsError(try SteamLibrary.parseWebAPI(Data(#"{"response":{}}"#.utf8)))
    }

    func testParsesProfileXML() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gamesList><steamID64>76561198000000000</steamID64><games>
        <game><appID>480</appID><name><![CDATA[Spacewar]]></name><hoursOnRecord>1.5</hoursOnRecord></game>
        <game><appID>730</appID><name><![CDATA[Counter-Strike 2]]></name></game>
        </games></gamesList>
        """
        let games = try SteamLibrary.parseProfileXML(Data(xml.utf8))
        XCTAssertEqual(games.map(\.name), ["Spacewar", "Counter-Strike 2"])
        XCTAssertEqual(games[0].playtimeMinutes, 90)
    }

    func testPrivateProfileXMLIsAnError() {
        let xml = "<?xml version=\"1.0\"?><response><error><![CDATA[This profile is private.]]></error></response>"
        XCTAssertThrowsError(try SteamLibrary.parseProfileXML(Data(xml.utf8)))
    }

    func testOwnedGamesMergeWithInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AquaPaths(root: root)
        let steam = SteamStore(paths: paths, wine: WineRuntime(paths: paths))
        let apps = steam.steamDirectory.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try #""AppState" { "appid" "480" "name" "Spacewar" "StateFlags" "4" "installdir" "Spacewar" }"#
            .write(to: apps.appendingPathComponent("appmanifest_480.acf"), atomically: true, encoding: .utf8)
        let owned = [SteamOwnedGame(appID: "480", name: "Spacewar", playtimeMinutes: 0),
                     SteamOwnedGame(appID: "730", name: "Counter-Strike 2", playtimeMinutes: 0),
                     SteamOwnedGame(appID: "228980", name: "Steamworks Common Redistributables", playtimeMinutes: 0)]
        let library = steam.library(owned: owned)
        XCTAssertEqual(library.map(\.appID), ["730", "480"])
        XCTAssertEqual(library.first { $0.appID == "480" }?.state, .installed)
        XCTAssertEqual(library.first { $0.appID == "730" }?.state, .notInstalled)
    }
}

final class LegendaryConfigTests: XCTestCase {
    func testPinsWindowsPlatform() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AquaPaths(root: root)
        let epic = EpicStore(paths: paths, wine: WineRuntime(paths: paths))
        try FileManager.default.createDirectory(at: paths.legendaryConfig, withIntermediateDirectories: true)
        try "[Legendary]\ndefault_platform = Mac\n\n[default]\nwine_executable = x\n"
            .write(to: paths.legendaryConfig.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        try epic.writeConfig()
        try epic.writeConfig()
        let text = try String(contentsOf: paths.legendaryConfig.appendingPathComponent("config.ini"), encoding: .utf8)
        XCTAssertTrue(text.contains("default_platform = Windows"))
        XCTAssertTrue(text.contains("disable_auto_crossover = true"))
        XCTAssertFalse(text.contains("Mac"))
        XCTAssertEqual(text.components(separatedBy: "disable_update_check").count, 2)
        XCTAssertTrue(text.contains("wine_executable = x"))
    }
}

final class SteamClientBridgeTests: XCTestCase {
    func testParsesOwnedReply() {
        let games = SteamClientBridge.parseOwned([["appid": "480", "name": "Spacewar", "minutes": 3], ["appid": "", "name": "x"], ["appid": "730", "name": ""]])
        XCTAssertEqual(games.map(\.appID), ["480", "730"])
        XCTAssertEqual(games[1].name, "App 730")
    }
}

final class EngineTests: XCTestCase {
    func testBottleEngineFollowsName() {
        let paths = AquaPaths(root: URL(fileURLWithPath: "/tmp/aqua-test"))
        XCTAssertEqual(Bottle.forStore(.epic, engine: .aqua, paths: paths).name, "epic")
        XCTAssertEqual(Bottle(name: "steam", paths: paths).engine, .aqua)
        XCTAssertEqual(Bottle.forStore(.epic, engine: .wine10, paths: paths).name, "epic-wine10")
        let cx = Bottle.forStore(.epic, engine: .crossover24, paths: paths)
        XCTAssertEqual(cx.name, "epic-crossover")
        XCTAssertEqual(cx.engine, .crossover24)
        XCTAssertEqual(cx.wine.path, "/tmp/aqua-test/Runtime/Engine-crossover24/bin/wine")
        XCTAssertEqual(Bottle(name: "epic", paths: paths).wine.path, "/tmp/aqua-test/Runtime/Engine-aqua/bin/wine")
    }

    func testRendererVariablePerEngine() {
        let paths = AquaPaths(root: URL(fileURLWithPath: "/tmp/aqua-test"))
        let wine = WineRuntime(paths: paths)
        let aqua = wine.environment(bottle: Bottle(name: "epic", paths: paths), recipe: GameRecipe(renderer: .dxmt), settings: AquaSettings())
        XCTAssertEqual(aqua["WINEDLLPATH_PREPEND"], "/tmp/aqua-test/Runtime/Frameworks/renderer/dxmt/wine")
        XCTAssertNil(aqua["WINEDLLPATH_DXMT"])
        XCTAssertEqual(aqua["CX_ACTIVE_GRAPHICS_BACKEND"], "dxmt")
        XCTAssertEqual(aqua["WINE_LARGE_ADDRESS_AWARE"], "1")
        let w10 = wine.environment(bottle: Bottle(name: "epic-wine10", paths: paths), recipe: GameRecipe(renderer: .dxmt), settings: AquaSettings())
        XCTAssertNotNil(w10["WINEDLLPATH_DXMT"])
        XCTAssertNil(w10["WINEDLLPATH_PREPEND"])
        XCTAssertEqual(w10["WINELOADER"], "/tmp/aqua-test/Runtime/Engine/bin/wine")
    }

    func testRecipesPickEngines() {
        let book = RecipeBook.load(paths: AquaPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        XCTAssertEqual(book.recipe(for: .epic, id: "41869934302e4b8cafac2d3c0e7c293d").engine, .crossover24)
        XCTAssertEqual(book.recipe(for: .epic, id: "anything-else").engine, .aqua)
    }
}

final class DisplaySettingsTests: XCTestCase {
    func testPatchesEachFormat() {
        let size = DisplaySize(width: 3024, height: 1964)
        let ini = DisplaySettingsWriter.patch("[/Script/Engine.GameUserSettings]\nResolutionSizeX=1512\nresolutionsizey=982\nOther=1\n",
                                              format: .ini, values: ["ResolutionSizeX": size.fill("{width}"), "ResolutionSizeY": size.fill("{height}")])
        XCTAssertTrue(ini.contains("ResolutionSizeX=3024"))
        XCTAssertTrue(ini.contains("resolutionsizey=1964"))
        XCTAssertTrue(ini.contains("Other=1"))
        let xml = DisplaySettingsWriter.patch("<Resolution-FullScreenWidth>1920</Resolution-FullScreenWidth>", format: .xml,
                                              values: ["Resolution-FullScreenWidth": "3024"])
        XCTAssertEqual(xml, "<Resolution-FullScreenWidth>3024</Resolution-FullScreenWidth>")
        let kv = DisplaySettingsWriter.patch("\"setting.defaultres\"\t\t\"1280\"", format: .keyValues, values: ["setting.defaultres": "3024"])
        XCTAssertEqual(kv, "\"setting.defaultres\"\t\t\"3024\"")
        XCTAssertEqual(DisplaySettingsWriter.patch("Resolution = 800 600", format: .ini, values: ["Resolution": "3024 1964"]), "Resolution = 3024 1964")
    }

    func testAddsMissingKeysUnderSection() {
        let added = DisplaySettingsWriter.patch("[Core.System]\nPaths=../\n\n[Other]\nA=1\n", format: .ini,
                                                values: ["r.WarnOfBadDrivers": "0"], section: "SystemSettings")
        XCTAssertEqual(added, "[Core.System]\nPaths=../\n\n[Other]\nA=1\n\n[SystemSettings]\nr.WarnOfBadDrivers=0\n")
        let existing = DisplaySettingsWriter.patch("[SystemSettings]\nr.Foo=1\n\n[Other]\nA=1\n", format: .ini,
                                                   values: ["r.WarnOfBadDrivers": "0"], section: "SystemSettings")
        XCTAssertEqual(existing, "[SystemSettings]\nr.Foo=1\nr.WarnOfBadDrivers=0\n\n[Other]\nA=1\n")
        let replaced = DisplaySettingsWriter.patch("[SystemSettings]\nr.WarnOfBadDrivers=1\n", format: .ini,
                                                   values: ["r.WarnOfBadDrivers": "0"], section: "SystemSettings")
        XCTAssertEqual(replaced, "[SystemSettings]\nr.WarnOfBadDrivers=0\n")
        XCTAssertEqual(DisplaySettingsWriter.patch("", format: .ini, values: ["k": "v"], section: "S"), "[S]\nk=v\n")
    }

    func testWritesIntoTheBottlesWindowsUser() async throws {
        let paths = AquaPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("aqua-files-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bottle = Bottle.forStore(.epic, engine: .aqua, paths: paths)
        let fm = FileManager.default
        let users = bottle.driveC.appendingPathComponent("users")
        let config = users.appendingPathComponent("crossover/AppData/Local/HogwartsLegacy/Saved/Config/WindowsNoEditor")
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        try fm.createDirectory(at: users.appendingPathComponent("someone/AppData/Local"), withIntermediateDirectories: true)
        try "[Volatile Environment]\n\"USERPROFILE\"=\"C:\\\\users\\\\crossover\"\n".write(to: bottle.prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        XCTAssertEqual(DisplaySettingsWriter.profileFolder(in: bottle), "C:\\users\\crossover")

        let setting = DisplaySetting(format: .ini, file: "%LOCALAPPDATA%\\Hogwarts*Legacy\\Saved\\Config\\WindowsNoEditor\\Engine.ini",
                                     section: "SystemSettings", values: ["r.WarnOfBadDrivers": "0"])
        try await DisplaySettingsWriter.apply([setting], size: DisplaySize(width: 1, height: 1), bottle: bottle, runtime: WineRuntime(paths: paths))
        let written = try String(contentsOf: config.appendingPathComponent("Engine.ini"), encoding: .utf8)
        XCTAssertEqual(written, "[SystemSettings]\nr.WarnOfBadDrivers=0\n")
    }
}

final class LaunchOptionsTextTests: XCTestCase {
    func testPairsAndArguments() {
        XCTAssertEqual(LaunchOptionsText.parsePairs("A=1\n# note\n B = two words \nbad line\n"), ["A": "1", "B": "two words"])
        XCTAssertEqual(LaunchOptionsText.formatPairs(["B": "2", "A": "1"]), "A=1\nB=2")
        XCTAssertEqual(LaunchOptionsText.parseArguments(#"-dx11 -windowed "-log=My File.txt" ''"#), ["-dx11", "-windowed", "-log=My File.txt", ""])
        XCTAssertEqual(LaunchOptionsText.formatArguments(["-dx11", "a b"]), #"-dx11 "a b""#)
    }

    func testFilesRoundTrip() {
        let text = """
        %LOCALAPPDATA%\\Game\\Engine.ini
        [SystemSettings]
        r.WarnOfBadDrivers=0
        [Core.Log]
        LogTemp=Verbose
        %APPDATA%\\Other\\settings.cfg
        fov=90
        """
        let files = LaunchOptionsText.parseFiles(text)
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].section, "SystemSettings")
        XCTAssertEqual(files[1].values, ["LogTemp": "Verbose"])
        XCTAssertEqual(files[2].file, "%APPDATA%\\Other\\settings.cfg")
        XCTAssertNil(files[2].section)
        XCTAssertEqual(LaunchOptionsText.parseFiles(LaunchOptionsText.formatFiles(files)), files)
    }
}

final class LocalGamesTests: XCTestCase {
    func testSuggestedTitleSkipsBuildFolders() {
        XCTAssertEqual(LocalLibrary.suggestedTitle(for: URL(fileURLWithPath: "/g/Hollow Knight/hollow_knight.exe")), "Hollow Knight")
        XCTAssertEqual(LocalLibrary.suggestedTitle(for: URL(fileURLWithPath: "/g/Cool_Game/Binaries/Win64/Cool.exe")), "Cool Game")
        XCTAssertEqual(LocalLibrary.suggestedTitle(for: URL(fileURLWithPath: "/u/Downloads/Tetris.exe")), "Tetris")
    }

    func testCandidatesDropHelpers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aqua-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = ["Game.exe": 3000, "Launcher.exe": 1000, "unins000.exe": 5000, "vc_redist.x64.exe": 9000, "UnityCrashHandler64.exe": 4000]
        for (name, size) in files { try Data(count: size).write(to: dir.appendingPathComponent(name)) }
        let found = LocalLibrary.executables(in: [dir])
        XCTAssertEqual(found.count, 5)
        XCTAssertEqual(LocalLibrary.gameCandidates(found).map(\.lastPathComponent), ["Game.exe", "Launcher.exe"])
    }

    func testArtworkMatch() {
        let results = [(id: "1", name: "Hollow Knight: Silksong"), (id: "2", name: "Hollow Knight"), (id: "3", name: "Knight")]
        XCTAssertEqual(LocalLibrary.bestMatch(for: "Hollow Knight", in: results), "2")
        XCTAssertEqual(LocalLibrary.bestMatch(for: "hollow-knight", in: results), "2")
        XCTAssertNil(LocalLibrary.bestMatch(for: "Celeste", in: results))
    }

    func testLibraryRoundTrip() throws {
        let paths = AquaPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("aqua-lib-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let library = LocalLibrary(paths: paths, wine: WineRuntime(paths: paths))
        let game = try library.add(LocalGame(title: "Tetris", executable: "/tmp/tetris.exe"))
        XCTAssertEqual(library.games().map(\.title), ["Tetris"])
        XCTAssertEqual(library.bottle(for: .aqua).name, "local")
        try library.remove(id: game.id)
        XCTAssertTrue(library.games().isEmpty)
    }
}
