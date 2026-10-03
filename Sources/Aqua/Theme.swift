import AppKit
import SwiftUI
import AquaCore

enum Theme {
    static let background = Color(hex: 0x090A0D)
    static let sidebar = Color(hex: 0x0D0F13)
    static let panel = Color(hex: 0x101217)
    static let raised = Color(hex: 0x13161C)
    static let selected = Color(hex: 0x171B23)
    static let control = Color(hex: 0x1B1F27)
    static let placeholder = Color(hex: 0x161920)
    static let track = Color(hex: 0x232833)
    static let border = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.06)
    static let text = Color(hex: 0xECEEF2)
    static let secondaryText = Color(hex: 0xAEB5C1)
    static let mutedText = Color(hex: 0x8B93A1)
    static let faintText = Color(hex: 0x6B7380)
    static let accent = Color(hex: 0x2563EB)
    static let accentText = Color(hex: 0x5B9BFF)
    static let danger = Color(hex: 0xF0616D)
    static let radius: CGFloat = 6
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

extension Font {
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .semibold, .bold, .heavy, .black: name = "Geist-SemiBold"
        case .medium: name = "Geist-Medium"
        default: name = "Geist-Regular"
        }
        return AquaFonts.available ? .custom(name, fixedSize: size) : .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = weight == .regular ? "GeistMono-Regular" : "GeistMono-Medium"
        return AquaFonts.available ? .custom(name, fixedSize: size) : .system(size: size, weight: weight, design: .monospaced)
    }
}

enum AquaFonts {
    private(set) static var available = false

    static func register() {
        guard let folder = Bundle.resources(named: "Aqua_Aqua", fallback: { .module }).url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let fonts = files.filter { $0.pathExtension == "ttf" } as CFArray
        CTFontManagerRegisterFontURLs(fonts, .process, true, nil)
        available = NSFont(name: "Geist-Regular", size: 12) != nil
    }
}

// MARK: Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(height >= 40 ? 15 : 13, .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, height >= 40 ? 20 : 16)
            .frame(height: height)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Theme.radius))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(13, .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(Theme.control.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Color.white.opacity(0.1)))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Rectangle())
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .frame(width: size, height: size)
            .background(Theme.control.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Color.white.opacity(0.1)))
            .contentShape(Rectangle())
    }
}

/// Plain text that acts as a button, for status lines and inline actions.
struct LinkButtonStyle: ButtonStyle {
    var color = Theme.accentText

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.7 : 1))
            .contentShape(Rectangle())
    }
}

// MARK: Pieces

struct ProgressLine: View {
    var fraction: Double
    var height: CGFloat = 3
    var color = Theme.accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.track)
                Rectangle().fill(color).frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// Aqua's mark: three nested drops, the same drawing as the app icon (Tools/logo.swift).
struct BrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            DropShape().fill(Color(hex: 0x3B82F6)).frame(width: size * 0.656, height: size)
            DropShape().fill(Color(hex: 0xA8C6FE)).frame(width: size * 0.48, height: size * 0.732).offset(y: size * 0.075)
            DropShape().fill(Color.white).frame(width: size * 0.336, height: size * 0.512).offset(y: size * 0.142)
        }
        .frame(width: size, height: size)
    }
}

