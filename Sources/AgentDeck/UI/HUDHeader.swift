import DeckCore
import SwiftUI

/// Usage limits with reset countdowns, coloured like the common menu bar meters (orange 70 %, red 90 %).
struct UsageSection: View {
    let windows: [UsageWindow]
    let note: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(windows) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(window.tool == .claude ? "Claude" : "Codex") · \(window.label)").font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(Int(window.percent.rounded()))%")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(color(window.level))
                        }
                        ProgressView(value: min(max(window.percent, 0), 100), total: 100).tint(color(window.level))
                        HStack {
                            if let detail = window.detail { Text(detail) }
                            Spacer()
                            Text(resetText(window, now: context.date))
                        }
                        .font(.caption2).foregroundStyle(HUD.text2)
                        if let eta = window.depletesAt {
                            Text("按最近的速度，预计 \(eta.formatted(.dateTime.weekday(.abbreviated).hour().minute())) 用完")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                if let note {
                    Text(note).font(.caption2).foregroundStyle(HUD.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(HUD.surface).overlay(RoundedRectangle(cornerRadius: 12).stroke(HUD.line)))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func color(_ level: UsageWindow.Level) -> Color {
        switch level {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func resetText(_ window: UsageWindow, now: Date) -> String {
        guard let resets = window.resetsAt else { return window.id == "claude.spend" ? "按月计" : "" }
        let seconds = Int(resets.timeIntervalSince(now))
        guard seconds > 0 else { return "已重置，等待新数据" }
        let (days, hours, minutes) = (seconds / 86400, seconds % 86400 / 3600, seconds % 3600 / 60)
        let left = days > 0 ? "\(days) 天 \(hours) 小时" : hours > 0 ? "\(hours) 小时 \(minutes) 分" : "\(minutes) 分钟"
        return "\(left)后重置 · \(resets.formatted(.dateTime.month(.defaultDigits).day().hour().minute()))"
    }
}

/// One usage limit as a ring: the tool's colour while normal, orange from 70 %, red from 90 %.
private struct UsageRing: View {
    let window: UsageWindow

    var body: some View {
        let color: Color = switch window.level {
        case .normal: window.tool == .claude ? HUD.claude : HUD.codex
        case .warning: .orange
        case .critical: .red
        }
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.09), lineWidth: 4)
                Circle().trim(from: 0, to: min(max(window.percent, 0), 100) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.6), radius: 3)
                Text("\(Int(window.percent.rounded()))%").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            }
            .frame(width: 40, height: 40)
            Text("\(window.tool == .claude ? "Claude" : "Codex") \(window.label.components(separatedBy: "·").last?.trimmingCharacters(in: .whitespaces) ?? "")")
                .font(.system(size: 10)).foregroundStyle(HUD.text2)
        }
    }
}

/// Counts that matter at a glance, and the usage rings (click for the details).
struct HUDHeader: View {
    let inbox: Inbox
    let usage: [UsageWindow]
    let hasUsageNote: Bool
    @Binding var showUsage: Bool

    var body: some View {
        let states = inbox.sessions.values.map { inbox.state(of: $0) }
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AGENT DECK").font(.system(size: 10.5, weight: .semibold)).tracking(0.9).foregroundStyle(HUD.text3)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    stat(inbox.waitingCount, "等你", HUD.wait)
                    stat(states.filter { $0 == .running }.count, "在跑", HUD.run)
                    stat(states.filter { $0 == .doneUnread }.count, "新完成", HUD.done)
                }
            }
            Spacer(minLength: 8)
            if !usage.isEmpty || hasUsageNote {
                Button { showUsage.toggle() } label: {
                    if usage.isEmpty {
                        Text("用量").font(.system(size: 11.5)).foregroundStyle(HUD.text2)
                    } else {
                        HStack(spacing: 10) { ForEach(usage) { UsageRing(window: $0) } }
                    }
                }
                .buttonStyle(.plain)
                .help(showUsage ? "收起用量详情" : "展开用量详情")
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private func stat(_ value: Int, _ label: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(value)").font(.system(size: 24, weight: .bold).monospacedDigit()).foregroundStyle(value > 0 ? color : HUD.text3)
            Text(label).font(.system(size: 12)).foregroundStyle(HUD.text2)
        }
    }
}
