import Foundation
import Testing
@testable import DeckCore

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Test func enterpriseAccountShowsMonthlySpend() throws {
    // Shape returned by Claude Code's get_usage on 2026-10-29 for an enterprise seat.
    let response = try json("""
    {"rate_limits": {"five_hour": null, "seven_day": null, "seven_day_opus": null, "limits": [],
      "extra_usage": {"is_enabled": true, "monthly_limit": 250000, "used_credits": 128869, "utilization": 51.5476},
      "spend": {"used": {"amount_minor": 128869, "currency": "USD", "exponent": 2},
                "limit": {"amount_minor": 250000, "currency": "USD", "exponent": 2},
                "percent": 52, "severity": "normal", "enabled": true}},
     "subscription_type": "enterprise"}
    """)
    let windows = ClaudeUsage.parse(response)
    #expect(windows.map(\.id) == ["claude.spend"])
    #expect(windows.first?.percent == 52)
    #expect(windows.first?.detail == "$1,288.69 / $2,500.00")
    #expect(windows.first?.level == .normal)
}

@Test func subscriptionWindowsComeFirstWithResets() throws {
    let response = try json("""
    {"rate_limits": {"five_hour": {"utilization": 91.5, "resets_at": "2026-10-29T15:00:00Z"},
                     "seven_day": {"utilization": 40, "resets_at": 1793848488}, "spend": null}}
    """)
    let windows = ClaudeUsage.parse(response)
    #expect(windows.map(\.label) == ["5 小时", "每周"])
    #expect(windows[0].level == .critical)
    #expect(windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-10-29T15:00:00Z"))
    #expect(windows[1].resetsAt == Date(timeIntervalSince1970: 1793848488))
}

@Test func codexWeeklyWindowFromRollout() throws {
    let limits = try json(#"{"limit_id":"codex","primary":{"used_percent":12.0,"window_minutes":10080,"resets_at":1793848488},"secondary":null,"credits":{"has_credits":false}}"#)
    let windows = CodexUsage.parse(limits, now: Date(timeIntervalSince1970: 1793300000))
    #expect(windows.count == 1)
    #expect(windows[0].label == "每周")
    #expect(windows[0].percent == 12)
}

@Test func codexWindowThatAlreadyResetStartsAtZero() throws {
    let limits = try json(#"{"primary":{"used_percent":88.0,"window_minutes":300,"resets_at":1000}}"#)
    let windows = CodexUsage.parse(limits, now: Date(timeIntervalSince1970: 2000))
    #expect(windows[0].label == "5 小时")
    #expect(windows[0].percent == 0)
}

@Test func forecastExtrapolatesTheRecentPace() {
    let now = Date(timeIntervalSince1970: 100_000)
    let samples = [(at: now.addingTimeInterval(-3600), percent: 40.0), (at: now, percent: 50.0)]
    let eta = UsageForecast.depletion(samples: samples, resetsAt: now.addingTimeInterval(10 * 3600), now: now)
    #expect(eta == now.addingTimeInterval(5 * 3600))  // 10 % per hour, 50 % to go
}

@Test func forecastStaysQuietWhenTheResetComesFirstOrNothingMoves() {
    let now = Date(timeIntervalSince1970: 100_000)
    let rising = [(at: now.addingTimeInterval(-3600), percent: 40.0), (at: now, percent: 50.0)]
    #expect(UsageForecast.depletion(samples: rising, resetsAt: now.addingTimeInterval(2 * 3600), now: now) == nil)
    let flat = [(at: now.addingTimeInterval(-3600), percent: 50.0), (at: now, percent: 50.0)]
    #expect(UsageForecast.depletion(samples: flat, resetsAt: nil, now: now) == nil)
    let tooShort = [(at: now.addingTimeInterval(-300), percent: 40.0), (at: now, percent: 50.0)]
    #expect(UsageForecast.depletion(samples: tooShort, resetsAt: nil, now: now) == nil)
}
