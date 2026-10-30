import CoreGraphics
import Foundation

/// One Cursor window on the deck's map, with the sessions that run in it.
public struct Island: Sendable, Equatable, Identifiable {
    public struct Member: Sendable, Equatable {
        public let sessionId: String
        public let state: SessionState
    }

    /// The window's folders, standardized, sorted and joined; `WindowMap.otherID` for sessions outside
    /// every open window. The lock file's pid cannot tell windows apart: they all report Cursor's pid.
    public let id: String
    public let name: String
    public let folders: [String]
    /// In inbox order: waiting, new, running, idle; newest first within a state.
    public let members: [Member]
    public let lastActive: Date?

    public var isOther: Bool { id == WindowMap.otherID }

    public func count(_ state: SessionState) -> Int {
        members.filter { $0.state == state }.count
    }
}

public enum WindowMap {
    public static let otherID = "~other"

    /// Groups sessions by the Cursor window they run in (the deepest folder that contains their directory).
    /// The busiest `maxIslands` windows go on the map, busiest first: something waiting, then something
    /// new, then something running, then the most recent activity. The rest come back as `quiet`.
    public static func build(windows: [IDEWindow], inbox: Inbox, maxIslands: Int = 6) -> (islands: [Island], quiet: [Island]) {
        var folders: [String: [String]] = [:]
        for window in windows {
            folders[key(window)] = window.workspaceFolders.map { ($0 as NSString).standardizingPath }
        }
        var members: [String: [Island.Member]] = [:]
        var active: [String: Date] = [:]
        for session in inbox.ordered {
            let id = WorkspaceResolver.window(containing: session.cwd, in: windows).map(key) ?? otherID
            members[id, default: []].append(Island.Member(sessionId: session.id, state: inbox.state(of: session)))
            active[id] = max(active[id] ?? .distantPast, session.updatedAt)
        }
        var all = folders.map { id, paths in
            Island(id: id, name: name(for: paths), folders: paths, members: members[id] ?? [], lastActive: active[id])
        }
        if let others = members[otherID] {
            all.append(Island(id: otherID, name: "其他", folders: [], members: others, lastActive: active[otherID]))
        }
        all.sort(by: busierFirst)
        return (Array(all.prefix(maxIslands)), Array(all.dropFirst(maxIslands)))
    }

    static func key(_ window: IDEWindow) -> String {
        window.workspaceFolders.map { ($0 as NSString).standardizingPath }.sorted().joined(separator: "\n")
    }

    /// A single-folder window is named after its folder; a multi-root one after its first folder plus a count.
    static func name(for folders: [String]) -> String {
        guard let first = folders.first else { return "其他" }
        let base = (first as NSString).lastPathComponent
        return folders.count > 1 ? "\(base) +\(folders.count - 1)" : base
    }

