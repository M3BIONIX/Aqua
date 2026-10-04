import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel!
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Aqua at a time: two would both drive the same downloads and bottles.
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0 != .current }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        AquaFonts.register()
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        model = AppModel()
        buildMenu()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Aqua"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(Theme.background)
        window.minSize = NSSize(width: 1080, height: 700)
        window.contentView = NSHostingView(rootView: RootView().environmentObject(model).environmentObject(model.downloads))
        window.setFrameAutosaveName("AquaMainWindow")
        if !window.setFrameUsingName("AquaMainWindow") { window.center() }
        self.window = window
        #if DEBUG
        if Snapshots.isRequested {
            // Render without taking focus, so keystrokes meant for other apps can't press buttons here.
            window.orderBack(nil)
            Snapshots.runIfRequested(window: window, model: model)
            return
        }
        #endif
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model?.downloads.stopForQuit()
    }

    @objc func showSettings() { model.route = .settings }
    @objc func showLibrary() { model.route = .library }
    @objc func showDownloads() { model.route = .downloads }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Aqua", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Aqua", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Aqua", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Library", action: #selector(showLibrary), keyEquivalent: "1")
        view.addItem(withTitle: "Downloads", action: #selector(showDownloads), keyEquivalent: "2")
        viewItem.submenu = view

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    #if DEBUG
    app.setActivationPolicy(Snapshots.isRequested ? .accessory : .regular)
    #else
    app.setActivationPolicy(.regular)
    #endif
    app.run()
}
