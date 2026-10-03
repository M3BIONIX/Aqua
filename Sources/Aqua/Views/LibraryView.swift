import SwiftUI
import AquaCore

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadCenter

    var body: some View {
        VStack(spacing: 0) {
            LibraryToolbar()
                .padding(.horizontal, 40)
                .padding(.top, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if model.libraryFilter == .all, model.searchText.isEmpty, let game = model.featuredGame {
                        FeaturedBanner(game: game)
                    }
                    gridSection
                }
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder
    private var gridSection: some View {
        let games = model.visibleGames
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.libraryFilter == .all ? "Library" : model.libraryFilter.rawValue)
                        .font(.geist(18, .semibold)).tracking(-0.18)
                    Text("\(games.count) games").font(.mono(13)).foregroundStyle(Theme.mutedText)
                    if model.epicLoading || model.steamLibraryLoading {
                        Text("Updating…").font(.geist(13)).foregroundStyle(Theme.mutedText)
                    }
                }
                Spacer()
                SortMenu()
            }
            if games.isEmpty {
                EmptyLibrary()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 158, maximum: 210), spacing: 20, alignment: .top)],
                          alignment: .leading, spacing: 26) {
                    ForEach(games) { game in GameTile(game: game) }
                }
            }
        }
    }
}

private struct LibraryToolbar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: 28) {
                ForEach(LibraryFilter.allCases, id: \.self) { filter in
                    UnderlineTab(title: filter.rawValue, active: model.libraryFilter == filter) { model.libraryFilter = filter }
                }
            }
            Spacer()
            HStack(spacing: 10) {
                SearchField(text: $model.searchText, prompt: "Search your library")
                    .frame(width: 280)
                Button { model.refreshLibraries() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle(size: 34))
                .help("Refresh both libraries")
            }
            .padding(.bottom, 10)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

struct UnderlineTab: View {
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Text(title)
                    .font(.geist(14, active ? .medium : .regular))
                    .foregroundStyle(active ? Theme.text : Theme.mutedText)
                Rectangle().fill(active ? Theme.accentText : .clear).frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.mutedText)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.faintText))
                .textFieldStyle(.plain)
                .font(.geist(13))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.mutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
    }
}

private struct SortMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(LibrarySort.allCases, id: \.self) { sort in
                Button(sort.rawValue) { model.librarySort = sort }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Sort by").foregroundStyle(Theme.mutedText)
                Text(model.librarySort.rawValue).foregroundStyle(Theme.text)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.mutedText)
            }
            .font(.geist(13))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct FeaturedBanner: View {
    @EnvironmentObject var model: AppModel
    let game: LibraryGame

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(url: game.heroURL)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
            LinearGradient(stops: [.init(color: Theme.background.opacity(0.92), location: 0),
                                   .init(color: Theme.background.opacity(0.55), location: 0.45),
                                   .init(color: Theme.background.opacity(0), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 14) {
                Text(model.activity[game.id] == nil ? "Ready to play" : "Continue playing")
                    .font(.geist(13)).foregroundStyle(Theme.mutedText)
                Text(game.title)
                    .font(.geist(40, .semibold)).tracking(-0.8)
                    .lineLimit(2)
                if !meta.isEmpty {
                    Text(meta).font(.mono(13)).foregroundStyle(Theme.secondaryText)
                }
                HStack(spacing: 10) {
                    PlayButton(game: game, height: 40)
                    Button("Game settings") { model.route = .game(game.id) }
                        .buttonStyle(SecondaryButtonStyle(height: 40))
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(.leading, 36)
            .padding(.bottom, 34)
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { model.route = .game(game.id) }
    }

    private var meta: String {
        var parts: [String] = []
        if let entry = model.activity[game.id] {
            parts.append("Last played \(Format.relative(entry.lastPlayed))")
            if entry.seconds >= 60 { parts.append(Format.playtime(entry.seconds)) }
        }
        let size = DisplaySize.main(retina: model.settings.retinaMode)
        parts.append("\(size.width) × \(size.height)")
        return parts.joined(separator: "  ·  ")
    }
}

/// Play, Stop or a launch state, for the banner and the game page.
struct PlayButton: View {
    @EnvironmentObject var model: AppModel
    let game: LibraryGame
    var height: CGFloat = 40

    var body: some View {
        switch model.status(of: game) {
        case .running:
            Button { model.stop(game) } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(SecondaryButtonStyle(height: height))
        case .launching:
            Button {} label: { Text("Starting…") }
                .buttonStyle(PrimaryButtonStyle(height: height))
                .disabled(true)
        case .installed:
            Button { model.play(game) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").font(.system(size: 12))
                    Text("Play")
                }
            }
            .buttonStyle(PrimaryButtonStyle(height: height))
        case .transferring, .waiting:
            Button("View download") { model.route = .downloads }
                .buttonStyle(SecondaryButtonStyle(height: height))
        case .notInstalled, .failed:
            Button { model.install(game) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 12, weight: .semibold))
                    Text("Install")
                }
            }
            .buttonStyle(PrimaryButtonStyle(height: height))
            .disabled(!game.isWindowsGame)
        }
    }
}