    private static func busierFirst(_ a: Island, _ b: Island) -> Bool {
        for state in [SessionState.waiting, .doneUnread, .running] {
            let (x, y) = (a.count(state) > 0, b.count(state) > 0)
            if x != y { return x }
        }
        let (x, y) = (a.lastActive ?? .distantPast, b.lastActive ?? .distantPast)
        if x != y { return x > y }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// The board the islands stand on, seen the way the design mock-up shows it: turned −42° in its own plane,
/// tilted back 57°, projected orthographically. Board coordinates: x right, y down, z up off the board.
public struct IsoProjection: Sendable, Equatable {
    public static let turn = -42.0 * Double.pi / 180
    public static let tilt = 57.0 * Double.pi / 180

    /// Where the board's centre lands in view coordinates.
    public var origin: CGPoint

    public init(origin: CGPoint) {
        self.origin = origin
    }

    public func project(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint {
        let (c, s) = (cos(Self.turn), sin(Self.turn))
        let depth = x * s + y * c
        return CGPoint(x: origin.x + x * c - y * s, y: origin.y + depth * cos(Self.tilt) - z * sin(Self.tilt))
    }
}

/// Where each island sits on the board, sized to fit a view.
public struct IsoLayout: Sendable, Equatable {
    public struct Tile: Sendable, Equatable {
        public let id: String
        /// On the board, which is centred on the projection's origin.
        public let rect: CGRect
    }

    public let tiles: [Tile]
    public let projection: IsoProjection
    public let tileSize: Double
    public let thickness: Double

    /// Grid for `count` islands: 1×1, 2×1, 2×2, 3×2 (columns × rows).
    public static func grid(for count: Int) -> (columns: Int, rows: Int) {
        switch count {
        case ...1: return (1, 1)
        case 2: return (2, 1)
        case 3...4: return (2, 2)
        default: return (3, 2)
        }
    }

    /// Lays `ids` out in reading order so the board, its thickness and `headroom` for beacons above it fit `size`.
    public init(ids: [String], size: CGSize, gap: Double = 18, thickness: Double = 12, headroom: Double = 56,
                maxTile: Double = 124) {
        let (columns, rows) = Self.grid(for: ids.count)
        let (c, s, k) = (abs(cos(IsoProjection.turn)), abs(sin(IsoProjection.turn)), cos(IsoProjection.tilt))
        let (cols, rws) = (Double(columns), Double(rows))
        let lift = thickness * sin(IsoProjection.tilt)
        // Projected width and height grow linearly with the tile size t; solve both for t and take the smaller.
        let byWidth = (Double(size.width) - gap * ((cols - 1) * c + (rws - 1) * s)) / (cols * c + rws * s)
        let byHeight = (Double(size.height) - headroom - lift - gap * ((cols - 1) * s + (rws - 1) * c) * k) / ((cols * s + rws * c) * k)
        let t = max(1, min(byWidth, byHeight, maxTile))
        let (width, height) = (cols * t + (cols - 1) * gap, rws * t + (rws - 1) * gap)

        var tiles: [Tile] = []
        for (index, id) in ids.prefix(columns * rows).enumerated() {
            let (column, row) = (Double(index % columns), Double(index / columns))
            tiles.append(Tile(id: id, rect: CGRect(x: -width / 2 + column * (t + gap), y: -height / 2 + row * (t + gap),
                                                   width: t, height: t)))
        }

        // Centre the projected board horizontally, and vertically in the space left below the headroom.
        let probe = IsoProjection(origin: .zero)
        let corners = [(-width / 2, -height / 2), (width / 2, -height / 2), (width / 2, height / 2), (-width / 2, height / 2)]
            .map { probe.project($0.0, $0.1) }
        let (minX, maxX) = (corners.map(\.x).min()!, corners.map(\.x).max()!)
        let (minY, maxY) = (corners.map(\.y).min()!, corners.map(\.y).max()!)
        let origin = CGPoint(x: Double(size.width) / 2 - Double(minX + maxX) / 2,
                             y: (headroom + Double(size.height) - lift) / 2 - Double(minY + maxY) / 2)
        self.tiles = tiles
        self.projection = IsoProjection(origin: origin)
        self.tileSize = t
        self.thickness = thickness
    }

    /// A point on a tile's top face, from fractions of the tile (0…1, x along its top edge, y down its side).
    public func point(on tile: Tile, _ u: Double, _ v: Double, z: Double = 0) -> CGPoint {
        projection.project(Double(tile.rect.minX) + u * Double(tile.rect.width), Double(tile.rect.minY) + v * Double(tile.rect.height), z)
    }

    /// The tile's top face as a polygon in view coordinates.
    public func outline(of tile: Tile, z: Double = 0) -> [CGPoint] {
        [point(on: tile, 0, 0, z: z), point(on: tile, 1, 0, z: z), point(on: tile, 1, 1, z: z), point(on: tile, 0, 1, z: z)]
    }

    /// How near the viewer a tile is: larger is further in front.
    public func depth(of tile: Tile) -> Double {
        Double(point(on: tile, 0.5, 0.5).y)
    }

    /// Tiles from the back to the front, the order to draw them in.
    public var backToFront: [Tile] {
        tiles.sorted { depth(of: $0) < depth(of: $1) }
    }

    /// The front-most tile whose top face contains `point`; `lift` raises a tile (the one under the pointer).
    public func tile(at point: CGPoint, lift: (String) -> Double = { _ in 0 }) -> String? {
        backToFront.reversed().first { contains(outline(of: $0, z: lift($0.id)), point) }?.id
    }

    private func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let (a, b) = (polygon[i], polygon[j])
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
