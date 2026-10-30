import Foundation
import Testing
@testable import DeckCore

@Test func ideLockMatchesFoldersOfMultiRootWindow() throws {
    let json = #"{"pid": 42, "workspaceFolders": ["/w/devkits", "/w/agent-cli"], "ideName": "Cursor", "transport": "ws", "authToken": "secret"}"#
    let window = try #require(IDELocks.parse(Data(json.utf8)))
    #expect(window.ideName == "Cursor")
    #expect(window.contains(path: "/w/agent-cli"))
    #expect(window.contains(path: "/w/agent-cli/src/main.go"))
    #expect(!window.contains(path: "/w/agent-cli-old"))
    #expect(!window.contains(path: "/w"))
}

@Test func registryEntryFromCursorPluginIsRecognised() throws {
    let json = #"{"pid": 84297, "sessionId": "f33e823b", "cwd": "/w/probe-ws", "kind": "interactive", "entrypoint": "claude-vscode", "name": "probe-ws-c3", "status": "idle", "messagingSocketPath": "/tmp/x.sock"}"#
    let session = try #require(ClaudeRegistry.parse(Data(json.utf8)))
    #expect(session.isFromIDE)
    #expect(session.name == "probe-ws-c3")
    #expect(ClaudeRegistry.parse(Data(#"{"pid": 1}"#.utf8)) == nil)
}

@Test func codexRolloutMetaIsParsedFromFirstLine() throws {
    let line = #"{"timestamp":"2026-10-29T09:33:26Z","type":"session_meta","payload":{"id":"01a18701","cwd":"/w/probe-ws","originator":"codex_vscode","cli_version":"0.164.0"}}"#
    let thread = try #require(CodexRollouts.parseMeta(firstLine: Data(line.utf8), file: URL(fileURLWithPath: "/tmp/r.jsonl")))
    #expect(thread.id == "01a18701")
    #expect(thread.isFromIDE)
}

@Test func firstLineStopsAtNewline() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("deckcore-\(UUID().uuidString).jsonl")
    try Data("first\nsecond\n".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(CodexRollouts.firstLine(of: url) == Data("first".utf8))
}
