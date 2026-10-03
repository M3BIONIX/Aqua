import SwiftUI
import AquaCore

/// Shown at launch until every connected store has delivered its game list.
/// Epic is almost always last, and the copy says so.
struct LoadingView: View {
    @EnvironmentObject var model: AppModel
    @State private var started = Date()

    private static let epicJokes = [
        "Epic is still thinking about it.",
        "Asking Epic nicely. Again.",
        "Epic's servers are buffering like it's 2009.",
        "Epic is counting every free weekly game you ever claimed.",
        "Somewhere, an Epic server is waking up a hamster.",
        "Epic is loading your library one free game at a time.",
        "Fun fact: the Epic Games Launcher would still be updating itself right now.",
        "Epic says it's almost done. Epic always says that.",
        "You could have installed Steam twice by now.",
        "Epic is checking with Tim Sweeney personally.",
        "Epic is shaking the server until the game list falls out.",
        "If this were the Epic launcher, your fans would be at 100% by now.",
    ]

    private static let steamDoneJokes = [
        "Steam finished ages ago. Epic, buddy?",
        "Steam is done and is now waiting on Epic like the rest of us.",
        "Steam: done. Epic: thinking about Fortnite skins.",
    ]

    var body: some View {
        TimelineView(.periodic(from: started, by: 3.2)) { context in
            let tick = Int(context.date.timeIntervalSince(started) / 3.2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    BrandMark(size: 26)
                    Text("Aqua").font(.geist(18, .semibold)).tracking(-0.18)
                }
                Text("Loading your library")
                    .font(.geist(40, .semibold))
                    .tracking(-1.1)
                    .padding(.top, 28)
                Text(caption(tick: tick))
                    .font(.geist(16))
                    .foregroundStyle(Theme.mutedText)
                    .frame(height: 24, alignment: .leading)
                    .id(tick)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeOut(duration: 0.35), value: tick)
                    .padding(.top, 12)

                VStack(spacing: 0) {
                    if model.steamAccount != nil || model.steamProgress != nil {
                        StoreLoadRow(store: .steam, account: model.steamAccount,
                                     done: model.steamLibraryLoaded, count: model.steamGames.count)
                        Rectangle().fill(Theme.border).frame(height: 1)
                    }
                    StoreLoadRow(store: .epic, account: model.epicAccount,
                                 done: model.epicLibraryLoaded, count: model.epicGames.count,
                                 checking: !model.epicChecked)
                }
                .padding(.top, 44)

                IndeterminateLine().padding(.top, 28)

                if context.date.timeIntervalSince(started) > 45 {
                    HStack(spacing: 14) {
                        Button("Open my library anyway") { finish() }.buttonStyle(SecondaryButtonStyle())
                        Text("Games still loading will show up when they arrive.")
                            .font(.geist(13)).foregroundStyle(Theme.mutedText)
                    }
                    .padding(.top, 28)
                }
            }
            .frame(width: 560, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if model.libraryLoadsFinished { finish() } }
        .onChange(of: model.libraryLoadsFinished) { if model.libraryLoadsFinished { finish() } }
    }

    private func caption(tick: Int) -> String {
        let steamPending = model.steamAccount != nil && !model.steamLibraryLoaded
        let epicPending = !model.epicLibraryLoaded
        if !epicPending && steamPending {
            return "Epic finished before Steam? Screenshot this, it'll never happen again."
        }
        if epicPending && !steamPending && model.steamAccount != nil && tick % 2 == 1 {
            return Self.steamDoneJokes[(tick / 2) % Self.steamDoneJokes.count]
        }
        if epicPending {
            return tick == 0 ? "Getting your games from Steam and Epic." : Self.epicJokes[(tick - 1) % Self.epicJokes.count]
        }
        return "All set."
    }

    private func finish() {
        guard !model.libraryReady else { return }
        withAnimation(.easeOut(duration: 0.35)) { model.libraryReady = true }
    }
}

private struct StoreLoadRow: View {
    let store: Store
    let account: String?
    let done: Bool
    let count: Int
    var checking = false

    var body: some View {
        HStack(spacing: 16) {
            StoreLogo(store: store, size: store == .steam ? 22 : 20)
                .foregroundStyle(Theme.text)
                .frame(width: 40, height: 40)
                .background(Theme.placeholder, in: RoundedRectangle(cornerRadius: Theme.radius))
            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayName).font(.geist(15, .medium))
                Text(account.map { "Signed in as \($0)" } ?? (checking ? "Checking your sign-in" : "Not signed in"))
                    .font(.geist(13)).foregroundStyle(Theme.mutedText)
            }
            Spacer()
            if done {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accentText)
                    Text(account == nil ? "Skipped" : "\(count) games").font(.mono(13))
                }
            } else {
                Text(store == .epic ? "Still loading…" : "Loading…").font(.mono(13)).foregroundStyle(Theme.mutedText)
            }
        }
        .padding(.vertical, 18)
    }
}

/// A short bar sliding along the track, for work with no measurable progress.
private struct IndeterminateLine: View {
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.accent)
                    .frame(width: proxy.size.width * 0.3)
                    .offset(x: proxy.size.width * phase)
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}
