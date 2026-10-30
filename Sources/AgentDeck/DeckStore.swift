import DeckCore
import Foundation

/// The app's single source of truth: the inbox, the hooks waiting on it, and the periodic disk scan.
@MainActor
final class DeckStore: ObservableObject {
    static let shared = DeckStore()
    static let socketPath = Log.directory.appendingPathComponent("deck.sock").path

    /// Holding a Codex approval is only safe if the Codex plugin keeps showing its own prompt meanwhile,
    /// which is not verified yet (spike). Until then Codex approvals are listed but answered in Cursor.
    static let holdsCodexApprovals = false

    @Published private(set) var inbox = Inbox()
    @Published private(set) var usage: [UsageWindow] = []
    @Published private(set) var usageNote: String?
    /// Open Cursor windows, refreshed with the disk scan; the map draws one island per window.
    @Published private(set) var windows: [IDEWindow] = []
    /// One-line feedback for the last jump or reply, shown above the map; set it with `show(_:for:)`.
    @Published var notice: String?
    private var noticeExpiry: Task<Void, Never>?
    private var replies: [UUID: PendingReply] = [:]
    private var server: HookServer?
    private let discovery = SessionDiscovery()
    private let scanner = DiskScanner()
    private let usageMonitor = UsageMonitor()

    /// A preview store shows its cards as answerable, the way a live card with a waiting hook looks.
    private let isPreview: Bool

    init() {
        isPreview = false
    }

    /// A store that is never started, holding the given state: renders the UI offscreen (`DemoData`).
    init(preview inbox: Inbox, windows: [IDEWindow], usage: [UsageWindow]) {
        isPreview = true
        self.inbox = inbox
        self.windows = windows
        self.usage = usage
    }

    func start() {
        let server = HookServer(path: Self.socketPath, log: { Log.write($0) }) { [weak self] envelope, reply in
            self?.receive(envelope, reply: reply)
        }
        do {
            try server.start()
            self.server = server
            Log.write("hook server listening at \(Self.socketPath)")
        } catch {
            Log.write("hook server failed to start: \(error)")
        }
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        usageMonitor.onChange = { [weak self] windows, note in
            self?.usage = windows
            self?.usageNote = note
        }
        usageMonitor.start()
    }

    func receive(_ envelope: HookEnvelope, reply: PendingReply?) {
        guard discovery.isInteractive(envelope) else {
            reply?.send(nil)  // headless runs never wait on the deck and stay out of the inbox
            return
        }
        if envelope.event != "PostToolUse" {
            Log.write("hook \(envelope.tool.rawValue) \(envelope.event) \(envelope.sessionId?.prefix(8) ?? "-")")
        }
        let change = inbox.apply(envelope, at: .now)
        if let reply {
            if let card = change.opened, envelope.tool == .claude || Self.holdsCodexApprovals {
                replies[card.id] = reply
                reply.onDrop { [weak self] in self?.release(card.id) }
            } else {
                reply.send(nil)
            }
        }
        change.closed.forEach(release)

        guard let sessionId = envelope.sessionId, let session = inbox.sessions[sessionId] else { return }
        if let card = change.opened {
            Notifier.shared.cardOpened(card, in: session, answerable: canAnswer(card.id))
        } else if ["Stop", "StopFailure"].contains(envelope.event), inbox.state(of: session) == .doneUnread {
            Notifier.shared.sessionDone(session)
        }
    }

