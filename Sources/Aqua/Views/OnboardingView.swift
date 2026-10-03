import SwiftUI
import AquaCore

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let step = model.onboardingStep
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("Step \(step) of 2").font(.mono(13)).foregroundStyle(Theme.mutedText)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)

            if step == 1 {
                ConnectStoresStep { model.onboardingStep = 2 }
            } else {
                StorageStep(back: { model.onboardingStep = 1 })
            }
        }
        .task { model.ensureRuntime() }
    }
}

private struct OnboardingIntro: View {
    let headline: String
    let subtext: String

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                BrandMark(size: 26)
                Text("Aqua").font(.geist(18, .semibold)).tracking(-0.18)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text(headline)
                    .font(.geist(44, .semibold))
                    .tracking(-1.32)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtext)
                    .font(.geist(16))
                    .foregroundStyle(Theme.mutedText)
                    .lineSpacing(5)
                    .frame(maxWidth: 470, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Step 1

private struct ConnectStoresStep: View {
    @EnvironmentObject var model: AppModel
    let next: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingIntro(headline: "Bring your Windows library to this Mac",
                                subtext: "Sign in to Steam, Epic Games, or both. Aqua runs their Windows versions for you, so there is nothing else to install.")
                VStack(spacing: 0) {
                    StoreRow(store: .epic)
                    Rectangle().fill(Theme.border).frame(height: 1)
                    StoreRow(store: .steam)
                }
                .padding(.top, 56)
                Spacer(minLength: 32)
                HStack {
                    Text(model.hasAnyAccount ? "You can add the other store later in Settings." : "One store is enough to continue.")
                        .font(.geist(14))
                        .foregroundStyle(Theme.mutedText)
                    Spacer()
                    Button(action: next) {
                        HStack(spacing: 8) {
                            Text("Continue")
                            Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 44))
                    .disabled(!model.hasAnyAccount)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(EdgeInsets(top: 56, leading: 88, bottom: 48, trailing: 48))
            .frame(width: 640)
            .frame(maxHeight: .infinity, alignment: .top)

            CoverWall()
        }
    }
}

private struct StoreRow: View {
    @EnvironmentObject var model: AppModel
    let store: Store

    var body: some View {
        HStack(spacing: 16) {
            StoreLogo(store: store, size: store == .steam ? 24 : 22)
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 44)
                .background(Theme.placeholder, in: RoundedRectangle(cornerRadius: Theme.radius))
            VStack(alignment: .leading, spacing: 4) {
                Text(store.displayName).font(.geist(16, .medium))
                status
            }
            Spacer()
            action
        }
        .padding(.vertical, 22)
    }

    private var account: String? { store == .steam ? model.steamAccount : model.epicAccount }

    @ViewBuilder
    private var status: some View {
        if let account {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accentText)
                Text(signedInText(account)).font(.geist(14)).foregroundStyle(Theme.mutedText)
            }
        } else if store == .steam, let progress = model.steamProgress {
            VStack(alignment: .leading, spacing: 6) {
                Text(progress.fraction.map { "\(progress.message), \(Int($0 * 100))%" } ?? progress.message)
                    .font(.geist(14)).foregroundStyle(Theme.mutedText)
                if let fraction = progress.fraction { ProgressLine(fraction: fraction, height: 2).frame(width: 220) }
            }
        } else if store == .steam, model.steamAwaitingSignIn {
            Text("Finish signing in in the Steam window").font(.geist(14)).foregroundStyle(Theme.accentText)
        } else if store == .epic, !model.epicChecked {
            Text("Checking…").font(.geist(14)).foregroundStyle(Theme.mutedText)
        } else {
            Text("Not signed in").font(.geist(14)).foregroundStyle(Theme.mutedText)
        }
    }

    private func signedInText(_ account: String) -> String {
        let count = store == .steam ? model.steamGames.count : model.epicGames.count
        return count > 0 ? "Signed in as \(account), \(count) games" : "Signed in as \(account)"
    }

    @ViewBuilder
    private var action: some View {
        switch store {
        case .epic:
            if model.epicAccount != nil {
                Button("Sign out") { model.logoutEpic() }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Sign in to Epic") { model.showEpicLogin = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.epicChecked)
            }
        case .steam:
            if model.steamAccount != nil {
                Button("Open Steam") { model.openSteam() }.buttonStyle(SecondaryButtonStyle())
            } else if model.steamAwaitingSignIn {
                Button("Show Steam") { model.openSteam() }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Sign in to Steam") { model.connectSteam() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.steamProgress != nil || !(model.host?.problems.isEmpty ?? false))
            }
        }
    }
}

