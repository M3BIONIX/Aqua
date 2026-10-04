import SwiftUI
import AquaCore

struct GameView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadCenter
    let gameID: String

    var body: some View {
        if let game = model.game(id: gameID) {
            content(game)
        } else {
            VStack(spacing: 12) {
                Text("This game is no longer in your library.").foregroundStyle(Theme.mutedText)
                Button("Back to Library") { model.route = .library }.buttonStyle(SecondaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ game: LibraryGame) -> some View {
        let recipe = model.recipe(for: game)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    ArtworkImage(url: game.heroURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: 380)
                    LinearGradient(stops: [.init(color: Theme.background, location: 0), .init(color: Theme.background.opacity(0), location: 0.6)],
                                   startPoint: .bottom, endPoint: .top)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(game.title).font(.geist(44, .semibold)).tracking(-1.2).lineLimit(2)
                        if let meta { Text(meta).font(.mono(13)).foregroundStyle(Theme.secondaryText) }
                        HStack(spacing: 10) {
                            PlayButton(game: game, height: 42)
                            if let path = model.installPath(of: game) {
                                Button("Show in Finder") { model.reveal(path: path) }.buttonStyle(SecondaryButtonStyle(height: 42))
                            }
                            if case .epic(let g) = game.source, g.install != nil {
                                Button("Uninstall") { model.uninstall(game) }.buttonStyle(SecondaryButtonStyle(height: 42))
                            }
                            if case .local = game.source {
                                Button("Remove from library") { model.removeLocalGame(game) }
                                    .buttonStyle(SecondaryButtonStyle(height: 42))
                                    .help("The game's files stay where they are")
                            }
                        }
                        .padding(.top, 6)
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 28)
                }
                .frame(height: 380)
                .clipped()
                .overlay(alignment: .topLeading) {
                    Button { model.route = .library } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                            Text("Library").font(.geist(13, .medium))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Theme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.radius))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 40)
                    .padding(.leading, 40)
                }

                VStack(alignment: .leading, spacing: 0) {
                    if let item = downloads.item(for: game.id), item.isPending {
                        DownloadSummary(item: item).padding(.bottom, 32)
                    }
                    if !game.isWindowsGame {
                        Text("Epic lists no Windows version of this game, so Aqua can't run it.")
                            .font(.geist(14)).foregroundStyle(Theme.danger).padding(.bottom, 24)
                    }
                    PageSection(title: "Graphics") {
                        VStack(spacing: 0) {
                            ForEach(Renderer.allCases, id: \.self) { renderer in
                                RendererRow(renderer: renderer, selected: (recipe.renderer ?? .d3dmetal) == renderer) {
                                    model.setRenderer(renderer, for: game)
                                }
                            }
                        }
                        Text("Takes effect the next time the game starts.").font(.geist(13)).foregroundStyle(Theme.mutedText).padding(.top, 12)
                    }
                    PageSection(title: "Launch options") {
                        LaunchOptionsEditor(game: game)
                    }
                    PageSection(title: "Details") {
                        DetailRow(label: "Store", value: game.store.displayName)
                        if case .local(let g) = game.source {
                            DetailRow(label: "Program", value: g.executable, mono: true)
                        } else {
                            DetailRow(label: game.store == .steam ? "App ID" : "App name", value: game.storeID, mono: true)
                        }
                        if game.installedBytes > 0 { DetailRow(label: "Size on disk", value: Format.bytes(game.installedBytes), mono: true) }
                        if let path = model.installPath(of: game) { DetailRow(label: "Location", value: path, mono: true) }
                        DetailRow(label: "Wine engine", value: (recipe.engine ?? .default).displayName)
                        DetailRow(label: "Windows version", value: recipe.windowsVersion ?? "win10", mono: true)
                        if let memory = model.settings.memoryLimitGB { DetailRow(label: "Memory limit", value: "\(memory) GB", mono: true) }
                        if let notes = recipe.notes { DetailRow(label: "Notes", value: notes) }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 12)
                .padding(.bottom, 40)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollIndicators(.never)
    }

    private var meta: String? {
        guard let entry = model.activity[gameID] else { return nil }
        var parts = ["Last played \(Format.relative(entry.lastPlayed))"]
        if entry.seconds >= 60 { parts.append("\(Format.playtime(entry.seconds)) played") }
        return parts.joined(separator: "  ·  ")
    }
}

private struct PageSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.geist(15, .semibold)).padding(.bottom, 12)
            content()
        }
        .padding(.vertical, 24)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

private struct RendererRow: View {
    let renderer: Renderer
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.accentText : Theme.mutedText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(renderer.displayName).font(.geist(14, .medium))
                    Text(help).font(.geist(13)).foregroundStyle(Theme.mutedText)
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var help: String {
        switch renderer {
        case .d3dmetal: return "Apple's D3DMetal. Best for most DirectX 11 and 12 games."
        case .dxmt: return "Often faster for games that only use DirectX 10 or 11."
        case .dxvk: return "DirectX 9 to 11 through Vulkan, for games that misbehave elsewhere."
        case .wined3d: return "Wine's OpenGL renderer. Slow, but runs old DirectX and DirectDraw games."
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).font(.geist(13)).foregroundStyle(Theme.mutedText).frame(width: 160, alignment: .leading)
            Text(value).font(mono ? .mono(13) : .geist(14)).textSelection(.enabled).lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

private struct DownloadSummary: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadCenter
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(DownloadText.state(item)).font(.geist(13)).foregroundStyle(Theme.accentText)
                Spacer()
                DownloadControls(item: item)
            }
            ProgressLine(fraction: item.fraction, height: 4)
            Text(DownloadText.stats(item)).font(.mono(13)).foregroundStyle(Theme.mutedText)
        }
        .padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}
