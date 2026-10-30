import AppKit
import SwiftUI

@main
struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            InboxView(store: DeckStore.shared)
        } label: {
            MenuBarLabel(store: DeckStore.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched bundle=\(Bundle.main.bundleIdentifier ?? "-")")
        Notifier.shared.setUp()
        DeckStore.shared.start()
        Diagnostics.logStatus()
    }

    /// `agentdeck://diag/...` lets checks run from a shell (`open -g`) without clicking the menu.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(Diagnostics.handle)
    }
}