/// Tall covers in three staggered columns, from the user's library once it has loaded.
private struct CoverWall: View {
    @EnvironmentObject var model: AppModel
    private static let fallback = ["730", "1245620", "990080", "292030", "1172470", "227300",
                                   "397540", "750920", "578080", "1248130", "1938090", "489830"]

    var body: some View {
        GeometryReader { proxy in
            let width = (proxy.size.width - 24 - 28) / 3
            let height = width * 1.5
            let covers = urls
            HStack(alignment: .top, spacing: 14) {
                ForEach(0..<3, id: \.self) { column in
                    VStack(spacing: 14) {
                        ForEach(0..<4, id: \.self) { row in
                            ArtworkImage(url: covers[(column * 4 + row) % covers.count])
                                .frame(width: width, height: height)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        }
                    }
                    .offset(y: [-60, -220, -120][column])
                }
            }
            .padding(.trailing, 24)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .overlay {
                LinearGradient(stops: [.init(color: Theme.background, location: 0), .init(color: Theme.background.opacity(0.55), location: 0.22),
                                       .init(color: Theme.background.opacity(0), location: 0.55)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [.init(color: Theme.background, location: 0), .init(color: Theme.background.opacity(0), location: 0.18)],
                               startPoint: .bottom, endPoint: .top)
            }
        }
    }

    private var urls: [URL?] {
        let owned = model.allGames.compactMap(\.coverURL)
        if owned.count >= 12 { return Array(owned.shuffledStable().prefix(12)) }
        return Self.fallback.map { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\($0)/library_600x900.jpg") }
    }
}

private extension Array where Element == URL {
    /// A fixed order that doesn't change between redraws.
    func shuffledStable() -> [URL] { sorted { $0.absoluteString.hashValue < $1.absoluteString.hashValue } }
}

// MARK: Step 2

private struct StorageStep: View {
    @EnvironmentObject var model: AppModel
    let back: () -> Void
    @State private var storageGB: Double = 0
    @State private var memoryGB: Double = 0

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingIntro(headline: "Set aside room to play",
                                subtext: "Choose where games are stored and how much of this Mac they can use. You can change this later in Settings.")
                VStack(alignment: .leading, spacing: 0) {
                    LocationField()
                        .padding(.bottom, 28)
                    StorageSlider(value: $storageGB)
                        .padding(.vertical, 28)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                    MemorySlider(value: $memoryGB)
                        .padding(.top, 28)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
                .padding(.top, 44)
                Spacer(minLength: 32)
                HStack {
                    Button(action: back) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.left").font(.system(size: 13, weight: .semibold))
                            Text("Back").font(.geist(15))
                        }
                        .foregroundStyle(Theme.mutedText)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("Finish setup", action: finish)
                        .buttonStyle(PrimaryButtonStyle(height: 44))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(EdgeInsets(top: 56, leading: 88, bottom: 48, trailing: 64))
            .frame(width: 680)
            .frame(maxHeight: .infinity, alignment: .top)

            HeroPanel()
                .padding(EdgeInsets(top: 8, leading: 0, bottom: 24, trailing: 24))
        }
        .onAppear(perform: loadDefaults)
    }

    private func loadDefaults() {
        let capacity = StorageSlider.capacityGB(model)
        storageGB = Double(model.settings.storageLimitGB ?? max(20, Int(Double(capacity) * 0.85) / 10 * 10))
        storageGB = min(max(storageGB, 20), Double(max(20, capacity)))
        memoryGB = Double(model.settings.memoryLimitGB ?? max(SystemMemory.minimumForGamesGB, SystemMemory.maximumForGamesGB - 2))
    }

    private func finish() {
        model.settings.storageLimitGB = Int(storageGB)
        model.settings.memoryLimitGB = Int(memoryGB)
        model.finishOnboarding()
    }
}

struct LocationField: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Games location").font(.geist(15, .medium))
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").font(.system(size: 15)).foregroundStyle(Theme.accentText)
                Text(model.settings.gamesLocation)
                    .font(.mono(14))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change") { model.chooseGamesLocation() }.buttonStyle(SecondaryButtonStyle(height: 34))
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 46)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Color.white.opacity(0.1)))
            Text("\(volumeName), \(Format.bytes(model.freeBytesAtGamesLocation)) free. Steam and Epic games both install here.")
                .font(.geist(14))
                .foregroundStyle(Theme.mutedText)
        }
    }

    private var volumeName: String {
        var url = model.settings.gamesURL
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "This disk"
        return name.hasSuffix("disk") || name.hasSuffix("Disk") ? name : "\(name) disk"
    }
}

