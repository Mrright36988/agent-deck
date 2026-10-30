import Foundation
import Testing
@testable import DeckCore

@Test func allowAndDenyMatchTheVerifiedHookShape() throws {
    let allow = try #require(String(data: HookAnswer.allow().encoded(), encoding: .utf8))
    #expect(allow == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
    #expect(HookAnswer.deny("no")["hookSpecificOutput"]?["decision"]?["message"]?.string == "no")
}

@Test func questionAnswerEchoesQuestionsAndAddsAnswers() {
    let questions: JSONValue = .array([.object(["question": .string("选 A 还是 B？")])])
    let output = HookAnswer.answer(.object(["questions": questions]), picks: ["选 A 还是 B？": ["A", "B"]])
    let updated = output["hookSpecificOutput"]?["decision"]?["updatedInput"]
    #expect(updated?["questions"] == questions)
    #expect(updated?["answers"]?["选 A 还是 B？"]?.string == "A, B")
}
