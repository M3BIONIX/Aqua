import Foundation

/// Minimal parser for Valve's text KeyValues format (`.acf`, `.vdf`).
public indirect enum VDF: Equatable, Sendable {
    case string(String)
    case object([(String, VDF)])

    public static func == (lhs: VDF, rhs: VDF) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.object(a), .object(b)): return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public subscript(key: String) -> VDF? {
        guard case let .object(pairs) = self else { return nil }
        return pairs.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
    }

    public var string: String? { if case let .string(s) = self { return s }; return nil }
    public var pairs: [(String, VDF)] { if case let .object(p) = self { return p }; return [] }

    public static func parse(_ text: String) throws -> VDF {
        var parser = Parser(Array(text.unicodeScalars))
        return .object(try parser.parsePairs(topLevel: true))
    }

    private struct Parser {
        let chars: [Unicode.Scalar]
        var i = 0
        init(_ chars: [Unicode.Scalar]) { self.chars = chars }

        mutating func skip() {
            while i < chars.count {
                let c = chars[i]
                if CharacterSet.whitespacesAndNewlines.contains(c) { i += 1; continue }
                if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                break
            }
        }

        mutating func token() throws -> String? {
            skip()
            guard i < chars.count else { return nil }
            if chars[i] == "{" || chars[i] == "}" { return nil }
            var out = String.UnicodeScalarView()
            if chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        default: out.append(chars[i])
                        }
                    } else {
                        out.append(chars[i])
                    }
                    i += 1
                }
                guard i < chars.count else { throw AquaError("Unterminated string in VDF") }
                i += 1
            } else {
                while i < chars.count, !CharacterSet.whitespacesAndNewlines.contains(chars[i]),
                      chars[i] != "{", chars[i] != "}", chars[i] != "\"" {
                    out.append(chars[i]); i += 1
                }
            }
            return String(out)
        }

        mutating func parsePairs(topLevel: Bool) throws -> [(String, VDF)] {
            var result: [(String, VDF)] = []
            while true {
                skip()
                guard i < chars.count else {
                    if topLevel { return result }
                    throw AquaError("Unexpected end of VDF")
                }
                if chars[i] == "}" {
                    if topLevel { throw AquaError("Unexpected } in VDF") }
                    i += 1
                    return result
                }
                guard let key = try token() else { throw AquaError("Expected key in VDF") }
                skip()
                guard i < chars.count else { throw AquaError("Missing value for \(key)") }
                if chars[i] == "{" {
                    i += 1
                    result.append((key, .object(try parsePairs(topLevel: false))))
                } else if let value = try token() {
                    result.append((key, .string(value)))
                } else {
                    throw AquaError("Missing value for \(key)")
                }
            }
        }
    }
}
