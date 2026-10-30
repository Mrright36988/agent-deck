import Foundation

/// The full content of an approval, as the deck shows it before anyone can approve.
public struct ApprovalDetail: Sendable, Equatable {
    public enum Style: Sendable { case command, diff, text }

    public let headline: String
    public let body: String
    public let style: Style

    public init(toolName: String, input: JSONValue) {
        switch toolName {
        case "Bash":
            headline = input["description"]?.string ?? "运行命令"
            body = input["command"]?.string ?? ""
            style = .command
        case "Edit":
            headline = "修改 \(input["file_path"]?.string ?? "")"
            body = Self.diff(old: input["old_string"]?.string ?? "", new: input["new_string"]?.string ?? "")
            style = .diff
        case "MultiEdit":
            headline = "修改 \(input["file_path"]?.string ?? "")"
            body = (input["edits"]?.array ?? [])
                .map { Self.diff(old: $0["old_string"]?.string ?? "", new: $0["new_string"]?.string ?? "") }
                .joined(separator: "\n⋯\n")
            style = .diff
        case "Write":
            headline = "写入 \(input["file_path"]?.string ?? "")"
            body = input["content"]?.string ?? ""
            style = .text
        default:
            // Codex sends shell commands as `cmd` or `command` (string or argv array).
            if let command = input["cmd"]?.string ?? input["command"]?.string
                ?? input["command"]?.array?.compactMap(\.string).joined(separator: " ") {
                headline = "\(toolName) 运行命令"
                body = command
                style = .command
            } else {
                headline = "使用 \(toolName)"
                body = String(data: (try? JSONSerialization.data(withJSONObject: Self.plain(input), options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
                style = .text
            }
        }
    }

    /// Short enough to read in full inside a notification, so approving from there is not approving blind.
    public var fitsInNotification: Bool {
        style == .command && body.count <= 300 && body.split(separator: "\n").count <= 4
    }

    static func diff(old: String, new: String) -> String {
        let removed = old.split(separator: "\n", omittingEmptySubsequences: false).map { "- \($0)" }
        let added = new.split(separator: "\n", omittingEmptySubsequences: false).map { "+ \($0)" }
        return (removed + added).joined(separator: "\n")
    }

    private static func plain(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(plain)
        case .object(let v): return v.mapValues(plain)
        }
    }
}
