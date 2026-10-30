import Foundation
import Testing
@testable import DeckCore

@Test func bashShowsTheWholeCommand() {
    let detail = ApprovalDetail(toolName: "Bash", input: .object(["command": .string("git push origin main"), "description": .string("推送")]))
    #expect(detail.headline == "推送")
    #expect(detail.body == "git push origin main")
    #expect(detail.fitsInNotification)
}

@Test func longOrMultilineCommandsAreReviewedInThePanel() {
    let long = String(repeating: "x", count: 301)
    #expect(!ApprovalDetail(toolName: "Bash", input: .object(["command": .string(long)])).fitsInNotification)
    let script = "a\nb\nc\nd\ne"
    #expect(!ApprovalDetail(toolName: "Bash", input: .object(["command": .string(script)])).fitsInNotification)
}

@Test func editIsRenderedAsADiffAndNeverFitsANotification() {
    let detail = ApprovalDetail(toolName: "Edit", input: .object([
        "file_path": .string("/w/a.swift"), "old_string": .string("let a = 1"), "new_string": .string("let a = 2\nlet b = 3"),
    ]))
    #expect(detail.headline == "修改 /w/a.swift")
    #expect(detail.body == "- let a = 1\n+ let a = 2\n+ let b = 3")
    #expect(!detail.fitsInNotification)
}

@Test func codexCommandArraysAreJoined() {
    let detail = ApprovalDetail(toolName: "exec_command", input: .object(["command": .array([.string("curl"), .string("-sI"), .string("https://example.com")])]))
    #expect(detail.body == "curl -sI https://example.com")
    #expect(detail.style == .command)
}

@Test func unknownToolsFallBackToPrettyJSON() {
    let detail = ApprovalDetail(toolName: "mcp__linear__save_issue", input: .object(["title": .string("修复")]))
    #expect(detail.body.contains("\"title\" : \"修复\""))
    #expect(!detail.fitsInNotification)
}
