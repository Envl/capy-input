import AppKit
import SwiftUI

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static let appName = "capy-companion"
    static let showMenuBarIconKey = "showMenuBarIcon"

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.setDockIconVisible(!UserDefaults.standard.bool(forKey: Self.showMenuBarIconKey))
        MacDictionarySync.shared.start()
        ScreenWordSuggestions.shared.start()
        _ = AppUpdater.shared
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScreenWordSuggestions.shared.disarm()
    }

    static func setDockIconVisible(_ visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        let window = NSApp.keyWindow
        NSApp.setActivationPolicy(policy)
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        if updater.isEnabled {
            Button(L10n.checkForUpdates) { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

struct CapyCompanionMenu: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(InterfaceLanguage.preferenceKey) private var language = InterfaceLanguage.system

    var body: some View {
        Button(L10n.openCapyCompanion) {
            openWindow(id: "main")
            NSApp.activate()
        }
        CheckForUpdatesButton()
        Divider()
        Button(L10n.quitCapyCompanion) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
