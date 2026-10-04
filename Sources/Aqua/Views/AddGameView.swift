import SwiftUI
import UniformTypeIdentifiers
import AquaCore

/// Adds a Windows game from a file on this Mac: run its installer, or point at its .exe.
struct AddGameView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case choose
        case installing(String)
        case pick([URL])
        case adding
    }

    @State private var step: Step = .choose
    @State private var title = ""
    @State private var selected: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add a Windows game").font(.geist(20, .semibold)).tracking(-0.2)
                Spacer()
                if step != .adding, !isInstalling {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle(size: 30))
                }
            }
            .padding(.bottom, 20)

            switch step {
            case .choose: choose
            case .installing(let name): installing(name)
            case .pick(let candidates): pick(candidates)
            case .adding:
                VStack(alignment: .leading, spacing: 14) {
                    Text("Adding \(title)…").font(.geist(15, .medium))
                    IndeterminateLine()
                }
            }
        }
        .padding(28)
        .frame(width: 580)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .interactiveDismissDisabled(isInstalling)
    }

    private var isInstalling: Bool {
        if case .installing = step { return true }
        return false
    }

    // MARK: Steps

    private var choose: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("For games that aren't on Steam or Epic, like DRM-free games from GOG or itch.io, or games from a disc.")
                .font(.geist(14)).foregroundStyle(Theme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            ChoiceRow(icon: "shippingbox", title: "Run an installer",
                      detail: "A setup .exe or .msi. Aqua opens it, you install the game, then pick it from what was installed.") {
                guard let file = pickFile(types: ["exe", "msi"], prompt: "Run Installer") else { return }
                runInstaller(file)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            ChoiceRow(icon: "gamecontroller", title: "Add a game you already have",
                      detail: "Choose the game's .exe in its folder. Nothing is copied or moved.") {
                guard let file = pickFile(types: ["exe"], prompt: "Add Game") else { return }
                title = LocalLibrary.suggestedTitle(for: file)
                selected = file
                step = .pick([file])
            }
            if !model.runtimeInstalled {
                Text("Aqua is still setting itself up. Games can be added once that finishes.")
                    .font(.geist(13)).foregroundStyle(Theme.danger).padding(.top, 14)
            }
        }
    }

    private func installing(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Installing with \(name)").font(.geist(15, .medium))
            Text("The installer opens in its own window. Install the game there and close the installer when it's done. Aqua then finds what was installed.")
                .font(.geist(14)).foregroundStyle(Theme.mutedText).fixedSize(horizontal: false, vertical: true)
            Text("To keep the game on your games disk, choose a folder on drive S: (your Aqua games folder) when the installer asks where to install.")
                .font(.geist(13)).foregroundStyle(Theme.faintText).fixedSize(horizontal: false, vertical: true)
            IndeterminateLine().padding(.top, 6)
            Button("Stop the installer") { model.stopLocalInstaller() }.buttonStyle(SecondaryButtonStyle()).padding(.top, 6)
        }
    }

    private func pick(_ candidates: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.geist(13)).foregroundStyle(Theme.mutedText)
                TextField("", text: $title)
                    .textFieldStyle(.plain)
                    .font(.geist(14))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Program to start").font(.geist(13)).foregroundStyle(Theme.mutedText)
                if candidates.isEmpty {
                    Text("Aqua didn't find a new program in the usual install folders. Choose the game's .exe yourself.")
                        .font(.geist(13)).foregroundStyle(Theme.mutedText).fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(candidates.prefix(12), id: \.self) { url in
                                CandidateRow(url: url, selected: selected == url) {
                                    selected = url
                                    title = LocalLibrary.suggestedTitle(for: url)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                Button("Choose another .exe…") {
                    guard let file = pickFile(types: ["exe"], prompt: "Choose") else { return }
                    selected = file
                    title = LocalLibrary.suggestedTitle(for: file)
                    if !candidates.contains(file) { step = .pick([file] + candidates) }
                }
                .buttonStyle(LinkButtonStyle()).font(.geist(13))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Add to library", action: add)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(selected == nil || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Actions

    private func runInstaller(_ file: URL) {
        step = .installing(file.lastPathComponent)
        Task {
            let candidates = await model.runLocalInstaller(file)
            selected = candidates.first
            title = candidates.first.map(LocalLibrary.suggestedTitle(for:)) ?? ""
            step = .pick(candidates)
        }
    }

    private func add() {
        guard let selected else { return }
        step = .adding
        Task {
            if let game = await model.addLocalGame(executable: selected, title: title) {
                model.route = .game(game.id)
            }
            dismiss()
        }
    }

    private func pickFile(types: [String], prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = prompt
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct ChoiceRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Hoverable { hovering in
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: icon)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.accentText)
                        .frame(width: 40, height: 40)
                        .background(Theme.placeholder, in: RoundedRectangle(cornerRadius: Theme.radius))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.geist(15, .medium))
                        Text(detail).font(.geist(13)).foregroundStyle(Theme.mutedText).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.text : Theme.mutedText).padding(.top, 12)
                }
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}

private struct CandidateRow: View {
    let url: URL
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.accentText : Theme.mutedText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.geist(14, .medium))
                    Text(url.deletingLastPathComponent().path).font(.mono(11)).foregroundStyle(Theme.faintText)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
