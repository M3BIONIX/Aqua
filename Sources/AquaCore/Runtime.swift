import Foundation

/// Pinned downloads. Hashes match the published release assets.
public struct RuntimeComponent: Sendable {
    public let name: String
    public let version: String
    public let url: URL
    public let sha256: String
    /// Folder inside the archive that holds the component.
    public let archiveRoot: String
    public var fileName: String { url.lastPathComponent }
}

public enum RuntimeComponents {
    /// Where Aqua's own builds (the engine) are published.
    public static let releaseBase = "https://github.com/M3BIONIX/Aqua/releases/download"

    /// Aqua Wine: CodeWeavers' CrossOver 26.3 Wine with Aqua's patches, built by Engine/build-engine.sh.
    public static let aquaEngine = RuntimeComponent(
        name: "Aqua Wine", version: "CrossOver 26.3.0 r4",
        url: URL(string: "\(releaseBase)/engine-cx26.3.0-r4/aqua-wine-cx26.3.0-r4.tar.xz")!,
        sha256: "3ffa355235c84b458a2cb6484249f841e61c3ff92385969faa9bc3bc78419cb5", archiveRoot: "AquaWine")

    /// Sikarugir Wine 10.0. Its 11.0 builds fail to start Windows processes on macOS 26.5.
    public static let engine = RuntimeComponent(
        name: "Wine 10 engine", version: "Sikarugir Wine 10.0 r8",
        url: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_8.tar.xz")!,
        sha256: "2a6bcf2a3bf13cddf825599b6bc1e3659cbf71e1282c6d77141a92f6ac8d4c68", archiveRoot: "wswine.bundle")

    /// Sikarugir's build of CrossOver 24.0.7's Wine.
    public static let crossoverEngine = RuntimeComponent(
        name: "CrossOver 24 engine", version: "Sikarugir WineCX 24.0.7 r6",
        url: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineCX24.0.7_7.tar.xz")!,
        sha256: "203f9e9fd6c2cc77e6525d798a434ced326145db34a356355e05659d3445fd1c", archiveRoot: "wswine.bundle")

    /// Sikarugir wrapper template: D3DMetal, DXMT, DXVK, MoltenVK, GStreamer and Wine's dylib dependencies.
    public static let frameworks = RuntimeComponent(
        name: "Graphics and libraries", version: "Sikarugir Template 1.0.21",
        url: URL(string: "https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.21.tar.xz")!,
        sha256: "bbe996e4e4375318485953d0c7818b7b4b0a4dc1f13303bcc584f99f7602f78d",
        archiveRoot: "Template-1.0.21.app/Contents/Frameworks")

    /// legendary 0.21.1 native arm64 build (Epic Games Store client).
    public static let legendary = RuntimeComponent(
        name: "legendary", version: "0.21.1",
        url: URL(string: "https://github.com/derrod/legendary/releases/download/0.21.1/legendary_macOS_arm64")!,
        sha256: "d87978321dba9cb731fab40c72f0a30bed55baca8b5341ab21024c5733cd837e", archiveRoot: "")
}

public struct HostCheck: Sendable {
    public let isAppleSilicon: Bool
    public let macOSVersion: OperatingSystemVersion
    public let rosettaInstalled: Bool

    public var problems: [String] {
        var list: [String] = []
        if !isAppleSilicon { list.append("Aqua requires an Apple Silicon Mac.") }
        if macOSVersion.majorVersion < 14 { list.append("D3DMetal requires macOS 14 Sonoma or later.") }
        if !rosettaInstalled { list.append("Rosetta 2 is not installed. Install it with: softwareupdate --install-rosetta --agree-to-license") }
        return list
    }