    /// Shows `message` until `seconds` pass or another message replaces it. A jump that worked gets a short
    /// time: by then the deck is usually behind Cursor, and the banner would otherwise outlive what it says.
    func show(_ message: String, for seconds: Double = 20) {
        notice = message
        noticeExpiry?.cancel()
        noticeExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    private func report(_ outcome: Jumper.Outcome) {
        switch outcome {
        case .windowOnly(let message): show(message, for: 6)
        case .unavailable(let message): show(message)
        }
    }

    /// True while the hook behind this card is still waiting, so an answer from the deck takes effect.
    func canAnswer(_ cardId: UUID) -> Bool {
        isPreview || replies[cardId] != nil
    }

    /// Answers a card from the deck; the waiting hook prints `output` and the session carries on.
    func answer(_ cardId: UUID, with output: JSONValue) {
        guard let reply = replies.removeValue(forKey: cardId) else {
            show("这个请求已经在别处处理过了")
            return
        }
        reply.send(output)
        inbox.removeCard(cardId)
        Notifier.shared.withdraw(card: cardId)
    }

    func answerQuestion(_ cardId: UUID, picks: [String: [String]]) {
        guard case .question(_, let input)? = inbox.cards[cardId]?.kind else { return }
        answer(cardId, with: HookAnswer.answer(input, picks: picks))
    }

    func answerQuestion(_ cardId: UUID, option index: Int) {
        guard case .question(let questions, _)? = inbox.cards[cardId]?.kind,
              let question = questions.first, question.options.indices.contains(index) else { return }
        answerQuestion(cardId, picks: [question.text: [question.options[index].label]])
    }

    func jump(_ sessionId: String) {
        guard let session = inbox.sessions[sessionId] else { return }
        inbox.markRead(sessionId)
        Task { report(await Jumper.jump(to: session)) }
    }

    /// Raises the window an island stands for, without marking any of its sessions read.
    func jumpToWindow(_ island: Island) {
        guard let window = windows.first(where: { Set($0.workspaceFolders.map { ($0 as NSString).standardizingPath }) == Set(island.folders) }) else {
            show("「\(island.name)」不在打开的 Cursor 窗口里")
            return
        }
        Task { report(await Jumper.raise(window, name: island.name)) }
    }

    func replyToCodex(_ sessionId: String, text: String) {
        Task {
            if let error = await CodexQueue.send(text, to: sessionId) {
                show("回复没有发出去：\(error)")
            } else {
                inbox.markRead(sessionId)
                notice = nil
            }
        }
    }

    func markRead(_ sessionId: String) {
        inbox.markRead(sessionId)
    }

    private func release(_ cardId: UUID) {
        replies.removeValue(forKey: cardId)?.send(nil)
        inbox.removeCard(cardId)
        Notifier.shared.withdraw(card: cardId)
    }

    private func refresh() async {
        let windows = await scanner.cursorWindows()
        if windows != self.windows { self.windows = windows }
        let live = await scanner.liveClaudeSessions()
        let codexThreads = await scanner.recentCodexThreads()
        let codexIds = Set(inbox.sessions.values.filter { $0.tool == .codex }.map(\.id)).union(codexThreads.map(\.id))
        let codexTitles = await scanner.codexTitles(for: Array(codexIds))
        let now = Date()
        let liveIds = Set(live.map(\.id))
        discovery.noteLiveClaude(liveIds)
        for found in live {
            inbox.discovered(id: found.id, tool: .claude, cwd: found.cwd, title: found.title, busy: found.busy,
                             activeAt: found.activeAt, at: now)
        }
        for found in codexThreads {
            inbox.discovered(id: found.id, tool: .codex, cwd: found.cwd, title: codexTitles[found.id], busy: found.busy,
                             activeAt: found.activeAt, at: now)
        }
        let recentCodex = Set(codexThreads.map(\.id))
        for session in inbox.sessions.values {
            switch session.tool {
            case .claude where !liveIds.contains(session.id):
                inbox.removeSession(session.id).forEach(release)
            case .codex where inbox.cards(for: session.id).isEmpty && !recentCodex.contains(session.id)
                && now.timeIntervalSince(session.updatedAt) > 2 * 3600:
                inbox.removeSession(session.id).forEach(release)
            case .codex:
                if let title = codexTitles[session.id] {
                    inbox.discovered(id: session.id, tool: .codex, cwd: session.cwd, title: title, busy: nil, at: now)
                }
            default:
                break
            }
        }
    }
}
