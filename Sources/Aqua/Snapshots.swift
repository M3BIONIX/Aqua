#if DEBUG
import AppKit
import SwiftUI

/// `AQUA_SNAPSHOT_DIR=/path Aqua` renders each screen to PNG and quits. Debug builds only;
/// settings are changed in memory, never saved.
@MainActor
enum Snapshots {
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
            model.settings.onboarded = onboarded
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
