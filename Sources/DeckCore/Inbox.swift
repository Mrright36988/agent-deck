import Foundation

public enum Tool: String, Sendable, Codable {
    case claude, codex
}

/// One hook invocation as forwarded by `deck-hook`: `{"v":1,"tool":…,"event":…,"wait":…,"payload":{…}}`.
public struct HookEnvelope: Sendable, Codable, Equatable {
    public let tool: Tool
    public let event: String
    public let wait: Bool
    public let payload: JSONValue

    public init(tool: Tool, event: String, wait: Bool, payload: JSONValue) {
        self.tool = tool
        self.event = event
        self.wait = wait
        self.payload = payload
    }

    public var sessionId: String? { payload["session_id"]?.string }
}

public struct Question: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public let label: String
        public let detail: String?
    }

    public let text: String
    public let header: String?
    public let options: [Option]
    public let multiSelect: Bool

    /// Parses the `questions` array of an AskUserQuestion tool input.
    static func parse(_ value: JSONValue?) -> [Question]? {
        guard let items = value?.array, !items.isEmpty else { return nil }
        let questions = items.compactMap { item -> Question? in
            guard let text = item["question"]?.string else { return nil }
            let options = (item["options"]?.array ?? []).compactMap { option in
                option["label"]?.string.map { Option(label: $0, detail: option["description"]?.string) }
            }
            return Question(text: text, header: item["header"]?.string, options: options,
                            multiSelect: item["multiSelect"]?.bool ?? false)
        }
        return questions.count == items.count ? questions : nil
    }
}

/// Something a session is blocked on until someone answers it, here or in Cursor.
public struct Card: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        case approval(toolName: String, input: JSONValue)
        case question([Question], input: JSONValue)
    }

    public let id: UUID
    public let sessionId: String
    public let tool: Tool
    public let kind: Kind
    public let createdAt: Date

    public var toolName: String {
        switch kind {
        case .approval(let name, _): return name
        case .question: return "AskUserQuestion"
        }
    }

    /// True when a later PostToolUse with this tool and input shows the call already went ahead.
    func isSettled(byToolNamed name: String, input: JSONValue?) -> Bool {
        guard name == toolName, let input else { return false }
        switch kind {
        case .approval(_, let original): return original == input
        case .question(_, let original): return original["questions"] == input["questions"]
        }
    }
}

public struct Session: Sendable, Identifiable, Equatable {
    public let id: String
    public let tool: Tool
    public var cwd: String
    public var title: String?
    public var lastMessage: String?
    public var permissionMode: String?
    public var transcriptPath: String?
    public var running = false
    public var unread = false
    public var updatedAt: Date

    public init(id: String, tool: Tool, cwd: String, updatedAt: Date) {
        self.id = id
        self.tool = tool
        self.cwd = cwd
        self.updatedAt = updatedAt
    }

    public var project: String { (cwd as NSString).lastPathComponent }
    public var displayTitle: String { title?.isEmpty == false ? title! : project }
}

/// Inbox order: blocked on you, then finished and unread, then running, then the rest.
public enum SessionState: Int, Sendable, Comparable, CaseIterable {
    case waiting, doneUnread, running, idle

    public static func < (lhs: SessionState, rhs: SessionState) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The deck's state, changed only by hook events, discovery and user actions. Pure, so it can be tested.
public struct Inbox: Sendable {
    public private(set) var sessions: [String: Session] = [:]
    public private(set) var cards: [UUID: Card] = [:]

    public init() {}

    public struct Change: Sendable, Equatable {
        /// The card this event opened; its hook stays connected until the card is closed.
        public var opened: Card?
        /// Cards this event settled elsewhere; their hooks must be released without a decision.
        public var closed: [UUID] = []
    }