    public static func current() async -> HostCheck {
        #if arch(arm64)
        let arm = true
        #else
        let arm = false
        #endif
        // `arch -x86_64` fails with "Bad CPU type" when Rosetta is missing.
        let rosetta = (try? await Shell.run(URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", "/usr/bin/true"], timeout: 20)) != nil
        return HostCheck(isAppleSilicon: arm, macOSVersion: ProcessInfo.processInfo.operatingSystemVersion, rosettaInstalled: rosetta)
    }
}

public struct RuntimeProgress: Sendable {
    public var step: String
    public var fraction: Double?
}

/// Downloads, verifies and unpacks the Wine engine and graphics frameworks into `Runtime/`.
public final class RuntimeInstaller: @unchecked Sendable {
    public let paths: AquaPaths
    public init(paths: AquaPaths = .shared) { self.paths = paths }

    private var markerFile: URL { paths.runtime.appendingPathComponent("installed.json") }

    /// Graphics frameworks plus the default engine.
    public var isInstalled: Bool {
        guard let data = try? Data(contentsOf: markerFile),
              let marker = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return marker["frameworks"] == RuntimeComponents.frameworks.sha256
            && isInstalled(.default)
            && FileManager.default.fileExists(atPath: paths.vulkanDriverManifest.path)
    }

    public func isInstalled(_ engine: WineEngine) -> Bool {
        let marker = paths.engine(engine).appendingPathComponent(".aqua-sha256")
        return (try? String(contentsOf: marker, encoding: .utf8)) == engine.component.sha256
            && FileManager.default.isExecutableFile(atPath: paths.wine(engine).path)
    }

    /// True while any wineserver from one of Aqua's engines is alive (Steam, a game, an installer).
    public func engineInUse() async -> Bool {
        // Wine starts the server as `<engine>/lib/wine/../../bin/wineserver`, so match the engine folder.
        let pattern = NSRegularExpression.escapedPattern(for: paths.runtime.path + "/Engine") + ".*wineserver"
        let result = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-f", pattern], allowedStatus: [0, 1])
        return result?.status == 0
    }

    public func install(progress: @escaping @Sendable (RuntimeProgress) -> Void) async throws {
        if await engineInUse() { throw AquaError("Quit Steam and any running games before reinstalling the runtime.") }
        try paths.ensure(paths.runtime)
        if !frameworksInstalled {
            try await unpack(RuntimeComponents.frameworks, into: paths.frameworks, progress: progress)
            try writeVulkanManifest()
            try JSONEncoder().encode(["frameworks": RuntimeComponents.frameworks.sha256]).write(to: markerFile, options: .atomic)
        }
        try await install(.default, progress: progress)
        progress(RuntimeProgress(step: "Runtime ready", fraction: 1))
    }

    private var frameworksInstalled: Bool {
        guard let data = try? Data(contentsOf: markerFile),
              let marker = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return marker["frameworks"] == RuntimeComponents.frameworks.sha256
    }

    /// Installs an engine if it isn't already, and checks that Wine starts.
    public func install(_ engine: WineEngine, progress: (@Sendable (RuntimeProgress) -> Void)? = nil) async throws {
        guard !isInstalled(engine) else { return }
        let destination = paths.engine(engine)
        try await unpack(engine.component, into: destination, progress: progress)
        progress?(RuntimeProgress(step: "Checking \(engine.displayName)…", fraction: nil))
        let version = try await Shell.run(paths.wine(engine), ["--version"],
                                          environment: WineRuntime(paths: paths).baseEnvironment(engine: engine), timeout: 60)
        guard version.output.lowercased().contains("wine") else {
            throw AquaError("\(engine.displayName) failed its startup check:\n\(version.output)")
        }
        try engine.component.sha256.write(to: destination.appendingPathComponent(".aqua-sha256"), atomically: true, encoding: .utf8)
    }

    /// Downloads (or reuses) a verified archive and swaps its content into place.
    private func unpack(_ component: RuntimeComponent, into destination: URL,
                        progress: (@Sendable (RuntimeProgress) -> Void)?) async throws {
        let archive = paths.downloads.appendingPathComponent(component.fileName)
        progress?(RuntimeProgress(step: "Downloading \(component.name)…", fraction: 0))
        try await Downloader.fetch(component.url, to: archive, sha256: component.sha256) { received, total in
            progress?(RuntimeProgress(step: "Downloading \(component.name)…", fraction: total > 0 ? Double(received) / Double(total) : nil))
        }
        progress?(RuntimeProgress(step: "Unpacking \(component.name)…", fraction: nil))
        let staging = paths.runtime.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try paths.ensure(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        // Gecko (Internet Explorer engine) is only needed by apps embedding IE.
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/tar"),
                            ["-xf", archive.path, "-C", staging.path, "--exclude", "*/share/wine/gecko", component.archiveRoot], timeout: 900)
        let source = staging.appendingPathComponent(component.archiveRoot)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AquaError("The \(component.name) package has an unexpected layout.")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", destination.path], allowedStatus: [0, 1])
    }

    func writeVulkanManifest() throws {
        let manifest: [String: Any] = [
            "file_format_version": "1.0.1",
            "ICD": ["library_path": paths.frameworks.appendingPathComponent("libvulkan_kosmickrisp.dylib").path, "api_version": "1.4.363"],
        ]
        try paths.ensure(paths.vulkanDriverManifest.deletingLastPathComponent())
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
            .write(to: paths.vulkanDriverManifest, options: .atomic)
    }

    /// Size on disk of the installed runtime, for the settings screen.
    public func installedSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: paths.runtime, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
