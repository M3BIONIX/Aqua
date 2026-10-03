import Foundation

/// Builds the environment for running Wine with a bottle and a game recipe.
public struct WineRuntime: Sendable {
    public let paths: AquaPaths
    public init(paths: AquaPaths = .shared) { self.paths = paths }

    /// Variables Aqua controls. Anything inherited with these prefixes is dropped so a
    /// user's shell setup (e.g. a CrossOver or Homebrew Wine) can't leak in.
    public static let ownedPrefixes = ["WINE", "DYLD_", "CX_", "D3DM", "DXMT_", "MTL_", "GST_", "ROSETTA_", "MVK_", "DXVK_", "AQUA_MEMORY"]

    public func baseEnvironment(engine: WineEngine) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !Self.ownedPrefixes.contains { key.hasPrefix($0) }
        }
        let fw = paths.frameworks.path
        env["WINESERVER"] = paths.wineserver(engine).path
        env["WINELOADER"] = paths.wine(engine).path
        env["WINEDEBUG"] = "-all"
        env["WINEMSYNC"] = "1"
        env["WINEESYNC"] = "0"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [
            fw,
            paths.d3dmetal.appendingPathComponent("external").path,
            fw + "/GStreamer.framework/Versions/1.0/lib",
            "/usr/lib",
        ].joined(separator: ":")
        return env
    }

    public func environment(bottle: Bottle, recipe: GameRecipe, settings: AquaSettings) -> [String: String] {
        var env = baseEnvironment(engine: bottle.engine)
        let fw = paths.frameworks
        let renderer = recipe.renderer ?? .d3dmetal
        env["WINEPREFIX"] = bottle.prefix.path
        // Wine searches its own lib dir before WINEDLLPATH, so renderers go through the
        // engines' dedicated variables, which are searched first.
        if let folder = renderer.frameworkFolder {
            let variable = bottle.engine.usesRendererVariables ? renderer.engineVariable : "WINEDLLPATH_PREPEND"
            env[variable ?? "WINEDLLPATH_PREPEND"] = fw.appendingPathComponent("renderer/\(folder)/wine").path
        }
        // Mesa's KosmicKrisp Vulkan driver. MoltenVK needs portability enumeration, which this Wine doesn't request.
        env["VK_DRIVER_FILES"] = paths.vulkanDriverManifest.path
        env["VK_ICD_FILENAMES"] = paths.vulkanDriverManifest.path
        // Same defaults as GameToMac: more address space for 32-bit games, and copy-on-write
        // emulation that some anti-tamper and engine code relies on.
        env["WINE_LARGE_ADDRESS_AWARE"] = "1"
        env["WINE_SIMULATE_WRITECOPY"] = "1"
        // CrossOver's Wine reports GPU hardware scheduling to DX12 games on D3DMetal.
        env["CX_ACTIVE_GRAPHICS_BACKEND"] = renderer.rawValue
        if recipe.advertiseAVX ?? true { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        env["MTL_HUD_ENABLED"] = settings.metalHUD ? "1" : "0"
        env["D3DM_ENABLE_METALFX"] = "0"
        env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = paths.d3dmetal.appendingPathComponent("external/libd3dshared.dylib").path
        env["MVK_CONFIG_LOG_LEVEL"] = "1"
        env["GST_PLUGIN_PATH"] = fw.appendingPathComponent("GStreamer.framework/Versions/1.0/lib/gstreamer-1.0").path
        env["GST_REGISTRY"] = bottle.root.appendingPathComponent("gstreamer-registry.bin").path
        env["SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"] = "1"
        // Read by Aqua's engine patch: the physical memory Windows programs are told about.
        if let limit = settings.memoryLimitGB { env["AQUA_MEMORY_LIMIT_MB"] = String(limit * 1024) }
        switch renderer {
        case .dxmt: env["DXMT_SHADER_CACHE_PATH"] = bottle.root.appendingPathComponent("shader-cache/dxmt").path
        case .dxvk: env["DXVK_STATE_CACHE_PATH"] = bottle.root.appendingPathComponent("shader-cache/dxvk").path
                    env["DXVK_LOG_LEVEL"] = "warn"
        default: break
        }

        var overrides = Self.baseOverrides.merging(renderer.dllOverrides) { $1 }
        overrides.merge(recipe.dllOverrides ?? [:]) { $1 }
        env["WINEDLLOVERRIDES"] = Self.formatOverrides(overrides)

        env.merge(recipe.environment ?? [:]) { $1 }
        return env
    }

    /// Never needed for games and slow or noisy under Wine.
    static let baseOverrides: [String: String] = [
        "winemenubuilder.exe": "",
        "mshtml": "",
        // Wine Mono isn't bundled yet; without this Wine stops to offer downloading it.
        "mscoree": "",
        "gameoverlayrenderer": "",
        "gameoverlayrenderer64": "",
    ].merging(vcRuntimeOverrides) { $1 }

    /// Prefer Microsoft's Visual C++ 2015-2022 runtime when a game or Steam has installed it.
    /// Wine otherwise loads its own builtin copies even over a game's bundled DLLs, and
    /// Unreal Engine's launcher then reports "Microsoft Visual C++ Runtime" as missing.
    /// Same set winetricks' vcrun2022 overrides; falls back to builtin when absent.
    static let vcRuntimeOverrides: [String: String] = Dictionary(uniqueKeysWithValues: [
        "concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait", "msvcp140_codecvt_ids",
        "vcamp140", "vccorlib140", "vcomp140", "vcruntime140", "vcruntime140_1",
    ].map { ($0, "n,b") })

    static func formatOverrides(_ overrides: [String: String]) -> String {
        overrides.keys.sorted().map { "\($0)=\(overrides[$0]!)" }.joined(separator: ";")
    }
}

extension Renderer {
    /// Directory (relative to Runtime/Frameworks/renderer) holding this renderer's PE DLLs.
    var frameworkFolder: String? {
        switch self {
        case .d3dmetal: return "d3dmetal"
        case .dxmt: return "dxmt"
        case .dxvk: return "dxvk"
        case .wined3d: return nil
        }
    }

    /// The engine variable that points Wine at this renderer's DLL folder.
    var engineVariable: String? {
        switch self {
        case .d3dmetal: return "WINEDLLPATH_D3DMETAL"
        case .dxmt: return "WINEDLLPATH_DXMT"
        case .dxvk: return "WINEDLLPATH_DXVK"
        case .wined3d: return nil
        }
    }

    /// DLLs this renderer provides.
    var dlls: [String] {
        switch self {
        case .d3dmetal: return ["dxgi", "d3d11", "d3d12", "atidxx64"]
        case .dxmt: return ["dxgi", "d3d11", "d3d10core", "winemetal"]
        case .dxvk: return ["dxgi", "d3d11", "d3d10core", "d3d9"]
        case .wined3d: return []
        }
    }

    var dllOverrides: [String: String] {
        let graphics = ["dxgi", "d3d9", "d3d10core", "d3d11", "d3d12", "atidxx64", "winemetal"]
        var map = Dictionary(uniqueKeysWithValues: graphics.map { ($0, "b") })
        // D3DMetal and DXMT are Wine-style builtins; DXVK ships plain Windows DLLs.
        if self == .dxvk { for dll in dlls { map[dll] = "n,b" } }
        if self == .d3dmetal {
            // Apple's NVIDIA shims confuse games that then expect DLSS.
            map["nvapi64"] = ""
            map["nvngx"] = ""
        }
        if self == .wined3d { map.removeValue(forKey: "atidxx64"); map.removeValue(forKey: "winemetal") }
        return map
    }
}