    @discardableResult
    public mutating func apply(_ envelope: HookEnvelope, cardId: UUID = UUID(), at now: Date) -> Change {
        let payload = envelope.payload
        guard let sessionId = envelope.sessionId else { return Change() }
        var change = Change()

        if envelope.event == "SessionEnd" {
            change.closed = closeCards { $0.sessionId == sessionId }
            sessions[sessionId] = nil
            return change
        }

        // A session keeps the directory it started in: hooks report the shell's current directory,
        // which moves whenever the agent runs `cd`.
        var session = sessions[sessionId] ?? Session(id: sessionId, tool: envelope.tool,
                                                    cwd: payload["cwd"]?.string ?? "", updatedAt: now)
        session.updatedAt = now
        if session.cwd.isEmpty, let cwd = payload["cwd"]?.string { session.cwd = cwd }
        if let mode = payload["permission_mode"]?.string { session.permissionMode = mode }
        if let path = payload["transcript_path"]?.string { session.transcriptPath = path }

        switch envelope.event {
        case "UserPromptSubmit":
            session.running = true
            session.unread = false
            change.closed = closeCards { $0.sessionId == sessionId }
        case "PermissionRequest" where envelope.wait:
            session.running = true
            let toolName = payload["tool_name"]?.string ?? "?"
            let input = payload["tool_input"] ?? .null
            let kind: Card.Kind = toolName == "AskUserQuestion"
                ? Question.parse(input["questions"]).map { .question($0, input: input) } ?? .approval(toolName: toolName, input: input)
                : .approval(toolName: toolName, input: input)
            let card = Card(id: cardId, sessionId: sessionId, tool: envelope.tool, kind: kind, createdAt: now)
            cards[card.id] = card
            change.opened = card
        case "PostToolUse":
            session.running = true
            let toolName = payload["tool_name"]?.string ?? ""
            change.closed = closeCards { $0.sessionId == sessionId && $0.isSettled(byToolNamed: toolName, input: payload["tool_input"]) }
        case "Stop", "StopFailure":
            session.running = false
            session.unread = true
            if let message = payload["last_assistant_message"]?.string { session.lastMessage = message }
            change.closed = closeCards { $0.sessionId == sessionId }
        default:
            break
        }
        sessions[sessionId] = session
        return change
    }

    /// Adds or refreshes a session found by scanning on-disk state, without touching hook-derived flags.
    /// `activeAt` is the last activity the disk shows (registry status change, rollout write); it orders
    /// sessions and drives "x minutes ago" until hook events take over.
    public mutating func discovered(id: String, tool: Tool, cwd: String, title: String?, busy: Bool?,
                                    activeAt: Date? = nil, at now: Date) {
        var session = sessions[id] ?? Session(id: id, tool: tool, cwd: cwd, updatedAt: activeAt ?? now)
        if let activeAt, activeAt > session.updatedAt { session.updatedAt = activeAt }
        if !cwd.isEmpty { session.cwd = cwd }  // the registry records where the session started
        if let title, !title.isEmpty { session.title = title }
        if sessions[id] == nil, let busy { session.running = busy }
        sessions[id] = session
    }

    public mutating func removeSession(_ id: String) -> [UUID] {
        sessions[id] = nil
        return closeCards { $0.sessionId == id }
    }

    public mutating func removeCard(_ id: UUID) {
        cards[id] = nil
    }

    public mutating func markRead(_ sessionId: String) {
        sessions[sessionId]?.unread = false
    }

    public func state(of session: Session) -> SessionState {
        if cards.values.contains(where: { $0.sessionId == session.id }) { return .waiting }
        if session.running { return .running }
        return session.unread ? .doneUnread : .idle
    }

    public func cards(for sessionId: String) -> [Card] {
        cards.values.filter { $0.sessionId == sessionId }.sorted { $0.createdAt < $1.createdAt }
    }

    public var ordered: [Session] {
        sessions.values.sorted {
            let (a, b) = (state(of: $0), state(of: $1))
            return a != b ? a < b : $0.updatedAt > $1.updatedAt
        }
    }

    public var waitingCount: Int { Set(cards.values.map(\.sessionId)).count }

    private mutating func closeCards(where match: (Card) -> Bool) -> [UUID] {
        let ids = cards.values.filter(match).map(\.id)
        ids.forEach { cards[$0] = nil }
        return ids
    }
}
