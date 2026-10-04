import Foundation

/// Converts launch options to and from the plain text people edit in the app.
public enum LaunchOptionsText {
    /// `KEY=value` lines. Blank lines and lines starting with `#` are ignored.
    public static func parsePairs(_ text: String) -> [String: String] {
        var pairs: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            pairs[key] = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return pairs
    }

    public static func formatPairs(_ pairs: [String: String]?) -> String {
        (pairs ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    /// Splits launch arguments on spaces, keeping "quoted parts" together.
    public static func parseArguments(_ text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken { arguments.append(current); current = ""; hasToken = false }
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { arguments.append(current) }
        return arguments
    }

    public static func formatArguments(_ arguments: [String]?) -> String {
        (arguments ?? []).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    /// Settings files as blocks: a Windows path line, an optional `[Section]` line, then
    /// `key=value` lines. A section starts a new entry for the same file.
    ///
    ///     %LOCALAPPDATA%\Game\Saved\Config\WindowsNoEditor\Engine.ini
    ///     [SystemSettings]
    ///     r.WarnOfBadDrivers=0
    public static func parseFiles(_ text: String) -> [DisplaySetting] {
        var settings: [DisplaySetting] = []
        var file: String?
        var section: String?
        var values: [String: String] = [:]
        func flush() {
            if let file, !values.isEmpty { settings.append(DisplaySetting(format: .ini, file: file, section: section, values: values)) }
            values = [:]
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                flush()
                section = String(trimmed.dropFirst().dropLast())
            } else if let equals = trimmed.firstIndex(of: "="), file != nil, !looksLikePath(trimmed) {
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { values[key] = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces) }
            } else {
                flush()
                file = trimmed
                section = nil
            }
        }
        flush()
        return settings
    }

    public static func formatFiles(_ settings: [DisplaySetting]?) -> String {
        var blocks: [String] = []
        var lastFile: String?
        for setting in settings ?? [] where setting.format == .ini {
            guard let file = setting.file else { continue }
            var lines: [String] = []
            if file != lastFile { lines.append(file) }
            if let section = setting.section { lines.append("[\(section)]") }
            lines += setting.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            blocks.append(lines.joined(separator: "\n"))
            lastFile = file
        }
        return blocks.joined(separator: "\n")
    }

    private static func looksLikePath(_ line: String) -> Bool {
        line.hasPrefix("%") || line.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil
    }
}
