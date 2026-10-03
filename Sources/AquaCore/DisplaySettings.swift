import Foundation
import CoreGraphics

/// A game setting Aqua writes before launch so the game renders at the display's resolution.
/// Values may use `{width}` and `{height}`: the display's pixel size in Retina mode, its point
/// size otherwise. Files are only edited if the game has already created them.
public struct DisplaySetting: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable {
        /// `<Key>value</Key>` elements.
        case xml
        /// `Key=value` lines (any section).
        case ini
        /// Valve key-values: `"key"  "value"`.
        case keyValues
        /// DWORD values under `registryKey` (Unity's `Screenmanager …` keys).
        case registry
    }

    public var format: Format
    /// Windows path. Supports %APPDATA%, %LOCALAPPDATA%, %USERPROFILE%, %DOCUMENTS%, %STEAM%,
    /// and `*` as a path segment wildcard.
    public var file: String?
    public var registryKey: String?
    public var values: [String: String]

    public init(format: Format, file: String? = nil, registryKey: String? = nil, values: [String: String]) {
        self.format = format
        self.file = file
        self.registryKey = registryKey
        self.values = values
    }
}

public struct DisplaySize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public static func main(retina: Bool) -> DisplaySize {
        let id = CGMainDisplayID()
        guard let mode = CGDisplayCopyDisplayMode(id) else {
            return DisplaySize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
        }
        return retina ? DisplaySize(width: mode.pixelWidth, height: mode.pixelHeight)
                      : DisplaySize(width: mode.width, height: mode.height)
    }

    func fill(_ template: String) -> String {
        template.replacingOccurrences(of: "{width}", with: String(width)).replacingOccurrences(of: "{height}", with: String(height))
    }
}

enum DisplaySettingsWriter {
    static func apply(_ settings: [DisplaySetting], size: DisplaySize, bottle: Bottle, runtime: WineRuntime) async throws {
        for setting in settings {
            let values = setting.values.mapValues(size.fill)
            if setting.format == .registry {
                guard let key = setting.registryKey else { continue }
                for (name, value) in values.sorted(by: { $0.key < $1.key }) {
                    try await bottle.reg(["add", key, "/v", name, "/t", "REG_DWORD", "/d", value, "/f"], using: runtime)
                }
                continue
            }
            guard let file = setting.file else { continue }
            for url in resolve(file, in: bottle) {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let updated = patch(text, format: setting.format, values: values)
                guard updated != text else { continue }
                let backup = url.appendingPathExtension("aqua-backup")
                if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: url, to: backup) }
                try updated.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    static func patch(_ text: String, format: DisplaySetting.Format, values: [String: String]) -> String {
        var text = text
        for (key, value) in values {
            let k = NSRegularExpression.escapedPattern(for: key)
            let v = NSRegularExpression.escapedTemplate(for: value)
            let pattern: String
            let template: String
            switch format {
            case .xml: pattern = "(<\(k)>)[^<]*(</\(k)>)"; template = "$1\(v)$2"
            case .ini: pattern = "(?m)^(\\s*\(k)\\s*=\\s*)[^\\r\\n]*"; template = "$1\(v)"
            case .keyValues: pattern = "(\"\(k)\"\\s+\")[^\"]*(\")"; template = "$1\(v)$2"
            case .registry: continue
            }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: format == .ini ? [.caseInsensitive] : []) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: template)
        }
        return text
    }

    /// Expands variables and `*` segments into existing files inside the bottle.
    static func resolve(_ windowsPath: String, in bottle: Bottle) -> [URL] {
        let user = bottle.driveC.appendingPathComponent("users").path
        let profile = (try? FileManager.default.contentsOfDirectory(atPath: user))?
            .first { !["Public", "crossover"].contains($0) }.map { "C:\\users\\\($0)" } ?? "C:\\users\\Public"
        var path = windowsPath
        for (name, value) in [("%APPDATA%", profile + "\\AppData\\Roaming"), ("%LOCALAPPDATA%", profile + "\\AppData\\Local"),
                              ("%DOCUMENTS%", profile + "\\Documents"), ("%USERPROFILE%", profile),
                              ("%STEAM%", "C:\\Program Files (x86)\\Steam")] {
            path = path.replacingOccurrences(of: name, with: value)
        }
        let start = bottle.unixPath(forWindowsPath: String(path.prefix(3)))
        let segments = path.dropFirst(3).split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        var matches = [start]
        for segment in segments {
            matches = matches.flatMap { base -> [URL] in
                guard segment.contains("*") else { return [base.appendingPathComponent(segment)] }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
                let regex = "^" + NSRegularExpression.escapedPattern(for: segment).replacingOccurrences(of: "\\*", with: ".*") + "$"
                return names.filter { $0.range(of: regex, options: .regularExpression) != nil }.map { base.appendingPathComponent($0) }
            }
        }
        return matches.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
