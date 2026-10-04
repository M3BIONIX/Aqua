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
    /// and `*` within a path segment as a wildcard.
    public var file: String?
    /// For `ini`: keys missing from the file are added under this section, and the file is
    /// created if its folder exists. Without a section only existing keys are changed.
    public var section: String?
    public var registryKey: String?
    public var values: [String: String]

    public init(format: Format, file: String? = nil, section: String? = nil, registryKey: String? = nil, values: [String: String]) {
        self.format = format
        self.file = file
        self.section = section
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
            var targets = resolve(file, in: bottle)
            if targets.isEmpty, setting.format == .ini, setting.section != nil {
                // Create the file in each existing folder it belongs in.
                let name = file.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
                let folder = String(file.dropLast(name.count))
                targets = resolve(folder, in: bottle).filter { $0.hasDirectoryPath || isDirectory($0) }.map { $0.appendingPathComponent(name) }
            }
            for url in targets {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (FileManager.default.fileExists(atPath: url.path) ? nil : "")
                guard let text else { continue }
                let updated = patch(text, format: setting.format, values: values, section: setting.section)
                guard updated != text else { continue }
                let backup = url.appendingPathExtension("aqua-backup")
                if !text.isEmpty, !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: url, to: backup) }
                try updated.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    static func patch(_ text: String, format: DisplaySetting.Format, values: [String: String], section: String? = nil) -> String {
        var text = text
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            if format == .ini, let section, !hasINIKey(key, in: text) {
                text = insertINI(key: key, value: value, section: section, into: text)
                continue
            }
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

    static func hasINIKey(_ key: String, in text: String) -> Bool {
        let pattern = "(?m)^\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*="
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Adds `key=value` at the end of `[section]`, creating the section if needed.
    static func insertINI(key: String, value: String, section: String, into text: String) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let header = "[\(section)]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(header) == .orderedSame }) else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines += [header, "\(key)=\(value)"]
            return lines.joined(separator: "\n") + "\n"
        }
        var end = lines[(start + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.endIndex
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        lines.insert("\(key)=\(value)", at: end)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The Windows user folder the bottle's programs run as. CrossOver-based engines use
    /// `crossover`, plain Wine uses the Mac user name; the registry says which.
    static func profileFolder(in bottle: Bottle) -> String {
        let users = bottle.driveC.appendingPathComponent("users").path
        if let registry = try? String(contentsOf: bottle.prefix.appendingPathComponent("user.reg"), encoding: .utf8),
           let range = registry.range(of: #""USERPROFILE"="C:\\\\users\\\\([^"\\]+)""#, options: .regularExpression) {
            let name = registry[range].components(separatedBy: "\\\\").last?.dropLast() ?? ""
            if !name.isEmpty, FileManager.default.fileExists(atPath: users + "/" + name) { return "C:\\users\\\(name)" }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: users)) ?? []
        if let name = names.first(where: { !["Public", "crossover"].contains($0) }) ?? names.first(where: { $0 == "crossover" }) {
            return "C:\\users\\\(name)"
        }
        return "C:\\users\\Public"
    }

    /// Expands variables and `*` segments into existing files inside the bottle.
    static func resolve(_ windowsPath: String, in bottle: Bottle) -> [URL] {
        let profile = profileFolder(in: bottle)
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

extension Bottle {
    /// The Windows user folder games in this bottle save their settings under (`C:\users\<name>`).
    public var windowsUserFolder: URL { unixPath(forWindowsPath: DisplaySettingsWriter.profileFolder(in: self)) }
}
