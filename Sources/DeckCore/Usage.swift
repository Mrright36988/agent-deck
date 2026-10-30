import Foundation

/// One usage limit with how much of it is used and when it resets.
public struct UsageWindow: Sendable, Equatable, Identifiable {
    public enum Level: Sendable { case normal, warning, critical }

    public let id: String
    public let tool: Tool
    public let label: String
    public let percent: Double
    public let resetsAt: Date?
    /// Money or credits behind the percentage, e.g. "$1,288.69 / $2,500.00".
    public let detail: String?
    /// When the limit runs out at the recent pace, if that comes before the reset. Filled in by the monitor.
    public var depletesAt: Date?

    public init(id: String, tool: Tool, label: String, percent: Double, resetsAt: Date?, detail: String?, depletesAt: Date? = nil) {
        self.id = id
        self.tool = tool
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.detail = detail
        self.depletesAt = depletesAt
    }

    /// Thresholds as in the common menu bar meters: orange from 70 %, red from 90 %.
    public var level: Level { percent >= 90 ? .critical : percent >= 70 ? .warning : .normal }
}

public enum ClaudeUsage {
    private static let windows = [("five_hour", "5 小时"), ("seven_day", "每周"),
                                  ("seven_day_opus", "每周 · Opus"), ("seven_day_sonnet", "每周 · Sonnet")]

    /// Parses the `get_usage` control response of Claude Code (the data its own usage panel shows).
    /// Plans differ: subscriptions fill the 5-hour and weekly windows, enterprise seats a monthly spend.
    public static func parse(_ response: JSONValue) -> [UsageWindow] {
        guard let limits = response["rate_limits"] else { return [] }
        var result = windows.compactMap { key, label -> UsageWindow? in
            guard let window = limits[key], let percent = number(window["utilization"]) else { return nil }
            return UsageWindow(id: "claude.\(key)", tool: .claude, label: label, percent: percent,
                               resetsAt: date(window["resets_at"]), detail: nil)
        }
        if let spend = limits["spend"], spend["enabled"]?.bool != false, let percent = number(spend["percent"]) {
            let used = money(spend["used"]), limit = money(spend["limit"])
            result.append(UsageWindow(id: "claude.spend", tool: .claude, label: "额外用量 · 本月", percent: percent,
                                      resetsAt: date(spend["resets_at"]),
                                      detail: used.flatMap { u in limit.map { "\(u) / \($0)" } }))
        } else if let extra = limits["extra_usage"], extra["is_enabled"]?.bool == true, let percent = number(extra["utilization"]) {
            result.append(UsageWindow(id: "claude.spend", tool: .claude, label: "额外用量 · 本月", percent: percent,
                                      resetsAt: nil, detail: nil))
        }
        return result
    }

    private static func money(_ value: JSONValue?) -> String? {
        guard let minor = number(value?["amount_minor"]) else { return nil }
        let exponent = Int(number(value?["exponent"]) ?? 2)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = value?["currency"]?.string ?? "USD"
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: minor / pow(10, Double(exponent))))
    }
}

public enum CodexUsage {
    /// Parses `rate_limits` from a Codex rollout `token_count` event.
    public static func parse(_ limits: JSONValue, now: Date = Date()) -> [UsageWindow] {
        ["primary", "secondary"].compactMap { key -> UsageWindow? in
            guard let window = limits[key], let percent = number(window["used_percent"]) else { return nil }
            let minutes = Int(number(window["window_minutes"]) ?? 0)
            let resets = date(window["resets_at"])
            // A window that has reset since the event was written starts over at zero.
            let current = (resets.map { $0 <= now } ?? false) ? 0 : percent
            return UsageWindow(id: "codex.\(key)", tool: .codex, label: label(minutes: minutes), percent: current,
                               resetsAt: resets, detail: nil)
        }
    }

    static func label(minutes: Int) -> String {
        switch minutes {
        case 300: return "5 小时"
        case 1440: return "每天"
        case 10080: return "每周"
        case 0: return "额度"
        default: return minutes % 1440 == 0 ? "\(minutes / 1440) 天" : "\(minutes / 60) 小时"
        }
    }
}

public enum UsageForecast {
    /// When the window reaches 100 % at the pace of the last three hours of samples (oldest first),
    /// or nil when there is not enough movement or the window resets first.
    public static func depletion(samples: [(at: Date, percent: Double)], resetsAt: Date?, now: Date = Date()) -> Date? {
        let recent = samples.filter { now.timeIntervalSince($0.at) <= 3 * 3600 }
        guard let first = recent.first, let last = recent.last, last.percent < 100,
              last.at.timeIntervalSince(first.at) >= 20 * 60, last.percent > first.percent else { return nil }
        let perSecond = (last.percent - first.percent) / last.at.timeIntervalSince(first.at)
        let eta = last.at.addingTimeInterval((100 - last.percent) / perSecond)
        if let resetsAt, eta >= resetsAt { return nil }
        return eta
    }
}

private func number(_ value: JSONValue?) -> Double? {
    if case .number(let n)? = value { return n }
    return nil
}

/// Epoch seconds or ISO 8601, whichever the source uses.
private func date(_ value: JSONValue?) -> Date? {
    switch value {
    case .number(let seconds)?: return Date(timeIntervalSince1970: seconds)
    case .string(let text)?:
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    default: return nil
    }
}
