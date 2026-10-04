import SwiftUI
import AquaCore

/// Per-game launch options: Wine engine, Windows version, AVX, arguments, environment,
/// DLL overrides and settings-file changes. Saved as the user's recipe for the game, on top of
/// what Aqua ships; Reset removes the user's changes.
struct LaunchOptionsEditor: View {
    @EnvironmentObject var model: AppModel
    let game: LibraryGame

    @State private var engine: WineEngine?
    @State private var windowsVersion: String?
    @State private var advertiseAVX: Bool?
    @State private var arguments = ""
    @State private var environment = ""
    @State private var dllOverrides = ""
    @State private var files = ""
    @State private var loaded: GameRecipe?
    @State private var savedMessage = false

    private static let windowsVersions = ["win11", "win10", "win81", "win7"]

    var body: some View {
        let bundled = model.bundledRecipe(for: game)
        VStack(alignment: .leading, spacing: 22) {
            Text("Change how this game starts. Leave a field empty to use Aqua's settings. Changes apply the next time the game starts.")
                .font(.geist(13)).foregroundStyle(Theme.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 28) {
                if game.store == .epic {
                    OptionMenu(title: "Wine engine", value: engine?.displayName ?? "Aqua's choice (\((bundled?.engine ?? .default).displayName))") {
                        Button("Aqua's choice") { engine = nil }
                        Divider()
                        ForEach(WineEngine.allCases, id: \.self) { option in Button(option.displayName) { engine = option } }
                    }
                }
                OptionMenu(title: "Windows version", value: windowsVersion ?? "Aqua's choice (\(bundled?.windowsVersion ?? GameRecipe.defaults.windowsVersion ?? "win10"))") {
                    Button("Aqua's choice") { windowsVersion = nil }
                    Divider()
                    ForEach(Self.windowsVersions, id: \.self) { option in Button(option) { windowsVersion = option } }
                }
                OptionMenu(title: "AVX for the game", value: advertiseAVX.map { $0 ? "On" : "Off" } ?? "Aqua's choice (\((bundled?.advertiseAVX ?? true) ? "on" : "off"))") {
                    Button("Aqua's choice") { advertiseAVX = nil }
                    Divider()
                    Button("On") { advertiseAVX = true }
                    Button("Off") { advertiseAVX = false }
                }
            }

            OptionField(title: "Launch arguments", builtIn: LaunchOptionsText.formatArguments(bundled?.arguments)) {
                ZStack(alignment: .leading) {
                    if arguments.isEmpty {
                        Text("For example: -dx11 -windowed").font(.mono(13)).foregroundStyle(Theme.faintText).allowsHitTesting(false)
                    }
                    TextField("", text: $arguments).textFieldStyle(.plain).font(.mono(13))
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .inputBackground()
            }

            HStack(alignment: .top, spacing: 20) {
                OptionField(title: "Environment variables", builtIn: LaunchOptionsText.formatPairs(bundled?.environment)) {
                    CodeEditor(text: $environment, placeholder: "One per line\nDXVK_HUD=fps", height: 96)
                }
                OptionField(title: "DLL overrides", builtIn: LaunchOptionsText.formatPairs(bundled?.dllOverrides)) {
                    CodeEditor(text: $dllOverrides, placeholder: "One per line\nd3d12=n,b", height: 96)
                }
            }

            OptionField(title: "Game settings files", builtIn: LaunchOptionsText.formatFiles(bundled?.files)) {
                CodeEditor(text: $files, placeholder: """
                A file path, an optional [Section], then key=value lines:
                %LOCALAPPDATA%\\Game\\Saved\\Config\\WindowsNoEditor\\Engine.ini
                [SystemSettings]
                r.WarnOfBadDrivers=0
                """, height: 130)
            } footer: {
                HStack(spacing: 4) {
                    Text("Paths can use %LOCALAPPDATA%, %APPDATA%, %DOCUMENTS%, %USERPROFILE% and * as a wildcard. Missing keys are added under the section.")
                    Button("Open the game's Windows folder") { model.revealWindowsUserFolder(for: game) }
                        .buttonStyle(LinkButtonStyle())
                }
            }

            HStack(spacing: 10) {
                Button("Save launch options", action: save).buttonStyle(PrimaryButtonStyle()).disabled(!isDirty)
                Button("Reset to Aqua's settings", action: reset).buttonStyle(SecondaryButtonStyle()).disabled(loaded == nil)
                if savedMessage {
                    Text("Saved. Applies the next time the game starts.").font(.geist(13)).foregroundStyle(Theme.accentText)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: game.id) { load() }
    }

    private var edited: GameRecipe? {
        var recipe = loaded ?? GameRecipe()
        recipe.engine = game.store == .epic ? engine : loaded?.engine
        recipe.windowsVersion = windowsVersion
        recipe.advertiseAVX = advertiseAVX
        let args = LaunchOptionsText.parseArguments(arguments)
        recipe.arguments = args.isEmpty ? nil : args
        let env = LaunchOptionsText.parsePairs(environment)
        recipe.environment = env.isEmpty ? nil : env
        let dlls = LaunchOptionsText.parsePairs(dllOverrides)
        recipe.dllOverrides = dlls.isEmpty ? nil : dlls
        let settings = LaunchOptionsText.parseFiles(files)
        recipe.files = settings.isEmpty ? nil : settings
        return recipe == GameRecipe() ? nil : recipe
    }

    private var isDirty: Bool { edited != loaded }

    private func load() {
        let recipe = model.userRecipe(for: game)
        loaded = recipe
        engine = recipe?.engine
        windowsVersion = recipe?.windowsVersion
        advertiseAVX = recipe?.advertiseAVX
        arguments = LaunchOptionsText.formatArguments(recipe?.arguments)
        environment = LaunchOptionsText.formatPairs(recipe?.environment)
        dllOverrides = LaunchOptionsText.formatPairs(recipe?.dllOverrides)
        files = LaunchOptionsText.formatFiles(recipe?.files)
        savedMessage = false
    }

    private func save() {
        model.saveUserRecipe(edited, for: game)
        load()
        savedMessage = true
    }

    private func reset() {
        model.saveUserRecipe(nil, for: game)
        load()
        savedMessage = true
    }
}

private struct OptionMenu<Items: View>: View {
    let title: String
    let value: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.geist(13)).foregroundStyle(Theme.mutedText)
            Menu {
                items()
            } label: {
                HStack(spacing: 8) {
                    Text(value).font(.geist(13)).foregroundStyle(Theme.text).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.mutedText)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .inputBackground()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private struct OptionField<Content: View, Footer: View>: View {
    let title: String
    var builtIn: String = ""
    @ViewBuilder let content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.geist(13)).foregroundStyle(Theme.mutedText)
            content()
            if !builtIn.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aqua already sets").font(.geist(12)).foregroundStyle(Theme.faintText)
                    Text(builtIn).font(.mono(12)).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
                }
            }
            footer().font(.geist(12)).foregroundStyle(Theme.faintText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension OptionField where Footer == EmptyView {
    init(title: String, builtIn: String = "", @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, builtIn: builtIn, content: content) { EmptyView() }
    }
}

private struct CodeEditor: View {
    @Binding var text: String
    let placeholder: String
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.mono(13))
                    .foregroundStyle(Theme.faintText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.mono(13))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
        }
        .frame(height: height)
        .inputBackground()
    }
}

private extension View {
    func inputBackground() -> some View {
        background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
    }
}
