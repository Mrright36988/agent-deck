import AppKit
import DeckCore
import SwiftUI

/// The open Cursor windows as islands on an isometric board. Every session that is not idle stands on its
/// island as a beacon, taller the more it needs you; idle ones are dots. The board is drawn by hand in a
/// Canvas: SwiftUI flattens nested 3D effects, so pillars standing on a tilted board have to be projected
/// (`IsoProjection`), not rotated. The board and the names only redraw when something changes; the beacons
/// are small views whose looping animations SwiftUI interpolates, so nothing is redrawn frame by frame.
struct MapView: View {
    let islands: [Island]
    let selection: String?
    let onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?

    /// Where beacons and idle dots stand on a tile, as fractions of it: beacons towards the back corner,
    /// dots towards the right one, leaving the front for the name.
    private static let beaconSlots: [(Double, Double)] = [(0.70, 0.24), (0.46, 0.16), (0.86, 0.44), (0.60, 0.40)]
    private static let dotSlots: [(Double, Double)] = [(0.86, 0.68), (0.74, 0.60), (0.94, 0.84), (0.80, 0.82), (0.64, 0.52), (0.94, 0.56)]

    var body: some View {
        GeometryReader { geometry in
            let layout = IsoLayout(ids: placed.map(\.id), size: geometry.size)
            let pairs = order(layout)
            // Board and islands, then the beacons, then the names on top so nothing covers them.
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    Self.drawGrid(&context, size)
                    for (tile, island) in pairs { drawIsland(&context, layout, tile, island, z: lift(tile.id)) }
                }
                BeaconLayer(marks: marks(layout, pairs), size: geometry.size, animated: !reduceMotion)
                    .allowsHitTesting(false)
                Canvas { context, _ in
                    for (tile, island) in pairs { drawName(&context, layout, tile, island, z: lift(tile.id)) }
                }
                if islands.isEmpty {
                    Text("没有打开的 Cursor 窗口").font(.system(size: 12)).foregroundStyle(HUD.text3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = layout.tile(at: point, lift: lift)
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let id = layout.tile(at: value.location, lift: lift) { onSelect(id) }
            })
        }
        .accessibilityRepresentation {
            VStack {
                ForEach(islands) { island in
                    Button("\(island.name)：\(Self.summary(island))") { onSelect(island.id) }
                }
            }
        }
    }

    /// Islands keep their places as their sessions change state: alphabetical, "其他" last.
    private var placed: [Island] {
        islands.sorted { a, b in
            a.isOther != b.isOther ? b.isOther : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func lift(_ id: String) -> Double {
        id == hovered ? 8 : 0
    }

    static func summary(_ island: Island) -> String {
        let parts = [(SessionState.waiting, "等你"), (.running, "在跑"), (.doneUnread, "新完成")].compactMap { state, word in
            island.count(state) > 0 ? "\(island.count(state)) \(word)" : nil
        }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return island.members.isEmpty ? "没有会话" : "\(island.members.count) 个已读"
    }

    /// Islands paired with their tiles, from the back to the front.
    private func order(_ layout: IsoLayout) -> [(IsoLayout.Tile, Island)] {
        let byId = Dictionary(islands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return layout.backToFront.compactMap { tile in byId[tile.id].map { (tile, $0) } }
    }

    private func marks(_ layout: IsoLayout, _ pairs: [(IsoLayout.Tile, Island)]) -> [BeaconLayer.Mark] {
        pairs.flatMap { tile, island in
            island.members.filter { $0.state != .idle }.prefix(Self.beaconSlots.count).enumerated().map { index, member in
                let (u, v) = Self.beaconSlots[index]
                let foot = layout.point(on: tile, u, v, z: lift(tile.id))
                let head = layout.point(on: tile, u, v, z: lift(tile.id) + HUD.height(member.state))
                return BeaconLayer.Mark(id: "\(member.sessionId)#\(member.state.rawValue)", state: member.state, foot: foot,
                                        height: Double(foot.y - head.y))
            }
        }
    }

    // MARK: Drawing

    private static func drawGrid(_ context: inout GraphicsContext, _ size: CGSize) {
        var dots = Path()
        for x in stride(from: 7.0, to: Double(size.width), by: 14) {
            for y in stride(from: 7.0, to: Double(size.height), by: 14) {
                dots.addEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
            }
        }
        context.fill(dots, with: .color(Color(hex: 0x82AAE6).opacity(0.16)))
    }

    private func drawIsland(_ context: inout GraphicsContext, _ layout: IsoLayout, _ tile: IsoLayout.Tile, _ island: Island, z: Double) {
        // The slab's sides: outlines stacked from the underside up, lighter towards the top.
        let steps = 6
        for step in 0...steps {
            let depth = z - layout.thickness * Double(steps - step) / Double(steps)
            let shade = Double(step) / Double(steps)
            context.fill(outline(layout, tile, z: depth),
                         with: .color(Color(red: 0.02 + 0.03 * shade, green: 0.035 + 0.045 * shade, blue: 0.06 + 0.07 * shade)))
        }
        let top = outline(layout, tile, z: z)
        let selected = tile.id == selection
        context.fill(top, with: .color(Color(hex: selected ? 0x14233A : 0x0E1724)))
        let accent = island.count(.waiting) > 0 ? HUD.wait : HUD.run
        let dash: [CGFloat] = island.isOther ? [4, 3] : []
        if selected {
            var glow = context
            glow.addFilter(.shadow(color: accent.opacity(0.6), radius: 9))
            glow.stroke(top, with: .color(accent.opacity(0.9)), style: StrokeStyle(lineWidth: 1.4, dash: dash))
        } else {
            let edge = tile.id == hovered ? Color(hex: 0x78AAFF).opacity(0.5) : Color(hex: 0x78AAFF).opacity(0.24)
            context.stroke(top, with: .color(edge), style: StrokeStyle(lineWidth: 1, dash: dash))
        }
        for (index, _) in island.members.filter({ $0.state == .idle }).prefix(Self.dotSlots.count).enumerated() {
            let (u, v) = Self.dotSlots[index]
            let point = layout.point(on: tile, u, v, z: z)
            context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 1.8, width: 6, height: 3.6)), with: .color(HUD.idle))
        }
    }

    private func drawName(_ context: inout GraphicsContext, _ layout: IsoLayout, _ tile: IsoLayout.Tile, _ island: Island, z: Double) {
        let anchor = layout.point(on: tile, 0.30, 0.72, z: z)
        let name = context.resolve(Text(Self.truncated(island.name, to: 16)).font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(HUD.text))
        let counts = context.resolve(Text(Self.summary(island)).font(.system(size: 10)).foregroundStyle(HUD.text2))
        let limit = CGSize(width: 220, height: 20)
        let (nameSize, countsSize) = (name.measure(in: limit), counts.measure(in: limit))
        let width = max(nameSize.width, countsSize.width) + 12
        let box = CGRect(x: anchor.x - width / 2, y: anchor.y - (nameSize.height + countsSize.height + 6) / 2,
                         width: width, height: nameSize.height + countsSize.height + 6)
        context.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(Color.black.opacity(0.5)))
        context.draw(name, in: CGRect(x: box.minX + 6, y: box.minY + 3, width: width - 12, height: nameSize.height))
        context.draw(counts, in: CGRect(x: box.minX + 6, y: box.minY + 3 + nameSize.height, width: width - 12, height: countsSize.height))
    }

    /// The tile's top face with rounded corners, projected.
    private func outline(_ layout: IsoLayout, _ tile: IsoLayout.Tile, z: Double) -> Path {
        let r = 0.12
        var points: [CGPoint] = []
        for (cu, cv, start) in [(1 - r, r, -90.0), (1 - r, 1 - r, 0.0), (r, 1 - r, 90.0), (r, r, 180.0)] {
            for step in 0...5 {
                let angle = (start + Double(step) * 18) * .pi / 180
                points.append(layout.point(on: tile, cu + r * cos(angle), cv + r * sin(angle), z: z))
            }
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    private static func truncated(_ text: String, to length: Int) -> String {
        text.count > length ? String(text.prefix(length - 1)) + "…" : text
    }
}

/// The beacons as Core Animation layers: a glowing head on a pillar of light, a ring spreading from the foot
/// of a waiting one, a slow bob on a running one. The loops run in the window server, so a moving map costs
/// the app almost nothing between updates (SwiftUI-driven loops cost 15–25 % CPU here). With Reduce Motion
/// nothing moves, and a waiting beacon keeps a still ring so it does not rely on motion to stand out.
struct BeaconLayer: NSViewRepresentable {
    struct Mark: Equatable {
        /// Session and state: a beacon that changes state gets new layers and starts its loop afresh.
        let id: String
        let state: SessionState
        /// In the map's coordinates (y down).
        let foot: CGPoint
        /// The pillar's height on screen.
        let height: Double
    }

    let marks: [Mark]
    let size: CGSize
    let animated: Bool

    func makeNSView(context: Context) -> BeaconHostView {
        BeaconHostView()
    }

    func updateNSView(_ view: BeaconHostView, context: Context) {
        view.update(marks: marks, height: Double(size.height), animated: animated)
    }
}

final class BeaconHostView: NSView {
    private var beacons: [String: BeaconLayers] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Hover and clicks belong to the map underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(marks: [BeaconLayer.Mark], height: Double, animated: Bool) {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let live = Set(marks.map(\.id))
        for (id, beacon) in beacons where !live.contains(id) {
            beacon.root.removeFromSuperlayer()
            beacons[id] = nil
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for mark in marks {
            let beacon = beacons[mark.id] ?? BeaconLayers(mark: mark, animated: animated, scale: scale)
            if beacons[mark.id] == nil {
                root.addSublayer(beacon.root)
                beacons[mark.id] = beacon
            }
            // Layers count y upwards from the bottom; the map counts it down from the top.
            beacon.root.position = CGPoint(x: mark.foot.x, y: height - mark.foot.y)
        }
        CATransaction.commit()
    }
}

@MainActor
private final class BeaconLayers {
    let root = CALayer()

    init(mark: BeaconLayer.Mark, animated: Bool, scale: CGFloat) {
        let color = NSColor(HUD.color(mark.state))
        let height = mark.height
        // Desynchronise the loops so a row of beacons does not pulse in step.
        let offset = Double(abs(mark.id.hashValue) % 1000) / 1000

        if mark.state == .waiting {
            let k = cos(IsoProjection.tilt)
            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: -20, y: -20 * k, width: 40, height: 40 * k), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = color.cgColor
            ring.lineWidth = 1.6
            ring.contentsScale = scale
            if animated {
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 0.15
                grow.toValue = 1.0
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.9
                fade.toValue = 0.0
                let group = CAAnimationGroup()
                group.animations = [grow, fade]
                group.duration = 2.2
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                group.repeatCount = .infinity
                group.timeOffset = offset * 2.2
                ring.add(group, forKey: "pulse")
            } else {
                ring.transform = CATransform3DMakeScale(0.6, 0.6, 1)
                ring.opacity = 0.6
            }
            root.addSublayer(ring)
        }

        let pillar = CAGradientLayer()
        pillar.colors = [color.withAlphaComponent(0.1).cgColor, color.withAlphaComponent(0.95).cgColor]  // bottom → top
        pillar.anchorPoint = CGPoint(x: 0.5, y: 0)
        pillar.bounds = CGRect(x: 0, y: 0, width: 4, height: height)
        pillar.position = .zero
        pillar.cornerRadius = 2
        pillar.contentsScale = scale

        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [color.withAlphaComponent(0.55).cgColor, color.withAlphaComponent(0).cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        glow.position = CGPoint(x: 0, y: height)
        glow.contentsScale = scale

        let head = CALayer()
        head.backgroundColor = color.cgColor
        head.bounds = CGRect(x: 0, y: 0, width: 9, height: 9)
        head.cornerRadius = 4.5
        head.position = CGPoint(x: 0, y: height)
        head.contentsScale = scale

        if animated, mark.state == .running {
            let stretch = CABasicAnimation(keyPath: "transform.scale.y")
            stretch.fromValue = 0.92
            stretch.toValue = 1.1
            let rise = CABasicAnimation(keyPath: "position.y")
            rise.fromValue = height * 0.92
            rise.toValue = height * 1.1
            for (layer, animation) in [(pillar, stretch), (glow, rise), (head, rise)] as [(CALayer, CABasicAnimation)] {
                let loop = animation.copy() as! CABasicAnimation
                loop.duration = 0.8
                loop.autoreverses = true
                loop.repeatCount = .infinity
                loop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                loop.timeOffset = offset * 1.6
                layer.add(loop, forKey: "bob")
            }
        }
        [pillar, glow, head].forEach(root.addSublayer)
    }
}
