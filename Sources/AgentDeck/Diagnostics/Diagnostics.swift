import AppKit
import DeckCore
import SwiftUI
import UserNotifications

/// `agentdeck://diag/<action>` hooks for checking the running app from a shell (`open -g …`).
/// None of them can answer a card: any web page can open agentdeck:// links.
@MainActor
enum Diagnostics {
    static func handle(_ url: URL) {
        guard url.host == "diag" else { return Log.write("ignored url=\(url)") }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        Log.write("diag \(url.path) query=\(query.map { "\($0.name)=\($0.value ?? "")" })")
        switch url.path {
        case "/status": logStatus()
        case "/notify": Notifier.shared.sendTest()
        case "/panel": PanelController.shared.toggle()
        case "/dump": dumpInbox()
        case "/snapshot": render(InboxView(store: DeckStore.shared), to: "snapshot.png")
        case "/demo":
            let count = Int(query.first(where: { $0.name == "windows" })?.value ?? "") ?? 4
            render(InboxView(store: DemoData.store(windowCount: count)), to: "demo-\(count).png")
        case "/jump":
            if let session = query.first(where: { $0.name == "session" })?.value { DeckStore.shared.jump(session) }
        case "/notice":
            let text = query.first(where: { $0.name == "text" })?.value ?? "测试提示"
            DeckStore.shared.show(text, for: Double(query.first(where: { $0.name == "seconds" })?.value ?? "") ?? 6)
        case "/jumpwindow":
            let store = DeckStore.shared
            let map = WindowMap.build(windows: store.windows, inbox: store.inbox)
            if let name = query.first(where: { $0.name == "name" })?.value,
               let island = (map.islands + map.quiet).first(where: { $0.name == name }) {
                store.jumpToWindow(island)
            }
        default: Log.write("unknown diag action \(url.path)")
        }
    }

    static func logStatus() {
        Log.write("status frontmost=\(frontmostBundleID())")
        UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
            Log.write("status notifications=\(settings.authorizationStatus.rawValue) (0 notDetermined, 1 denied, 2 authorized, 3 provisional)")
        }
    }

    /// Renders `view` the way the menu bar window sizes it (to its fitting size) into `name` in the log
    /// directory, offscreen, so the layout can be checked without screen-recording permission.
    static func render(_ view: InboxView, to name: String) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSApp.effectiveAppearance
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        let size = host.fittingSize
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = Log.directory.appendingPathComponent(name)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            Log.write("rendered \(Int(size.width))x\(Int(size.height)) -> \(url.path)")
            window.contentView = nil
        }
    }

    static func dumpInbox() {
        let store = DeckStore.shared
        let inbox = store.inbox
        Log.write("dump sessions=\(inbox.sessions.count) waiting=\(inbox.waitingCount) notice=\(store.notice ?? "-")")
        for window in store.usage {
            Log.write("dump usage [\(window.tool.rawValue)] \(window.label) \(window.percent)% detail=\(window.detail ?? "-") resets=\(window.resetsAt.map { "\($0)" } ?? "-") eta=\(window.depletesAt.map { "\($0)" } ?? "-")")
        }
        if let note = store.usageNote { Log.write("dump usage note=\(note)") }
        for session in inbox.ordered {
            let cards = inbox.cards(for: session.id).map { "\($0.summary)\(store.canAnswer($0.id) ? "" : " (answer in Cursor)")" }
            Log.write("dump \(inbox.state(of: session).label) [\(session.tool.rawValue)] \(session.displayTitle) | \(session.project) | id=\(session.id.prefix(8)) cards=\(cards) last=\(session.lastMessage?.prefix(40) ?? "")")
        }
    }
}