/// A circle with a point above it; the sides are tangent to the circle.
struct DropShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width / 2
        let c = CGPoint(x: rect.midX, y: rect.maxY - r)
        let tip = CGPoint(x: rect.midX, y: rect.minY)
        let half = acos(r / (c.y - tip.y))
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: c.x + r * sin(half), y: c.y - r * cos(half)))
        path.addArc(center: c, radius: r, startAngle: .radians(-.pi / 2 + half), endAngle: .radians(3 * .pi / 2 - half), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct StoreLogo: View {
    let store: Store
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: store == .steam ? Self.steam : Self.epic)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    private static func template(_ svg: String) -> NSImage {
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }

    // Phosphor "steam-logo-fill" (MIT) and Simple Icons "epicgames" (CC0).
    private static let steam = template(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><path fill="#000" d="M231.92,132.11c-2.09,54-45.83,97.72-99.81,99.81A104.06,104.06,0,0,1,25.6,109.76a4,4,0,0,1,6.77-2.08l43,43a28,28,0,0,0,42.42,34.92l61.1-49.84a36,36,0,1,0-50.71-50.65l-43,52.74L35,87.67a4,4,0,0,1-.76-4.6,104,104,0,0,1,197.7,49ZM121.58,118.55,90.77,156.33A11.83,11.83,0,0,0,88,163.19,12.19,12.19,0,0,0,99.85,176a11.84,11.84,0,0,0,7.78-2.74l0,0,37.78-30.81A36.18,36.18,0,0,1,121.58,118.55ZM175.9,110A20,20,0,1,0,158,127.9,20,20,0,0,0,175.9,110Z"/></svg>"##)
    private static let epic = template(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#000" d="M3.537 0C2.165 0 1.66.506 1.66 1.879V18.44a4.262 4.262 0 00.02.433c.031.3.037.59.316.92.027.033.311.245.311.245.153.075.258.13.43.2l8.335 3.491c.433.199.614.276.928.27h.002c.314.006.495-.071.928-.27l8.335-3.492c.172-.07.277-.124.43-.2 0 0 .284-.211.311-.243.28-.33.285-.621.316-.92a4.261 4.261 0 00.02-.434V1.879c0-1.373-.506-1.88-1.878-1.88zm13.366 3.11h.68c1.138 0 1.688.553 1.688 1.696v1.88h-1.374v-1.8c0-.369-.17-.54-.523-.54h-.235c-.367 0-.537.17-.537.539v5.81c0 .369.17.54.537.54h.262c.353 0 .523-.171.523-.54V8.619h1.373v2.143c0 1.144-.562 1.71-1.7 1.71h-.694c-1.138 0-1.7-.566-1.7-1.71V4.82c0-1.144.562-1.709 1.7-1.709zm-12.186.08h3.114v1.274H6.117v2.603h1.648v1.275H6.117v2.774h1.74v1.275h-3.14zm3.816 0h2.198c1.138 0 1.7.564 1.7 1.708v2.445c0 1.144-.562 1.71-1.7 1.71h-.799v3.338h-1.4zm4.53 0h1.4v9.201h-1.4zm-3.13 1.235v3.392h.575c.354 0 .523-.171.523-.54V4.965c0-.368-.17-.54-.523-.54zm-3.74 10.147a1.708 1.708 0 01.591.108 1.745 1.745 0 01.49.299l-.452.546a1.247 1.247 0 00-.308-.195.91.91 0 00-.363-.068.658.658 0 00-.28.06.703.703 0 00-.224.163.783.783 0 00-.151.243.799.799 0 00-.056.299v.008a.852.852 0 00.056.31.7.7 0 00.157.245.736.736 0 00.238.16.774.774 0 00.303.058.79.79 0 00.445-.116v-.339h-.548v-.565H7.37v1.255a2.019 2.019 0 01-.524.307 1.789 1.789 0 01-.683.123 1.642 1.642 0 01-.602-.107 1.46 1.46 0 01-.478-.3 1.371 1.371 0 01-.318-.455 1.438 1.438 0 01-.115-.58v-.008a1.426 1.426 0 01.113-.57 1.449 1.449 0 01.312-.46 1.418 1.418 0 01.474-.309 1.58 1.58 0 01.598-.111 1.708 1.708 0 01.045 0zm11.963.008a2.006 2.006 0 01.612.094 1.61 1.61 0 01.507.277l-.386.546a1.562 1.562 0 00-.39-.205 1.178 1.178 0 00-.388-.07.347.347 0 00-.208.052.154.154 0 00-.07.127v.008a.158.158 0 00.022.084.198.198 0 00.076.066.831.831 0 00.147.06c.062.02.14.04.236.061a3.389 3.389 0 01.43.122 1.292 1.292 0 01.328.17.678.678 0 01.207.24.739.739 0 01.071.337v.008a.865.865 0 01-.081.382.82.82 0 01-.229.285 1.032 1.032 0 01-.353.18 1.606 1.606 0 01-.46.061 2.16 2.16 0 01-.71-.116 1.718 1.718 0 01-.593-.346l.43-.514c.277.223.578.335.9.335a.457.457 0 00.236-.05.157.157 0 00.082-.142v-.008a.15.15 0 00-.02-.077.204.204 0 00-.073-.066.753.753 0 00-.143-.062 2.45 2.45 0 00-.233-.062 5.036 5.036 0 01-.413-.113 1.26 1.26 0 01-.331-.16.72.72 0 01-.222-.243.73.73 0 01-.082-.36v-.008a.863.863 0 01.074-.359.794.794 0 01.214-.283 1.007 1.007 0 01.34-.185 1.423 1.423 0 01.448-.066 2.006 2.006 0 01.025 0zm-9.358.025h.742l1.183 2.81h-.825l-.203-.499H8.623l-.198.498h-.81zm2.197.02h.814l.663 1.08.663-1.08h.814v2.79h-.766v-1.602l-.711 1.091h-.016l-.707-1.083v1.593h-.754zm3.469 0h2.235v.658h-1.473v.422h1.334v.61h-1.334v.442h1.493v.658h-2.255zm-5.3.897l-.315.793h.624zm-1.145 5.19h8.014l-4.09 1.348z"/></svg>"##)
}

/// Game art with an in-memory cache so the library grid scrolls without reloading.
struct ArtworkImage: View {
    let url: URL?
    var title: String? = nil
    @State private var image: NSImage?

    var body: some View {
        // The placeholder sets the size; the image fills it without changing the layout.
        Theme.placeholder
            .overlay {
                // Art scaled to fill spills past the frame; clipping hides it but doesn't stop it taking clicks.
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().allowsHitTesting(false)
                } else if let title {
                    Text(title)
                        .font(.geist(14, .medium))
                        .foregroundStyle(Theme.mutedText)
                        .multilineTextAlignment(.center)
                        .padding(12)
                }
            }
            .clipped()
            .contentShape(Rectangle())
        .task(id: url) {
            guard let url else { image = nil; return }
            image = ImageStore.shared.cached(url)
            if image == nil { image = await ImageStore.shared.load(url) }
        }
    }
}

@MainActor
final class ImageStore {
    static let shared = ImageStore()
    private let cache = NSCache<NSURL, NSImage>()
    private var loading: [URL: Task<NSImage?, Never>] = [:]

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        if let task = loading[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
            return NSImage(data: data)
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

// MARK: Formatting

enum Format {
    static func bytes(_ value: Int64) -> String {
        let gb = Double(value) / 1_000_000_000
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", max(0, Double(value) / 1_000_000))
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytesPerSecond >= 1_000_000_000 ? String(format: "%.2f GB/s", bytesPerSecond / 1_000_000_000)
            : String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }

    static func duration(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600) h \(seconds % 3600 / 60) min" }
        if seconds >= 60 { return "\(seconds / 60) min \(seconds % 60) s" }
        return "\(seconds) s"
    }

    static func playtime(_ seconds: Double) -> String {
        seconds >= 3600 ? "\(Int(seconds / 3600)) h" : "\(max(1, Int(seconds / 60))) min"
    }

    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
        return days < 30 ? "\(days) days ago" : date.formatted(date: .abbreviated, time: .omitted)
    }

    static func ago(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return relative(date)
    }
}

struct Hoverable<Content: View>: View {
    @State private var hovering = false
    let content: (Bool) -> Content

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}
