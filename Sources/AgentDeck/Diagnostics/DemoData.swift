import DeckCore
import Foundation

/// Made-up sessions for `agentdeck://diag/demo`, to render the UI in states the live inbox is not in.
/// The store it returns is never started: it talks to no hook and sends no notification.
@MainActor
enum DemoData {
    static func store(windowCount: Int) -> DeckStore {
        let now = Date()
        let folders = [["/demo/workspace"], ["/demo/meeting-copilot", "/demo/meeting-copilot-native", "/demo/meeting-copilot-evidence"],
                       ["/demo/audio-agent"], ["/demo/trading-lab"], ["/demo/devkits"], ["/demo/dev-portal"],
                       ["/demo/school-agent"], ["/demo/map-viewer"]]
        let windows = folders.prefix(windowCount).map { IDEWindow(pid: 1, workspaceFolders: $0, ideName: "Cursor") }
        var inbox = Inbox()
        func add(_ id: String, _ tool: Tool, _ cwd: String, _ title: String, busy: Bool, minutesAgo: Double) {
            inbox.discovered(id: id, tool: tool, cwd: cwd, title: title, busy: busy, activeAt: now.addingTimeInterval(-minutesAgo * 60), at: now)
        }
        func event(_ id: String, _ name: String, _ fields: [String: JSONValue] = [:]) {
            var payload: [String: JSONValue] = ["session_id": .string(id)]
            payload.merge(fields) { $1 }
            inbox.apply(HookEnvelope(tool: .claude, event: name, wait: name == "PermissionRequest", payload: .object(payload)), at: now)
        }
        add("d1", .claude, "/demo/workspace", "修复会议录制回归", busy: true, minutesAgo: 0)
        event("d1", "PermissionRequest", ["tool_name": .string("Bash"),
                                          "tool_input": .object(["command": .string("pnpm test --filter recorder")])])
        add("d2", .claude, "/demo/meeting-copilot-native", "周报数据口径", busy: true, minutesAgo: 1)
        event("d2", "PermissionRequest", ["tool_name": .string("AskUserQuestion"), "tool_input": .object(["questions": .array([.object([
            "question": .string("活跃用户按哪个口径统计？"), "header": .string("口径"), "multiSelect": .bool(false),
            "options": .array([.object(["label": .string("自然周"), "description": .string("周一到周日")]),
                               .object(["label": .string("滚动 7 天")])]),
        ])])])])
        add("d3", .claude, "/demo/meeting-copilot", "Teams 入会兼容性复核", busy: false, minutesAgo: 3)
        event("d3", "Stop", ["last_assistant_message": .string("复核完成：新版客户端入会正常，旧版要手动允许麦克风。")])
        add("d4", .codex, "/demo/audio-agent", "流式转写延迟优化", busy: true, minutesAgo: 4)
        add("d5", .claude, "/demo/trading-lab", "回测报告整理", busy: true, minutesAgo: 1)
        add("d6", .claude, "/demo/workspace", "Linear 项目跟踪整理", busy: false, minutesAgo: 120)
        add("d7", .claude, "/demo/meeting-copilot", "SDK 版本确认", busy: false, minutesAgo: 1500)
        add("d8", .claude, "/demo/meeting-copilot-native", "插件安装检查", busy: false, minutesAgo: 1600)
        if windowCount > 4 {
            add("d9", .claude, "/demo/devkits", "CLI 发布说明", busy: false, minutesAgo: 30)
            event("d9", "Stop")
            add("d10", .codex, "/demo/dev-portal", "接口文档校对", busy: true, minutesAgo: 2)
            add("d11", .claude, "/demo/school-agent", "排课规则梳理", busy: false, minutesAgo: 600)
        }
        let usage = [
            UsageWindow(id: "claude.spend", tool: .claude, label: "额外用量 · 本月", percent: 57, resetsAt: nil, detail: "$1,200 / $2,500"),
            UsageWindow(id: "codex.week", tool: .codex, label: "每周", percent: 12, resetsAt: now.addingTimeInterval(6 * 86400), detail: nil),
        ]
        return DeckStore(preview: inbox, windows: windows, usage: usage)
    }
}
