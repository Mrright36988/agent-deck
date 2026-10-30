import DeckCore
import SwiftUI

struct SessionRow: View {
    @ObservedObject var store: DeckStore
    let session: Session
    let state: SessionState
    let cards: [Card]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { store.jump(session.id) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Beacon(state: state).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(session.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            TimelineView(.periodic(from: .now, by: 30)) { _ in
                                Text(ago(cards.first?.createdAt ?? session.updatedAt)).font(.system(size: 11)).foregroundStyle(HUD.text3)
                            }
                        }
                        Text("\(session.tool == .claude ? "Claude" : "Codex") · \(session.project)")
                            .font(.system(size: 11)).foregroundStyle(HUD.text2)
                        if cards.isEmpty, state == .doneUnread, let message = session.lastMessage {
                            Text(message).font(.system(size: 11)).foregroundStyle(HUD.text2).lineLimit(3)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("跳到这个会话所在的窗口")
            ForEach(cards) { CardView(store: store, card: $0) }
            if cards.isEmpty, state == .doneUnread {
                DoneActions(store: store, session: session)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    private func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "刚刚"
        case ..<3600: return "\(seconds / 60) 分钟"
        case ..<86400: return "\(seconds / 3600) 小时"
        default: return "\(seconds / 86400) 天"
        }
    }
}

private struct CardView: View {
    @ObservedObject var store: DeckStore
    let card: Card
    @State private var picks: [String: Set<String>] = [:]
    @State private var other = ""

    var body: some View {
        let answerable = store.canAnswer(card.id)
        VStack(alignment: .leading, spacing: 7) {
            switch card.kind {
            case .approval(let tool, let input):
                let detail = ApprovalDetail(toolName: tool, input: input)
                Text(detail.headline).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                DetailBody(detail: detail)
                HStack {
                    if answerable {
                        Spacer()
                        Button("拒绝") { store.answer(card.id, with: HookAnswer.deny("在 agent-deck 里拒绝")) }
                            .buttonStyle(HUDButtonStyle())
                        Button("允许") { store.answer(card.id, with: HookAnswer.allow()) }
                            .buttonStyle(HUDButtonStyle(accent: HUD.wait))
                    } else {
                        Text("请在 Cursor 里处理").font(.caption).foregroundStyle(HUD.text2)
                        Spacer()
                    }
                }
            case .question(let questions, _):
                ForEach(questions.indices, id: \.self) { index in
                    questionBlock(questions[index], answerable: answerable, onlyQuestion: questions.count == 1)
                }
                if answerable, needsSubmit(questions) {
                    Button("提交") { submit(questions) }
                        .buttonStyle(HUDButtonStyle(accent: HUD.wait))
                        .disabled(!questions.allSatisfy { !(picks[$0.text] ?? []).isEmpty })
                }
                if !answerable {
                    Text("请在 Cursor 里回答").font(.caption).foregroundStyle(HUD.text2)
                }
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(HUD.wait.opacity(0.35))))
        .shadow(color: HUD.wait.opacity(0.18), radius: 10, y: 4)
    }

    @ViewBuilder
    private func questionBlock(_ question: Question, answerable: Bool, onlyQuestion: Bool) -> some View {
        Text(question.text).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        ForEach(question.options, id: \.label) { option in
            let chosen = picks[question.text]?.contains(option.label) ?? false
            Button {
                pick(option.label, for: question, submitNow: onlyQuestion && !question.multiSelect)
            } label: {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: question.multiSelect ? (chosen ? "checkmark.square.fill" : "square")
                                                           : (chosen ? "largecircle.fill.circle" : "circle"))
                        .foregroundStyle(chosen ? HUD.wait : HUD.text2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label).font(.system(size: 12, weight: .medium))
                        if let detail = option.detail, !detail.isEmpty {
                            Text(detail).font(.system(size: 11)).foregroundStyle(HUD.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(chosen ? 0.10 : 0.04)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!answerable)
        }
        if answerable, onlyQuestion {
            TextField("其他（直接输入答案后回车）", text: $other)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let text = other.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    store.answerQuestion(card.id, picks: [question.text: [text]])
                }
        }
    }

    private func needsSubmit(_ questions: [Question]) -> Bool {
        questions.count > 1 || questions.contains(where: \.multiSelect)
    }

    private func pick(_ label: String, for question: Question, submitNow: Bool) {
        if submitNow {
            store.answerQuestion(card.id, picks: [question.text: [label]])
            return
        }
        var chosen = picks[question.text] ?? []
        if question.multiSelect {
            if chosen.contains(label) { chosen.remove(label) } else { chosen.insert(label) }
        } else {
            chosen = [label]
        }
        picks[question.text] = chosen
    }

    private func submit(_ questions: [Question]) {
        var answers: [String: [String]] = [:]
        for question in questions {
            let chosen = picks[question.text] ?? []
            answers[question.text] = question.options.map(\.label).filter(chosen.contains)
        }
        store.answerQuestion(card.id, picks: answers)
    }
}

private struct DetailBody: View {
    let detail: ApprovalDetail

    var body: some View {
        let lines = detail.body.split(separator: "\n", omittingEmptySubsequences: false).prefix(500).map(String.init)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(8)
        }
        .frame(maxHeight: 180)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.06))))
    }

    private func color(_ line: String) -> Color {
        guard detail.style == .diff else { return HUD.text }
        if line.hasPrefix("+ ") { return HUD.done }
        if line.hasPrefix("- ") { return Color(hex: 0xFF7B72) }
        return HUD.text2
    }
}

private struct DoneActions: View {
    @ObservedObject var store: DeckStore
    let session: Session
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.tool == .codex {
                HStack {
                    TextField("回复 Codex…", text: $reply).textFieldStyle(.roundedBorder).onSubmit(send)
                    Button("发送", action: send)
                        .buttonStyle(HUDButtonStyle(accent: HUD.run))
                        .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            HStack {
                Button("跳到会话") { store.jump(session.id) }.buttonStyle(HUDButtonStyle())
                Button("标为已读") { store.markRead(session.id) }.buttonStyle(HUDButtonStyle())
                Spacer()
            }
        }
        .controlSize(.small)
        .padding(.leading, 20)
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.replyToCodex(session.id, text: text)
        reply = ""
    }
}

extension Card {
    var summary: String {
        switch kind {
        case .approval(let tool, let input):
            let detail = ApprovalDetail(toolName: tool, input: input)
            return "\(detail.headline)：\(detail.body.prefix(80))"
        case .question(let questions, _):
            return "提问：\(questions.first?.text ?? "")"
        }
    }
}
