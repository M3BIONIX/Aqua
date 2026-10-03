import Foundation

/// The Wine build a bottle runs on. A bottle's engine follows from its name, so switching
/// engines means a different bottle; Wine would otherwise rewrite the prefix each time.
public enum WineEngine: String, Codable, CaseIterable, Sendable {
    /// Aqua's own build of CodeWeavers' CrossOver 26.3 Wine (Wine 11). Default.
    case aqua
    /// Sikarugir Wine 10.0. Fallback.
    case wine10
    /// Sikarugir build of CrossOver 24.0.7's Wine. Fallback.
    case crossover24

    public static let `default` = WineEngine.aqua

    public var displayName: String {
        switch self {
        case .aqua: return "Aqua Wine (CrossOver 26.3)"
        case .wine10: return "Wine 10"
        case .crossover24: return "CrossOver 24"
        }
    }

    var component: RuntimeComponent {
        switch self {
        case .aqua: return RuntimeComponents.aquaEngine
        case .wine10: return RuntimeComponents.engine
        case .crossover24: return RuntimeComponents.crossoverEngine
        }
    }

    /// Selects renderers through Sikarugir's per-renderer variables (`WINEDLLPATH_D3DMETAL`…)
    /// rather than `WINEDLLPATH_PREPEND`.
    var usesRendererVariables: Bool { self == .wine10 }

    /// Bottle names on this engine: `epic`, `epic-wine10`, `epic-crossover`.
    var bottleSuffix: String {
        switch self {
        case .aqua: return ""
        case .wine10: return "-wine10"
        case .crossover24: return "-crossover"
        }
    }

    static func of(bottleName name: String) -> WineEngine {
        allCases.first { !$0.bottleSuffix.isEmpty && name.hasSuffix($0.bottleSuffix) } ?? .default
    }
}

extension AquaPaths {
    public func engine(_ engine: WineEngine) -> URL {
        engine == .wine10 ? self.engine : runtime.appendingPathComponent("Engine-\(engine.rawValue)", isDirectory: true)
    }
    public func wine(_ engine: WineEngine) -> URL { self.engine(engine).appendingPathComponent("bin/wine") }
    public func wineserver(_ engine: WineEngine) -> URL { self.engine(engine).appendingPathComponent("bin/wineserver") }
}