struct StorageSlider: View {
    @EnvironmentObject var model: AppModel
    @Binding var value: Double

    static func capacityGB(_ model: AppModel) -> Int {
        Int((model.freeBytesAtGamesLocation + model.storageUsedBytes) / 1_000_000_000)
    }

    var body: some View {
        let maximum = Double(max(21, Self.capacityGB(model)))
        LabeledSlider(title: "Space for games", value: $value, range: 20...maximum, step: 10,
                      format: { "\(Int($0)) GB" })
    }
}

struct MemorySlider: View {
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledSlider(title: "Memory for games", value: $value,
                          range: Double(SystemMemory.minimumForGamesGB)...Double(SystemMemory.maximumForGamesGB), step: 1,
                          format: { "\(Int($0)) GB" })
            Text("This Mac has \(SystemMemory.physicalGB) GB. Aqua keeps \(SystemMemory.reservedGB) GB for macOS, so games can use up to \(SystemMemory.maximumForGamesGB) GB.")
                .font(.geist(14))
                .foregroundStyle(Theme.mutedText)
                .frame(maxWidth: 480, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.geist(15, .medium))
                Spacer()
                Text(format(value)).font(.mono(15))
            }
            AquaSlider(value: $value, range: range, step: step)
            HStack {
                Text(format(range.lowerBound))
                Spacer()
                Text(format(range.upperBound))
            }
            .font(.mono(13))
            .foregroundStyle(Theme.mutedText)
        }
    }
}

struct AquaSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span
            let x = proxy.size.width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: 4)
                Capsule().fill(Theme.accent).frame(width: x, height: 4)
                Circle()
                    .fill(Theme.text)
                    .overlay(Circle().stroke(Theme.accent, lineWidth: 3))
                    .frame(width: 18, height: 18)
                    .offset(x: x - 9)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let raw = range.lowerBound + span * min(max(drag.location.x / proxy.size.width, 0), 1)
                let snapped = (raw / step).rounded() * step
                value = min(max(snapped, range.lowerBound), range.upperBound)
            })
        }
        .frame(height: 18)
    }
}

private struct HeroPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            ArtworkImage(url: heroURL)
                .overlay(LinearGradient(stops: [.init(color: Theme.background.opacity(0.85), location: 0),
                                                .init(color: Theme.background.opacity(0), location: 0.4)],
                                        startPoint: .bottom, endPoint: .top))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            if let largest = model.largestGame {
                HStack(alignment: .firstTextBaseline) {
                    Text("Largest game in your library: \(largest.title)").font(.geist(14)).foregroundStyle(Theme.mutedText)
                    Spacer()
                    Text(Format.bytes(largest.installedBytes)).font(.mono(14))
                }
            }
        }
    }

    private var heroURL: URL? {
        model.largestGame?.heroURL ?? model.featuredGame?.heroURL
            ?? URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/990080/library_hero.jpg")
    }
}