struct GameTile: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadCenter
    let game: LibraryGame
    @State private var hovering = false

    var body: some View {
        let status = model.status(of: game)
        VStack(alignment: .leading, spacing: 10) {
            Button { model.route = .game(game.id) } label: {
                ArtworkImage(url: game.coverURL, title: game.title)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(hovering ? Color.white.opacity(0.22) : Theme.divider))
                    .opacity(dimmed(status) && !hovering ? 0.55 : 1)
                    .scaleEffect(hovering ? 1.015 : 1)
                    .animation(.easeOut(duration: 0.15), value: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            VStack(alignment: .leading, spacing: 4) {
                Text(game.title).font(.geist(14, .medium)).lineLimit(1)
                StatusLine(game: game, status: status)
            }
        }
        .contextMenu { TileMenu(game: game) }
    }

    private func dimmed(_ status: GameStatus) -> Bool {
        switch status {
        case .installed, .running, .launching: return false
        default: return true
        }
    }
}

private struct StatusLine: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadCenter
    let game: LibraryGame
    let status: GameStatus

    var body: some View {
        switch status {
        case .running:
            Text("Running").font(.geist(13)).foregroundStyle(Theme.accentText)
        case .launching:
            Text("Starting…").font(.geist(13)).foregroundStyle(Theme.mutedText)
        case .installed:
            Button("Play") { model.play(game) }.buttonStyle(LinkButtonStyle()).font(.geist(13))
        case .notInstalled:
            Button("Install") { model.install(game) }.buttonStyle(LinkButtonStyle(color: Theme.mutedText)).font(.geist(13))
                .disabled(!game.isWindowsGame)
        case .failed:
            Button("Install failed, retry") { model.install(game) }.buttonStyle(LinkButtonStyle(color: Theme.danger)).font(.geist(13))
        case .transferring(let item):
            VStack(alignment: .leading, spacing: 6) {
                ProgressLine(fraction: item.fraction, height: 2)
                Text(transferText(item)).font(.mono(12)).foregroundStyle(Theme.mutedText).lineLimit(1)
            }
            .padding(.top, 2)
        case .waiting(let item):
            Button(item.state == .paused ? "Paused \(Int(item.fraction * 100))%" : "Queued") { model.route = .downloads }
                .buttonStyle(LinkButtonStyle(color: Theme.mutedText)).font(.geist(13))
        }
    }

    private func transferText(_ item: DownloadItem) -> String {
        if case .preparing(let message) = item.state { return message }
        return "\(Int(item.fraction * 100))%  ·  \(Format.speed(item.networkBytesPerSecond))"
    }
}

private struct TileMenu: View {
    @EnvironmentObject var model: AppModel
    let game: LibraryGame

    var body: some View {
        Button("Open") { model.route = .game(game.id) }
        if game.isInstalled {
            Button("Play") { model.play(game) }
            if let path = model.installPath(of: game) { Button("Show in Finder") { model.reveal(path: path) } }
        } else {
            Button("Install") { model.install(game) }
        }
    }
}

private struct EmptyLibrary: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.geist(15, .medium))
            Text(detail).font(.geist(14)).foregroundStyle(Theme.mutedText)
            if !model.hasAnyAccount {
                Button("Connect a store") { model.route = .settings }.buttonStyle(PrimaryButtonStyle()).padding(.top, 6)
            }
        }
        .padding(.vertical, 48)
    }

    private var title: String {
        if !model.searchText.isEmpty { return "No games match \u{201C}\(model.searchText)\u{201D}" }
        switch model.libraryFilter {
        case .installed: return "Nothing installed yet"
        case .downloading: return "Nothing downloading"
        case .all: return model.epicLoading || model.steamLibraryLoading ? "Loading your library" : "Your library is empty"
        }
    }

    private var detail: String {
        if !model.searchText.isEmpty { return "Try a shorter name." }
        switch model.libraryFilter {
        case .installed, .downloading: return "Choose Install on any game in All games."
        case .all: return model.hasAnyAccount ? "Games you own on Steam and Epic appear here." : "Sign in to Steam or Epic Games to see your games."
        }
    }
}
