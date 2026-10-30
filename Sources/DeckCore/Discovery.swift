import Foundation

/// A Cursor window as described by the Claude Code extension's lock file (`~/.claude/ide/<port>.lock`).
public struct IDEWindow: Sendable, Equatable {
    public let pid: Int32
    public let workspaceFolders: [String]
    public let ideName: String

    public init(pid: Int32, workspaceFolders: [String], ideName: String) {
        self.pid = pid
        self.workspaceFolders = workspaceFolders
        self.ideName = ideName
    }

    /// True when `path` is one of the window's folders or sits under one of them.
    public func contains(path: String) -> Bool {
        let target = (path as NSString).standardizingPath
        return workspaceFolders.contains { folder in
            let root = (folder as NSString).standardizingPath
            return target == root || target.hasPrefix(root + "/")
        }
    }
}

public enum IDELocks {
    public static func parse(_ data: Data) -> IDEWindow? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int,
              let folders = object["workspaceFolders"] as? [String] else { return nil }
        return IDEWindow(pid: Int32(pid), workspaceFolders: folders, ideName: object["ideName"] as? String ?? "")
    }

    public static func load(directory: URL) -> [IDEWindow] {
        jsonFiles(in: directory, withExtension: "lock").compactMap(parse)
    }
}

/// A live Claude Code process from the session registry (`~/.claude/sessions/<pid>.json`).
public struct ClaudeSession: Sendable, Equatable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    public let name: String
    public let status: String
    public let entrypoint: String
    /// When the session last changed between busy and idle (registry times are epoch milliseconds).
    public var activeAt: Date? = nil

    public var isFromIDE: Bool { entrypoint == "claude-vscode" }
}

public enum ClaudeRegistry {
    public static func parse(_ data: Data) -> ClaudeSession? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int,
              let sessionId = object["sessionId"] as? String,
              let cwd = object["cwd"] as? String else { return nil }
        let millis = (object["statusUpdatedAt"] ?? object["updatedAt"]) as? Double
        return ClaudeSession(pid: Int32(pid), sessionId: sessionId, cwd: cwd,
                             name: object["name"] as? String ?? "",
                             status: object["status"] as? String ?? "",
                             entrypoint: object["entrypoint"] as? String ?? "",
                             activeAt: millis.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    public static func load(directory: URL) -> [ClaudeSession] {
        jsonFiles(in: directory, withExtension: "json").compactMap(parse)
    }

    /// The live sessions running in an IDE. A `claude -p` that a session starts itself (a script run from a Bash
    /// tool call) inherits that session's CLAUDE_CODE_ENTRYPOINT=claude-vscode, so it registers as an IDE session
    /// too; it is told apart by another registered session among its ancestor processes.
    public static func liveIDESessions(_ sessions: [ClaudeSession],
                                       isAlive: (Int32) -> Bool = ClaudeRegistry.isAlive(pid:),
                                       parent: (Int32) -> Int32? = ClaudeRegistry.parentPID(of:)) -> [ClaudeSession] {
        let live = sessions.filter { isAlive($0.pid) }
        let pids = Set(live.map(\.pid))
        return live.filter { $0.isFromIDE && !descends(from: pids, pid: $0.pid, parent: parent) }
    }

    static func descends(from pids: Set<Int32>, pid: Int32, parent: (Int32) -> Int32?) -> Bool {
        var current = pid
        for _ in 0..<32 {
            guard let next = parent(current), next > 1, next != current else { return false }
            if pids.contains(next) { return true }
            current = next
        }
        return false
    }

    public static func isAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    public static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

/// The first line of a Codex rollout file (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).
public struct CodexThread: Sendable, Equatable {
    public let id: String
    public let cwd: String
    public let originator: String
    public let file: URL

    public var isFromIDE: Bool { originator == "codex_vscode" }
}

public enum CodexRollouts {
    public static func parseMeta(firstLine: Data, file: URL) -> CodexThread? {
        guard let object = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              let cwd = payload["cwd"] as? String else { return nil }
        return CodexThread(id: id, cwd: cwd, originator: payload["originator"] as? String ?? "", file: file)
    }

    /// Threads whose rollout file changed within `window`, newest first.
    public static func recent(sessionsRoot: URL, within window: TimeInterval, now: Date = Date()) -> [CodexThread] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: sessionsRoot, includingPropertiesForKeys: keys) else { return [] }
        var found: [(Date, CodexThread)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  now.timeIntervalSince(modified) <= window,
                  let line = firstLine(of: url),
                  let thread = parseMeta(firstLine: line, file: url) else { continue }
            found.append((modified, thread))
        }
        return found.sorted { $0.0 > $1.0 }.map(\.1)
    }

    public static func firstLine(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                buffer.append(chunk[chunk.startIndex..<newline])
                return buffer
            }
            buffer.append(chunk)
        }
        return buffer.isEmpty ? nil : buffer
    }
}

private func jsonFiles(in directory: URL, withExtension ext: String) -> [Data] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == ext }.compactMap { try? Data(contentsOf: $0) }
}
