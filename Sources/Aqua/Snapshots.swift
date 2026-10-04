#if DEBUG
import AppKit
import SwiftUI

/// `AQUA_SNAPSHOT_DIR=/path Aqua` renders each screen to PNG and quits. Debug builds only;
/// settings are changed in memory, never saved.
@MainActor
enum Snapshots {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["AQUA_SNAPSHOT_DIR"] != nil }

    static func runIfRequested(window: NSWindow, model: AppModel) {
        guard let folder = ProcessInfo.processInfo.environment["AQUA_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let onboarded = model.settings.onboarded
        let steps: [(String, () -> Void)] = [
            ("1-onboarding-stores", { model.settings.onboarded = false; model.onboardingStep = 1 }),
            ("2-onboarding-storage", { model.onboardingStep = 2 }),
            ("3-library", { model.settings.onboarded = true; model.route = .library }),
            ("4-game", { model.route = .game(model.featuredGame?.id ?? model.allGames.first?.id ?? "") }),
            ("5-downloads", { model.route = .downloads }),
            ("6-settings", { model.route = .settings }),
        ]
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            capture(window, to: directory.appendingPathComponent("0-loading.png"))
            try? await Task.sleep(nanoseconds: 9_500_000_000)
            for (name, apply) in steps {
                apply()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                capture(window, to: directory.appendingPathComponent("\(name).png"))
            }
            model.route = .library
            model.showAddGame = true
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let sheet = window.attachedSheet { capture(sheet, to: directory.appendingPathComponent("7-add-game.png")) }
            model.showAddGame = false
            captureFullGamePage(model: model, to: directory.appendingPathComponent("4-game-full.png"))
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            model.settings.onboarded = onboarded
            NSApp.terminate(nil)
        }
    }

    /// The whole game page in a borderless window, which macOS doesn't limit to the screen height.
    private static var tallWindow: NSWindow?

    private static func captureFullGamePage(model: AppModel, to url: URL) {
        guard let id = model.featuredGame?.id ?? model.allGames.first?.id else { return }
        let page = GameView(gameID: id).environmentObject(model).environmentObject(model.downloads)
            .frame(width: 1120, height: 2400).background(Theme.background).foregroundStyle(Theme.text)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1120, height: 2400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: page)
        window.orderBack(nil)
        tallWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { capture(window, to: url) }
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
