import DeckCore
import Foundation

/// Polls both tools' usage limits and keeps a short history per limit for the depletion forecast.
@MainActor
final class UsageMonitor {
    var onChange: (([UsageWindow], String?) -> Void)?

    private var claude: [UsageWindow] = []
    private var codex: [UsageWindow] = []
    private var claudeNote: String?
    private var samples: [String: [(at: Date, percent: Double)]] = [:]

    func start() {
        Task {
            while !Task.isCancelled {
                await refreshCodex()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        Task {
            while !Task.isCancelled {
                await refreshClaude()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func refreshClaude() async {
        if let response = await ClaudeUsageCall.fetch() {
            claude = record(ClaudeUsage.parse(response))
            claudeNote = claude.isEmpty ? "Claude 没有返回额度数据" : nil
        } else {
            claudeNote = "Claude 额度暂时取不到（读取接口是实验性的，可能随插件升级变化）"
        }
        onChange?(claude + codex, claudeNote)
    }

    private func refreshCodex() async {
        let limits = await Task.detached(priority: .utility) { CodexUsageReader.latest() }.value
        codex = limits.map { record(CodexUsage.parse($0)) } ?? []
        onChange?(claude + codex, claudeNote)
    }

    /// Adds a sample per limit (restarting the history when usage drops, i.e. after a reset) and forecasts.
    private func record(_ windows: [UsageWindow]) -> [UsageWindow] {
        let now = Date()
        return windows.map { window in
            var history = samples[window.id] ?? []
            if let last = history.last, window.percent < last.percent { history = [] }
            history.append((now, window.percent))
            history = Array(history.suffix(240))  // a few hours of samples at the polling rates above
            samples[window.id] = history
            var forecast = window
            // A monthly limit without a reset date: assume no later than the next calendar month,
            // so a pace that only runs out after it is not reported as a problem.
            let bound = window.resetsAt ?? (window.id == "claude.spend" ? Self.startOfNextMonth(after: now) : nil)
            forecast.depletesAt = UsageForecast.depletion(samples: history, resetsAt: bound, now: now)
            return forecast
        }
    }

    private static func startOfNextMonth(after date: Date) -> Date? {
        let calendar = Calendar.current
        let month = calendar.dateInterval(of: .month, for: date)
        return month?.end
    }
}

/// Reads `rate_limits` from the newest Codex rollouts; Codex records them with every `token_count` event.
enum CodexUsageReader {
    static func latest() -> JSONValue? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let calendar = Calendar(identifier: .gregorian)
        let days = (0..<8).compactMap { calendar.date(byAdding: .day, value: -$0, to: Date()) }
        var files: [(URL, Date)] = []
        for day in days {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for entry in entries where entry.pathExtension == "jsonl" {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((entry, modified))
            }
        }
        for (file, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            if let limits = lastRateLimits(in: file) { return limits }
        }
        return nil
    }

    private static func lastRateLimits(in file: URL) -> JSONValue? {
        guard let handle = try? FileHandle(forReadingFrom: file), let size = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        let tail: UInt64 = 512 * 1024
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let marker = Data(#""rate_limits":{"#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            if let event = try? JSONDecoder().decode(JSONValue.self, from: line),
               let limits = event["payload"]?["rate_limits"], limits["primary"] != nil {
                return limits
            }
        }
        return nil
    }
}

/// Asks Claude Code for its usage limits through the SDK control request its own usage panel uses
/// (`get_usage`, marked experimental). No model call is made; it answers in well under a second.
final class ClaudeUsageCall: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<JSONValue?, Never>?

    static func fetch(timeout: TimeInterval = 15) async -> JSONValue? {
        guard let binary = binary() else { return nil }
        let call = ClaudeUsageCall()
        return await withCheckedContinuation { continuation in
            call.start(binary: binary, timeout: timeout, continuation: continuation)
        }
    }

    /// The newest Claude Code binary the Cursor plugin ships; the CLI on PATH can lag far behind it.
    static func binary() -> String? {
        let extensions = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/extensions")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: extensions.path)) ?? []
        let newest = folders.filter { $0.hasPrefix("anthropic.claude-code-") }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
        let bundled = newest.map { extensions.appendingPathComponent($0).appendingPathComponent("resources/native-binary/claude").path }
        return [bundled, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func start(binary: String, timeout: TimeInterval, continuation: CheckedContinuation<JSONValue?, Never>) {
        self.continuation = continuation
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        // No hooks and a non-IDE entrypoint: this probe must not show up as a Cursor session in the deck.
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--settings", #"{"disableAllHooks":true}"#]
        process.environment = ProcessInfo.processInfo.environment.merging(["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]) { $1 }
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            chunk.isEmpty ? finish(nil) : consume(chunk)
        }
        do {
            try process.run()
        } catch {
            return finish(nil)
        }
        let requests = [#"{"type":"control_request","request_id":"init","request":{"subtype":"initialize"}}"#,
                        #"{"type":"control_request","request_id":"usage","request":{"subtype":"get_usage","skip_behaviors":true}}"#]
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in finish(nil) }
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var found: JSONValue?
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = try? JSONDecoder().decode(JSONValue.self, from: line),
               message["type"]?.string == "control_response",
               message["response"]?["request_id"]?.string == "usage" {
                found = message["response"]?["response"]
            }
        }
        lock.unlock()
        if let found { finish(found) }
    }

    private func finish(_ value: JSONValue?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        pending.resume(returning: value)
    }
}
