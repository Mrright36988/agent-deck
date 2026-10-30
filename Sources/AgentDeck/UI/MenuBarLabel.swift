import DeckCore
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var store: DeckStore

    var body: some View {
        let inbox = store.inbox
        let waiting = inbox.waitingCount
        let running = inbox.sessions.values.filter { inbox.state(of: $0) == .running }.count
        HStack(spacing: 3) {
            Image(systemName: waiting > 0 ? "square.stack.3d.up.fill" : "square.stack.3d.up")
            if waiting > 0 {
                Text("\(waiting)")
            } else if running > 0 {
                Image(systemName: "play.fill").imageScale(.small)
                Text("\(running)")
            }
            if store.usage.contains(where: { $0.level == .critical }) {
                Image(systemName: "exclamationmark.triangle.fill")
            }
        }
    }
}
