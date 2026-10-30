import Foundation
import Testing
@testable import DeckCore

private let t0 = Date(timeIntervalSince1970: 1_000)

private let windows = [
    IDEWindow(pid: 1, workspaceFolders: ["/w/workspace"], ideName: "Cursor"),
    IDEWindow(pid: 1, workspaceFolders: ["/w/workspace/agent-deck/spike/probe-ws"], ideName: "Cursor"),
    IDEWindow(pid: 1, workspaceFolders: ["/w/meeting-copilot", "/w/meeting-copilot-native", "/w/meeting-copilot-evidence"], ideName: "Cursor"),
    IDEWindow(pid: 1, workspaceFolders: ["/w/audio-agent"], ideName: "Cursor"),
]

/// Sessions: "wait" in meeting-copilot-native (an approval pending), "run" in audio-agent, "done" and "idle" in workspace,
/// "probe" in the nested probe-ws window, "stray" outside every window.
private func sampleInbox() -> Inbox {
    var inbox = Inbox()
    inbox.discovered(id: "wait", tool: .claude, cwd: "/w/meeting-copilot-native/src", title: "修复回归", busy: true, at: t0)
    inbox.apply(HookEnvelope(tool: .claude, event: "PermissionRequest", wait: true, payload: .object([
        "session_id": .string("wait"), "tool_name": .string("Bash"), "tool_input": .object(["command": .string("ls")]),
    ])), at: t0)
    inbox.discovered(id: "run", tool: .codex, cwd: "/w/audio-agent", title: nil, busy: true, at: t0)
    inbox.discovered(id: "done", tool: .claude, cwd: "/w/workspace", title: nil, busy: false, at: t0)
    inbox.apply(HookEnvelope(tool: .claude, event: "Stop", wait: false, payload: .object(["session_id": .string("done")])), at: t0)
    inbox.discovered(id: "idle", tool: .claude, cwd: "/w/workspace/docs", title: nil, busy: false,
                     activeAt: t0.addingTimeInterval(-60), at: t0)
    inbox.discovered(id: "probe", tool: .claude, cwd: "/w/workspace/agent-deck/spike/probe-ws", title: nil, busy: false,
                     activeAt: t0.addingTimeInterval(-120), at: t0)
    inbox.discovered(id: "stray", tool: .claude, cwd: "/tmp/elsewhere", title: nil, busy: false,
                     activeAt: t0.addingTimeInterval(-30), at: t0)
    return inbox
}

private func island(_ name: String, in islands: [Island]) -> Island? {
    islands.first { $0.name == name }
}

@Test func sessionsGoToTheDeepestWindowThatHoldsThem() throws {
    let map = WindowMap.build(windows: windows, inbox: sampleInbox())
    let copilot = try #require(island("meeting-copilot +2", in: map.islands))
    #expect(copilot.members.map(\.sessionId) == ["wait"])
    #expect(copilot.count(.waiting) == 1)
    #expect(island("workspace", in: map.islands)?.members.map(\.sessionId) == ["done", "idle"])
    #expect(island("probe-ws", in: map.islands)?.members.map(\.sessionId) == ["probe"])
    let other = try #require(island("其他", in: map.islands))
    #expect(other.isOther && other.members.map(\.sessionId) == ["stray"])
}

@Test func busiestWindowsComeFirstAndTheRestAreQuiet() {
    let map = WindowMap.build(windows: windows, inbox: sampleInbox(), maxIslands: 3)
    // waiting, then new, then running; probe-ws and the stray session are idle.
    #expect(map.islands.map(\.name) == ["meeting-copilot +2", "workspace", "audio-agent"])
    #expect(map.quiet.map(\.name) == ["其他", "probe-ws"])  // most recent activity first
}

@Test func windowsWithoutSessionsStillGetAnIsland() {
    let map = WindowMap.build(windows: windows, inbox: Inbox())
    #expect(map.islands.count == 4)
    #expect(map.islands.allSatisfy { $0.members.isEmpty })
    let hasOther = map.islands.contains { $0.isOther }
    #expect(!hasOther)
}

@Test func duplicateLockFilesForOneWindowMakeOneIsland() {
    let map = WindowMap.build(windows: windows + [windows[0]], inbox: Inbox())
    #expect(map.islands.count == 4)
}

@Test func gridGrowsWithTheNumberOfIslands() {
    #expect(IsoLayout.grid(for: 1) == (1, 1))
    #expect(IsoLayout.grid(for: 2) == (2, 1))
    #expect(IsoLayout.grid(for: 3) == (2, 2))
    #expect(IsoLayout.grid(for: 6) == (3, 2))
}

@Test func frontCellIsDrawnLowestAndLast() throws {
    let layout = IsoLayout(ids: ["a", "b", "c", "d"], size: CGSize(width: 396, height: 250))
    // Reading order a b / c d: the bottom-left cell (c) faces the viewer, the top-right (b) is furthest back.
    #expect(layout.backToFront.map(\.id).first == "b")
    #expect(layout.backToFront.map(\.id).last == "c")
    let front = try #require(layout.tiles.first { $0.id == "c" })
    let back = try #require(layout.tiles.first { $0.id == "b" })
    #expect(layout.point(on: front, 0.5, 0.5).y > layout.point(on: back, 0.5, 0.5).y)
}

@Test func beaconsRiseUpTheScreen() {
    let projection = IsoProjection(origin: .zero)
    #expect(projection.project(0, 0, 40).y < projection.project(0, 0, 0).y)
    #expect(projection.project(0, 0, 40).x == projection.project(0, 0, 0).x)
}

@Test func hitTestFindsTheTileUnderThePointer() throws {
    let layout = IsoLayout(ids: ["a", "b", "c", "d"], size: CGSize(width: 396, height: 250))
    for tile in layout.tiles {
        #expect(layout.tile(at: layout.point(on: tile, 0.5, 0.5)) == tile.id)
    }
    #expect(layout.tile(at: CGPoint(x: 2, y: 2)) == nil)
    // A lifted tile is hit where it is drawn, not where it sat.
    let front = try #require(layout.tiles.first { $0.id == "c" })
    let lifted = layout.point(on: front, 0.5, 0.05, z: 40)
    #expect(layout.tile(at: lifted, lift: { $0 == "c" ? 40 : 0 }) == "c")
}

@Test func boardFitsItsSpaceForOneToSixIslands() {
    let size = CGSize(width: 396, height: 250)
    for count in 1...6 {
        let layout = IsoLayout(ids: (0..<count).map { "w\($0)" }, size: size)
        let points = layout.tiles.flatMap { layout.outline(of: $0, z: -layout.thickness) + layout.outline(of: $0) }
        #expect(points.allSatisfy { $0.x >= -0.5 && $0.x <= size.width + 0.5 && $0.y >= 0 && $0.y <= size.height + 0.5 })
        #expect(layout.tileSize >= 60)
    }
}
