import Foundation
import Testing
@testable import DeckCore

@Test func lastAITitleWins() {
    let transcript = """
    {"type":"user","message":{"content":"hi"}}
    {"type":"ai-title","aiTitle":"初版标题"}
    {"type":"assistant","message":{"content":[]}}
    {"type":"ai-title","aiTitle":"agent-deck spec.md 问答同步需求"}
    not json
    """
    #expect(Titles.claudeAITitle(in: Data(transcript.utf8)) == "agent-deck spec.md 问答同步需求")
    #expect(Titles.claudeAITitle(in: Data(#"{"type":"user"}"#.utf8)) == nil)
}

@Test func codexThreadNamesUseTheLatestEntry() {
    let index = """
    {"id":"t1","thread_name":"旧名字","updated_at":"2026-10-28"}
    {"id":"t2","thread_name":"agent-cli 发布","updated_at":"2026-10-29"}
    {"id":"t1","thread_name":"新名字","updated_at":"2026-10-29"}
    """
    #expect(Titles.codexThreadNames(in: Data(index.utf8)) == ["t1": "新名字", "t2": "agent-cli 发布"])
}
