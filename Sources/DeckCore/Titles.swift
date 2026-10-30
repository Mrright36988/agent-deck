import Foundation

/// Human-readable session titles, as the plugins show them on their tabs.
public enum Titles {
    /// The last `"aiTitle"` a Claude transcript recorded; Claude Code rewrites it as the conversation evolves.
    public static func claudeAITitle(in transcript: Data) -> String? {
        var title: String?
        for line in transcript.split(separator: UInt8(ascii: "\n")) where line.count < 1_000_000 {
            guard line.range(of: Data(#""aiTitle""#.utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let value = object["aiTitle"] as? String, !value.isEmpty else { continue }
            title = value
        }
        return title
    }

    /// Codex thread names from `~/.codex/session_index.jsonl`; later lines win.
    public static func codexThreadNames(in index: Data) -> [String: String] {
        var names: [String: String] = [:]
        for line in index.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String, !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }
}
