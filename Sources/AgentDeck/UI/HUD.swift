import DeckCore
import SwiftUI

/// The dark HUD look of the deck: one palette for the map and the lists around it. Each session state has
/// its own colour and its own beacon height, so the two never depend on colour alone.
enum HUD {
    static let wait = Color(hex: 0xF5B83D)
    static let run = Color(hex: 0x5AA9FF)
    static let done = Color(hex: 0x4FD1A5)
    static let idle = Color(hex: 0x5D6576)
    static let ground = Color(hex: 0x0A0E15)
    static let board = Color(hex: 0x060A10)
    static let surface = Color.white.opacity(0.04)
    static let line = Color(hex: 0x6EA0FF).opacity(0.16)
    static let text = Color(hex: 0xEEF3FA)
    static let text2 = Color(hex: 0xA9B6C9)
    static let text3 = Color(hex: 0x8291A7)
    static let claude = Color(hex: 0xE8916F)
    static let codex = Color(hex: 0x8FB3FF)

    static func color(_ state: SessionState) -> Color {
        switch state {
        case .waiting: return wait
        case .running: return run
        case .doneUnread: return done
        case .idle: return idle
        }
    }

    /// How tall a session's beacon stands, on the map and as the small glyph in lists.
    static func height(_ state: SessionState) -> Double {
        switch state {
        case .waiting: return 46
        case .running: return 30
        case .doneUnread: return 18
        case .idle: return 0
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A session's beacon in miniature: a glowing head on a bar as tall as the state is urgent.
struct Beacon: View {
    let state: SessionState

    var body: some View {
        let color = HUD.color(state)
        VStack(spacing: 0) {
            Circle().fill(color).frame(width: 6, height: 6)
                .shadow(color: state == .idle ? .clear : color.opacity(0.8), radius: 3)
            Rectangle().fill(color.opacity(0.5)).frame(width: 2, height: HUD.height(state) / 3.2)
        }
        .frame(width: 10, height: 20, alignment: .bottom)
    }
}

/// Compact HUD buttons: `accent` for the main action (filled), `plain` for the rest.
struct HUDButtonStyle: ButtonStyle {
    var accent: Color?

    func makeBody(configuration: Configuration) -> some View {
        HUDButtonBody(label: configuration.label, accent: accent, pressed: configuration.isPressed)
    }
}

private struct HUDButtonBody<Label: View>: View {
    let label: Label
    let accent: Color?
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        label
            .font(.system(size: 12, weight: accent == nil ? .medium : .semibold))
            .padding(.horizontal, 11)
            .frame(minHeight: 26)
            .foregroundStyle(accent == nil ? HUD.text : Color(hex: 0x0B0F16))
            .background(RoundedRectangle(cornerRadius: 7).fill(accent ?? Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(accent == nil ? Color.white.opacity(0.12) : .clear))
            .shadow(color: (accent ?? .clear).opacity(0.45), radius: 6, y: 2)
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(enabled ? (pressed ? 0.85 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

extension SessionState {
    var label: String {
        switch self {
        case .waiting: return "等我处理"
        case .doneUnread: return "新完成"
        case .running: return "在跑"
        case .idle: return "已读"
        }
    }
}
