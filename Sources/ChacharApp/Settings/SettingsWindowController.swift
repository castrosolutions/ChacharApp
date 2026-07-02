import AppKit
import ChacharCore
import SwiftUI

/// Owns the single settings window for the menu-bar (accessory) app.
///
/// While the window is open the app becomes a **regular** app — a Dock icon and the standard menu
/// bar appear, so configuring feels like using a normal Mac app (⌘W/⌘Q, copy/paste in the text
/// fields). When the window closes it drops back to a menu-bar **accessory** (no Dock icon), which
/// is how the app runs the rest of the time. This "dynamic Dock" is the idiomatic macOS pattern for
/// menu-bar apps that still want a real settings surface.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var historyViewModel: HistoryViewModel?
    private var vocabularyViewModel: VocabularyViewModel?

    func show(store: SettingsStore, status: RuntimeStatus, history: HistoryStore,
              vocabulary: VocabularyStore, asr: ASRModelController) {
        // Surface as a regular app so the Dock icon + menu bar appear while configuring.
        installMainMenuIfNeeded()
        NSApp.setActivationPolicy(.regular)

        if let window {
            historyViewModel?.reload()    // refresh with anything dictated since last open
            vocabularyViewModel?.reload() // pick up external edits to the JSON
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = HistoryViewModel(store: history)
        historyViewModel = viewModel
        let vocabModel = VocabularyViewModel(store: vocabulary)
        vocabularyViewModel = vocabModel
        let root = SettingsView(store: store, status: status, history: viewModel,
                                vocabulary: vocabModel, asr: asr)
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "ChacharApp Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false // keep the instance so we can reopen it
        win.delegate = self              // revert to accessory when the window closes
        win.center()
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Closing the settings window returns the app to a menu-bar-only accessory (Dock icon hidden).
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Main menu

    /// Install a minimal main menu (App / Edit / Window) the first time settings are shown. It stays
    /// hidden while the app is an accessory and only becomes visible in `.regular` mode. Without it,
    /// `.regular` would show an empty menu bar and the standard editing shortcuts (⌘C/⌘V/⌘Z) and
    /// ⌘W/⌘Q wouldn't work in the settings window's text fields.
    private func installMainMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let appName = "ChacharApp"
        let mainMenu = NSMenu()

        // App menu.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu — nil-targeted standard actions route through the responder chain to the focused
        // text field, which is what makes cut/copy/paste/undo work.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
