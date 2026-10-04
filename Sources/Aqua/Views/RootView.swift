import SwiftUI
import AquaCore

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.settings.onboarded && !model.libraryReady {
                LoadingView()
                    .transition(.opacity)
            } else if model.settings.onboarded {
                MainView()
                    .transition(.opacity)
            } else {
                OnboardingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .font(.geist(14))
        .ignoresSafeArea()
        .sheet(isPresented: $model.showEpicLogin) { EpicLoginView().environmentObject(model) }
        .sheet(isPresented: $model.showAddGame) { AddGameView().environmentObject(model) }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
            Button("Open Logs") { model.revealLogs(); model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
            Group {
                switch model.route {
                case .library: LibraryView()
                case .downloads: DownloadsView()
                case .settings: SettingsView()
                case .game(let id): GameView(gameID: id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                BrandMark()
                Text("Aqua").font(.geist(16, .semibold)).tracking(-0.16)
            }
            .padding(.horizontal, 6)
            .padding(.top, 52)
            .padding(.bottom, 24)

            VStack(spacing: 2) {
                NavRow(title: "Library", icon: "square.grid.2x2", active: isLibrary) { model.route = .library }
                NavRow(title: "Downloads", icon: "arrow.down.to.line", active: model.route == .downloads,
                       count: downloads.pending.count) { model.route = .downloads }
                NavRow(title: "Settings", icon: "gearshape", active: model.route == .settings) { model.route = .settings }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Accounts").font(.geist(13)).foregroundStyle(Theme.mutedText).padding(.horizontal, 10).padding(.bottom, 6)
                AccountRow(store: .steam, name: model.steamAccount)
                AccountRow(store: .epic, name: model.epicAccount)
            }
            .padding(.top, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
            .padding(.top, 28)

            Spacer(minLength: 16)

            if let progress = model.runtimeProgress {
                MeterCard(title: progress.message, fraction: progress.fraction ?? 0,
                          leading: progress.fraction.map { "\(Int($0 * 100))%" } ?? "Starting", trailing: "One-time setup")
            } else if let item = downloads.active {
                DownloadMeter(item: item)
            } else {
                StorageMeter()
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
        .frame(width: 240)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
    }

    private var isLibrary: Bool {
        if case .game = model.route { return true }
        return model.route == .library
    }
}

struct NavRow: View {
    let title: String
    let icon: String
    let active: Bool
    var count: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Hoverable { hovering in
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(active ? Theme.accentText : Theme.mutedText)
                        .frame(width: 18)
                    Text(title)
                        .font(.geist(14, active ? .medium : .regular))
                        .foregroundStyle(active ? Theme.text : Theme.secondaryText)
                    Spacer()
                    if count > 0 {
                        Text("\(count)").font(.mono(13)).foregroundStyle(Theme.mutedText)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(active ? Theme.selected : (hovering ? Theme.selected.opacity(0.5) : .clear),
                            in: RoundedRectangle(cornerRadius: Theme.radius))
            }
        }
        .buttonStyle(.plain)
    }
}

struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let store: Store
    let name: String?

    var body: some View {
        Button { model.route = .settings } label: {
            HStack(spacing: 10) {
                StoreLogo(store: store, size: 15).foregroundStyle(Theme.secondaryText)
                Text(name ?? "Not signed in")
                    .font(.geist(14))
                    .foregroundStyle(name == nil ? Theme.faintText : Theme.secondaryText)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MeterCard<Accessory: View>: View {
    let title: String
    let fraction: Double
    let leading: String
    let trailing: String
    var icon: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
                }
                Text(title).font(.geist(13, .medium)).lineLimit(1)
                Spacer(minLength: 4)
                accessory()
            }
            ProgressLine(fraction: fraction)
            HStack {
                Text(leading)
                Spacer()
                Text(trailing)
            }
            .font(.mono(12))
            .foregroundStyle(Theme.mutedText)
        }
        .padding(12)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.divider))
    }
}

extension MeterCard where Accessory == EmptyView {
    init(title: String, fraction: Double, leading: String, trailing: String, icon: String? = nil) {
        self.init(title: title, fraction: fraction, leading: leading, trailing: trailing, icon: icon) { EmptyView() }
    }
}

struct DownloadMeter: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadCenter
    let item: DownloadItem

    var body: some View {
        Button { model.route = .downloads } label: {
            MeterCard(title: item.title, fraction: item.fraction, leading: "\(Int(item.fraction * 100))%",
                      trailing: item.state == .paused ? "Paused" : Format.speed(item.networkBytesPerSecond)) {
                Button {
                    item.state == .paused ? downloads.resume(item.id) : downloads.pause(item.id)
                } label: {
                    Image(systemName: item.state == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.state == .paused ? "Resume" : "Pause")
            }
        }
        .buttonStyle(.plain)
    }
}

struct StorageMeter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let used = model.storageUsedBytes
        let free = model.freeBytesAtGamesLocation
        let limit = model.storageLimitBytes ?? (used + free)
        MeterCard(title: model.settings.gamesURL.lastPathComponent, fraction: limit > 0 ? Double(used) / Double(limit) : 0,
                  leading: "\(Format.bytes(used)) used", trailing: "\(Format.bytes(max(0, min(free, limit - used)))) free",
                  icon: "internaldrive")
    }
}
