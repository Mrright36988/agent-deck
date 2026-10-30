import Foundation

/// Sends a reply to a Codex thread with `codex queue`; the Cursor plugin picks it up as a user message (spike).
enum CodexQueue {
    private static let cli = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Returns nil on success, otherwise what went wrong.
    static func send(_ text: String, to threadId: String) async -> String? {
        guard let cli else { return "找不到 codex 命令" }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["queue", "--thread", threadId, "--message", text]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errorLog = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-codex-queue.err")
            FileManager.default.createFile(atPath: errorLog.path, contents: nil)
            process.standardError = try? FileHandle(forWritingTo: errorLog)
            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                let detail = (try? String(contentsOf: errorLog, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: status == 0 ? nil : (detail.isEmpty ? "codex queue 退出码 \(status)" : detail))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: error.localizedDescription)
            }
        }
    }
}
