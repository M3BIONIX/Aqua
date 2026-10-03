import SwiftUI
import AquaCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    private var storageGB: Binding<Double> {
        Binding(get: { Double(model.settings.storageLimitGB ?? StorageSlider.capacityGB(model)) },
                set: { model.settings.storageLimitGB = Int($0); model.saveSettings() })
    }

    private var memoryGB: Binding<Double> {
        Binding(get: { Double(model.settings.memoryLimitGB ?? SystemMemory.maximumForGamesGB) },
                set: { model.settings.memoryLimitGB = Int($0); model.saveSettings() })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings").font(.geist(28, .semibold)).tracking(-0.56)
                    .padding(.top, 26)
                    .padding(.bottom, 28)

                SettingsSection(title: "Accounts") {
                    SteamAccountRow()
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    EpicAccountRow()
                }

                SettingsSection(title: "Storage") {
                    LocationField()
                    StorageSlider(value: storageGB)
                        .padding(.top, 24)
                    Text("Installed games use \(Format.bytes(model.storageUsedBytes)) of this. Aqua won't start an install that would go past it.")
                        .font(.geist(14)).foregroundStyle(Theme.mutedText).padding(.top, 10)
                }

                SettingsSection(title: "Memory") {
                    MemorySlider(value: memoryGB)
                    Text("Windows games are told this is how much memory the Mac has, so they size their caches to it. Applies the next time a game or Steam starts.")
                        .font(.geist(14)).foregroundStyle(Theme.mutedText).padding(.top, 10)
                        .frame(maxWidth: 560, alignment: .leading)
                }

                SettingsSection(title: "Display") {
                    SettingToggle(title: "Retina resolution",
                                  detail: "Games render every pixel of the display with 200% Windows scaling. Sharper, uses more GPU.",
                                  isOn: Binding(get: { model.settings.retinaMode }, set: { model.settings.retinaMode = $0; model.saveSettings() }))
                    SettingToggle(title: "Performance HUD",
                                  detail: "Shows Apple's Metal frame rate overlay in games.",
                                  isOn: Binding(get: { model.settings.metalHUD }, set: { model.settings.metalHUD = $0; model.saveSettings() }))
                }

                SettingsSection(title: "Aqua") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Game engine").font(.geist(14, .medium))
                            Text(engineStatus).font(.geist(13)).foregroundStyle(Theme.mutedText)
                        }
                        Spacer()
                        Button("Open logs folder") { model.revealLogs() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private var engineStatus: String {
        if let progress = model.runtimeProgress {
            return "Setting up, \(Int((progress.fraction ?? 0) * 100))%"
        }
        return model.runtimeInstalled ? "\(RuntimeComponents.aquaEngine.name), \(RuntimeComponents.aquaEngine.version)" : "Not set up yet"
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.geist(13)).foregroundStyle(Theme.mutedText).padding(.bottom, 16)
            content()
        }
        .padding(.vertical, 28)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

private struct SettingToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.geist(14, .medium))
                Text(detail).font(.geist(13)).foregroundStyle(Theme.mutedText)
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
        }
        .padding(.vertical, 10)
    }
}

private struct AccountLayout<Actions: View>: View {
    let store: Store
    let status: String
    var detail: String? = nil
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 16) {
            StoreLogo(store: store, size: store == .steam ? 22 : 20)
                .foregroundStyle(Theme.text)
                .frame(width: 40, height: 40)
                .background(Theme.placeholder, in: RoundedRectangle(cornerRadius: Theme.radius))
            VStack(alignment: .leading, spacing: 4) {
                Text(store.displayName).font(.geist(15, .medium))
                Text(status).font(.geist(13)).foregroundStyle(Theme.mutedText)
                if let detail { Text(detail).font(.geist(12)).foregroundStyle(Theme.faintText) }
            }
            Spacer()
            HStack(spacing: 8) { actions() }
        }
        .padding(.vertical, 16)
    }
}

private struct SteamAccountRow: View {
    @EnvironmentObject var model: AppModel
    @State private var apiKey = ""
    @State private var showKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AccountLayout(store: .steam, status: status, detail: model.steamLibraryStatus) {
                if model.steamAccount != nil || model.steamAwaitingSignIn {
                    Button("Open Steam") { model.openSteam() }.buttonStyle(SecondaryButtonStyle())
                    Button("Quit Steam") { model.stopSteam() }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Sign in to Steam") { model.connectSteam() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.steamProgress != nil)
                }
            }
            Button(showKey ? "Hide Web API key" : "Private Steam profile? Add a Web API key") { showKey.toggle() }
                .buttonStyle(LinkButtonStyle(color: Theme.mutedText)).font(.geist(13))
                .padding(.leading, 56)
                .padding(.bottom, 12)
            if showKey {
                HStack(spacing: 10) {
                    if model.hasSteamAPIKey {
                        Text("A key is saved in your Keychain.").font(.geist(13)).foregroundStyle(Theme.mutedText)
                        Button("Remove") { model.saveSteamAPIKey("") }.buttonStyle(SecondaryButtonStyle(height: 32))
                    } else {
                        SecureField("", text: $apiKey, prompt: Text("Steam Web API key").foregroundStyle(Theme.faintText))
                            .textFieldStyle(.plain)
                            .font(.mono(13))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
                            .frame(width: 320)
                            .onSubmit { model.saveSteamAPIKey(apiKey); apiKey = "" }
                        Link("Get a key", destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
                            .font(.geist(13)).foregroundStyle(Theme.accentText)
                    }
                }
                .padding(.leading, 56)
                .padding(.bottom, 16)
            }
        }
    }

    private var status: String {
        if let progress = model.steamProgress {
            return progress.fraction.map { "\(progress.message), \(Int($0 * 100))%" } ?? progress.message
        }
        if model.steamAwaitingSignIn { return "Finish signing in in the Steam window" }
        guard let account = model.steamAccount else { return "Not signed in" }
        return "Signed in as \(account), \(model.steamGames.count) games"
    }
}

private struct EpicAccountRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        AccountLayout(store: .epic, status: status) {
            if model.epicAccount != nil {
                Button("Refresh") { Task { await model.refreshEpic(refreshLibrary: true) } }.buttonStyle(SecondaryButtonStyle())
                Button("Sign out") { model.logoutEpic() }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Sign in to Epic") { model.showEpicLogin = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.epicChecked)
            }
        }
    }

    private var status: String {
        guard let account = model.epicAccount else { return model.epicChecked ? "Not signed in" : "Checking…" }
        return "Signed in as \(account), \(model.epicGames.count) games"
    }
}
