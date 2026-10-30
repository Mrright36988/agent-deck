import DeckCore
import Foundation
import UserNotifications

/// macOS notifications for sessions that need you. Buttons answer in place only when the notification
/// shows everything being approved; anything longer opens the deck panel instead.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private enum Action {
        static let allow = "ALLOW", deny = "DENY", view = "VIEW", open = "OPEN", read = "READ", reply = "REPLY"
        static let option = "OPT_"
    }

    private var categories: [String: UNNotificationCategory] = [:]

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let view = UNNotificationAction(identifier: Action.view, title: "查看")
        let open = UNNotificationAction(identifier: Action.open, title: "跳到会话")
        let read = UNNotificationAction(identifier: Action.read, title: "标为已读")
        for category in [
            UNNotificationCategory(identifier: "APPROVAL", actions: [
                UNNotificationAction(identifier: Action.allow, title: "允许"),
                UNNotificationAction(identifier: Action.deny, title: "拒绝", options: [.destructive]), view,
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "VIEW", actions: [view, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "DONE", actions: [open, read], intentIdentifiers: []),
            UNNotificationCategory(identifier: "DONE_CODEX", actions: [
                UNTextInputNotificationAction(identifier: Action.reply, title: "回复", options: [],
                                              textInputButtonTitle: "发送", textInputPlaceholder: "回复 Codex"),
                open, read,
            ], intentIdentifiers: []),
        ] {
            categories[category.identifier] = category
        }
        center.setNotificationCategories(Set(categories.values))
        // UserNotifications calls back on a background queue; an explicitly @Sendable closure keeps
        // Swift 6 from inferring main-actor isolation and trapping on the isolation check.
        center.requestAuthorization(options: [.alert, .sound]) { @Sendable granted, error in
            Log.write("notification authorization granted=\(granted) error=\(error.map(String.init(describing:)) ?? "-")")
        }
    }

    func cardOpened(_ card: Card, in session: Session, answerable: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "\(session.tool == .claude ? "Claude" : "Codex") 等你处理 · \(session.project)"
        content.subtitle = session.displayTitle
        content.userInfo = ["card": card.id.uuidString, "session": session.id]
        content.sound = .default
        switch card.kind {
        case .approval(let tool, let input):
            let detail = ApprovalDetail(toolName: tool, input: input)
            content.body = "\(detail.headline)\n\(detail.body.prefix(300))"
            content.categoryIdentifier = answerable && detail.fitsInNotification ? "APPROVAL" : "VIEW"
        case .question(let questions, _):
            let first = questions[0]
            content.body = ([first.text] + first.options.map { "· \($0.label)" }).joined(separator: "\n")
            let simple = questions.count == 1 && !first.multiSelect && (1...3).contains(first.options.count)
            content.categoryIdentifier = answerable && simple ? questionCategory(first.options.map(\.label)) : "VIEW"
        }
        post(content, id: card.id.uuidString)
    }

    func sessionDone(_ session: Session) {
        let content = UNMutableNotificationContent()
        content.title = "\(session.tool == .claude ? "Claude" : "Codex") 完成 · \(session.project)"
        content.subtitle = session.displayTitle
        content.body = String((session.lastMessage ?? "").prefix(240))
        content.userInfo = ["session": session.id]
        content.categoryIdentifier = session.tool == .codex ? "DONE_CODEX" : "DONE"
        post(content, id: "done-\(session.id)")
    }

    func withdraw(card id: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "agent-deck"
        content.body = "测试通知"
        post(content, id: UUID().uuidString)
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { @Sendable error in
            if let error { Log.write("notification failed: \(error)") }
        }
    }

    /// Option buttons are part of a category, so each distinct set of option labels gets its own.
    private func questionCategory(_ labels: [String]) -> String {
        let id = "Q:" + labels.joined(separator: "\u{1F}")
        if categories[id] == nil {
            let options = labels.enumerated().map { UNNotificationAction(identifier: Action.option + "\($0.offset)", title: $0.element) }
            categories[id] = UNNotificationCategory(identifier: id, actions: options + [UNNotificationAction(identifier: Action.view, title: "查看")],
                                                    intentIdentifiers: [])
            UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
        }
        return id
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let card = (info["card"] as? String).flatMap(UUID.init(uuidString:))
        let session = info["session"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            Notifier.handle(action: action, card: card, session: session, text: text)
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    private static func handle(action: String, card: UUID?, session: String?, text: String?) {
        let store = DeckStore.shared
        Log.write("notification action=\(action) card=\(card?.uuidString.prefix(8) ?? "-")")
        switch action {
        case Action.allow:
            if let card { store.answer(card, with: HookAnswer.allow()) }
        case Action.deny:
            if let card { store.answer(card, with: HookAnswer.deny("在 agent-deck 里拒绝")) }
        case _ where action.hasPrefix(Action.option):
            if let card, let index = Int(action.dropFirst(Action.option.count)) { store.answerQuestion(card, option: index) }
        case Action.reply:
            if let session, let text, !text.isEmpty { store.replyToCodex(session, text: text) }
        case Action.read:
            if let session { store.markRead(session) }
        case Action.open:
            if let session { store.jump(session) }
        default:  // "查看" or a click on the notification body
            if card != nil { PanelController.shared.show() } else if let session { store.jump(session) }
        }
    }
}
