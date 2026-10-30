import DeckCore
import SwiftUI

struct InboxView: View {
    /// The menu bar window grows with its content but does not shrink back: after a long list, a short one
    /// sat in the middle of a window too tall for it. So that window keeps one height and the session list
    /// takes whatever the map, banner and usage details leave.
    static let menuHeight: CGFloat = 740

    @ObservedObject var store: DeckStore
    var inPanel = false
    @State private var selection: String?
    @State private var showUsage = false

    var body: some View {
        let inbox = store.inbox
        let map = WindowMap.build(windows: store.windows, inbox: inbox)
        let everything = map.islands + map.quiet
        // Default and fallback: the busiest island.
        let selected = everything.first { $0.id == selection } ?? map.islands.first
        let waiting = inbox.ordered.filter { inbox.state(of: $0) == .waiting }
        VStack(spacing: 0) {
            HUDHeader(inbox: inbox, usage: store.usage, hasUsageNote: store.usageNote != nil, showUsage: $showUsage)
            if showUsage {
                UsageSection(windows: store.usage, note: store.usageNote)
            }
            if let notice = store.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(HUD.wait)
                    Text(notice).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { store.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(HUD.text3)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(HUD.wait.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(HUD.wait.opacity(0.3))))
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if everything.isEmpty {
                Text("还没有会话。装好 hooks 后，Cursor 里的 Claude 和 Codex 会话会出现在这里。")
                    .font(.callout).foregroundStyle(HUD.text2).padding(16)
                Spacer(minLength: 0)
            } else {
                MapView(islands: map.islands, selection: selected?.id) { select($0) }
                    .frame(height: 250)
                    .background(RoundedRectangle(cornerRadius: 14).fill(HUD.board))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(HUD.line))
                    .padding(.horizontal, 12)
                if !map.quiet.isEmpty {
                    QuietStrip(quiet: map.quiet, selection: selected?.id) { select($0) }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !waiting.isEmpty {
                            SectionTitle(title: "等你处理", count: waiting.count, color: HUD.wait)
                            ForEach(waiting) { session in
                                SessionRow(store: store, session: session, state: .waiting, cards: inbox.cards(for: session.id))
                            }
                        }
                        if let selected {
                            IslandHeader(island: selected) { store.jumpToWindow(selected) }
                            let rest = selected.members.filter { $0.state != .waiting }.compactMap { inbox.sessions[$0.sessionId] }
                            if rest.isEmpty {
                                Text(selected.members.isEmpty ? "这个窗口里还没有会话" : "这个窗口的会话都在上面等你处理")
                                    .font(.system(size: 11.5)).foregroundStyle(HUD.text3)
                                    .padding(.horizontal, 16).padding(.top, 10)
                            }
                            ForEach([SessionState.doneUnread, .running, .idle], id: \.self) { state in
                                let group = rest.filter { inbox.state(of: $0) == state }
                                if !group.isEmpty {
                                    SectionTitle(title: state.label, count: group.count, color: HUD.color(state))
                                    ForEach(group) { session in
                                        SessionRow(store: store, session: session, state: state, cards: inbox.cards(for: session.id))
                                            .opacity(state == .idle ? 0.72 : 1)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: .infinity)
            }
            Legend()
            HStack(spacing: 14) {
                if !inPanel {
                    Button("钉成悬浮面板") { PanelController.shared.toggle() }
                }
                Menu {
                    Button("发测试通知") { Notifier.shared.sendTest() }
                    Button("打开日志") { NSWorkspace.shared.open(Log.fileURL) }
                } label: {
                    Text("诊断")
                }
                .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(HUD.text2)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .overlay(alignment: .top) { Rectangle().fill(HUD.line).frame(height: 1) }
        }
        .frame(minWidth: 380, idealWidth: 420, maxWidth: inPanel ? .infinity : 420,
               minHeight: inPanel ? nil : Self.menuHeight, maxHeight: inPanel ? .infinity : Self.menuHeight)
        .foregroundStyle(HUD.text)
        .background(HUD.ground)
        .environment(\.colorScheme, .dark)
    }

    /// Picking an island moves on from whatever the last jump reported, so its banner goes.
    private func select(_ id: String) {
        selection = id
        store.notice = nil
    }
}

private struct SectionTitle: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title) · \(count)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(HUD.text2)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }
}

/// The selected island: which window it is, and a way to bring that window to the front.
private struct IslandHeader: View {
    let island: Island
    let jump: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: island.isOther ? "questionmark.square.dashed" : "macwindow").foregroundStyle(HUD.text2)
            VStack(alignment: .leading, spacing: 2) {
                Text(island.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(kind).font(.system(size: 11)).foregroundStyle(HUD.text2).lineLimit(1)
            }
            Spacer(minLength: 6)
            if !island.isOther {
                Button(action: jump) { Label("跳到这个窗口", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(HUDButtonStyle(accent: HUD.run))
                    .help("把这个 Cursor 窗口切到前台")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(HUD.surface).overlay(RoundedRectangle(cornerRadius: 12).stroke(HUD.line)))
        .padding(.horizontal, 12).padding(.top, 14)
    }

    private var kind: String {
        let count = "\(island.members.count) 个会话"
        if island.isOther { return "不在打开的 Cursor 窗口里 · \(count)" }
        return island.folders.count > 1 ? "多根 workspace · \(count)" : "单目录窗口 · \(count)"
    }
}

/// Windows that did not make it onto the map; picking one shows its sessions below.
private struct QuietStrip: View {
    let quiet: [Island]
    let selection: String?
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("还有 \(quiet.count) 个窗口").font(.system(size: 11)).foregroundStyle(HUD.text3)
                ForEach(quiet) { island in
                    let busiest = [SessionState.waiting, .doneUnread, .running].first { island.count($0) > 0 } ?? .idle
                    Button { onSelect(island.id) } label: {
                        HStack(spacing: 5) {
                            Circle().fill(HUD.color(busiest)).frame(width: 5, height: 5)
                            Text(island.name).lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().fill(Color.white.opacity(island.id == selection ? 0.14 : 0.06)))
                        .overlay(Capsule().stroke(island.id == selection ? HUD.run.opacity(0.7) : HUD.line))
                    }
                    .buttonStyle(.plain)
                    .help(MapView.summary(island))
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach([SessionState.waiting, .running, .doneUnread, .idle], id: \.self) { state in
                HStack(spacing: 4) {
                    Beacon(state: state).scaleEffect(0.8)
                    Text(state == .waiting ? "等你" : state.label)
                }
            }
            Spacer()
            Text("点岛屿切换窗口")
        }
        .font(.system(size: 10.5)).foregroundStyle(HUD.text3)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}
