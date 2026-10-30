import Foundation
import Testing
@testable import DeckCore

/// End to end: the real hook/deck_hook.py talking to a real HookServer over a unix socket.
private let shim = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("hook/deck_hook.py").path

@MainActor
private final class Seen {
    var envelope: HookEnvelope?
    var hadReply = false
    var dropped = false
}

private func socketPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("deck-\(UUID().uuidString.prefix(8)).sock").path
}

private func startShim(socket: String, tool: String, event: String, input: String) throws -> (Process, FileHandle) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [shim, tool, event]
    process.environment = ProcessInfo.processInfo.environment.merging(["AGENT_DECK_SOCKET": socket]) { $1 }
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    try process.run()
    stdin.fileHandleForWriting.write(Data(input.utf8))
    try stdin.fileHandleForWriting.close()
    return (process, stdout.fileHandleForReading)
}

/// Waits for the shim off the cooperative pool, since the server's handler needs the main actor meanwhile.
private func output(of handle: FileHandle, _ process: Process) async -> Data {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let data = handle.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: data)
        }
    }
}

@Test func answerFromTheDeckReachesTheWaitingHook() async throws {
    let path = socketPath()
    let seen = Seen()
    let server = HookServer(path: path) { envelope, reply in
        seen.envelope = envelope
        seen.hadReply = reply != nil
        reply?.send(HookAnswer.allow())
    }
    try server.start()
    defer { server.stop() }

    let (process, stdout) = try startShim(socket: path, tool: "claude", event: "PermissionRequest",
                                          input: #"{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
    let printed = await output(of: stdout, process)
    #expect(process.terminationStatus == 0)
    #expect(try JSONDecoder().decode(JSONValue.self, from: printed) == HookAnswer.allow())
    let envelope = await seen.envelope
    #expect(envelope?.wait == true)
    #expect(envelope?.payload["tool_input"]?["command"]?.string == "ls")
    #expect(await seen.hadReply)
}

@Test func hookThatGivesUpIsReportedAsDropped() async throws {
    let path = socketPath()
    let seen = Seen()
    let server = HookServer(path: path) { _, reply in
        reply?.onDrop { seen.dropped = true }
    }
    try server.start()
    defer { server.stop() }

    let (process, _) = try startShim(socket: path, tool: "claude", event: "PermissionRequest", input: #"{"session_id":"s1"}"#)
    try await Task.sleep(for: .milliseconds(600))
    process.terminate()
    for _ in 0..<40 where !(await seen.dropped) {
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(await seen.dropped)
}

@Test func otherEventsAreDeliveredWithoutAReply() async throws {
    let path = socketPath()
    let seen = Seen()
    let server = HookServer(path: path) { envelope, reply in
        seen.envelope = envelope
        seen.hadReply = reply != nil
    }
    try server.start()
    defer { server.stop() }

    let (process, stdout) = try startShim(socket: path, tool: "codex", event: "Stop",
                                          input: #"{"session_id":"t1","last_assistant_message":"完成"}"#)
    let printed = await output(of: stdout, process)
    #expect(printed.isEmpty)
    for _ in 0..<20 where await seen.envelope == nil {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await seen.envelope?.payload["last_assistant_message"]?.string == "完成")
    #expect(await !seen.hadReply)
}
