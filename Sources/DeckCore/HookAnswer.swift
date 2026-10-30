import Foundation

/// Hook output for a PermissionRequest answered in the deck (same shape for Claude Code and Codex).
public enum HookAnswer {
    public static func allow() -> JSONValue {
        decision(["behavior": .string("allow")])
    }

    public static func deny(_ message: String) -> JSONValue {
        decision(["behavior": .string("deny"), "message": .string(message)])
    }

    /// Answers an AskUserQuestion call: echo the original questions and add `answers` keyed by question text.
    /// Multi-select picks are joined with ", ".
    public static func answer(_ input: JSONValue, picks: [String: [String]]) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if case .object(let object) = input { fields = object }
        fields["answers"] = .object(picks.mapValues { .string($0.joined(separator: ", ")) })
        return decision(["behavior": .string("allow"), "updatedInput": .object(fields)])
    }

    private static func decision(_ fields: [String: JSONValue]) -> JSONValue {
        .object(["hookSpecificOutput": .object([
            "hookEventName": .string("PermissionRequest"),
            "decision": .object(fields),
        ])])
    }
}
