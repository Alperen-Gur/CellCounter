import Foundation
import CoreGraphics

/// A balanced bounds tree for the current image. Bounds come from every contour
/// vertex, never the equivalent diameter (which cannot bound elongated cells).
/// Query results retain source array order so hit testing can reverse draw order.
nonisolated struct CellSpatialIndex: Sendable {
    struct Query: Sendable {
        var indices: [Int] = []
        var examinedEntries = 0
    }
    private struct Entry: Sendable { let index: Int; let bounds: CGRect }
    private struct Node: Sendable {
        let bounds: CGRect
        let left: Int?
        let right: Int?
        let entries: [Entry]
    }
    private var nodes: [Node] = []
    private var root: Int?
    let bounds: [CGRect]
    let manualOrdinals: [Int]
    let indicesByID: [UUID: Int]

    init(cells: [DetectedCell]) {
        bounds = cells.map(Self.sourceBounds)
        var ordinal = 0
        manualOrdinals = cells.map { cell in
            if cell.isManual { ordinal += 1; return ordinal }
            return 0
        }
        indicesByID = Dictionary(cells.enumerated().map { ($0.element.id, $0.offset) },
                                 uniquingKeysWith: { _, last in last })
        let entries = bounds.enumerated().compactMap { index, rect -> Entry? in
            guard Self.isFinite(rect) else { return nil }
            return Entry(index: index, bounds: rect)
        }
        root = build(entries)
    }

    static func sourceBounds(_ cell: DetectedCell) -> CGRect {
        guard cell.cx.isFinite, cell.cy.isFinite else { return .null }
        let center = CGPoint(x: cell.cx, y: cell.cy)
        // Pins have fixed screen size. Queries expand by their source-space
        // radius; retaining their centroid keeps the tree independent of zoom.
        if cell.isManual { return CGRect(origin: center, size: .zero) }
        if let contour = cell.contourPx, contour.count >= 3 {
            var minX = center.x, maxX = center.x, minY = center.y, maxY = center.y
            for point in contour where point.x.isFinite && point.y.isFinite {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        let radius = cell.diameterPx.isFinite ? max(0, cell.diameterPx / 2) : 0
        return CGRect(x: center.x - radius, y: center.y - radius,
                      width: radius * 2, height: radius * 2)
    }

    private mutating func build(_ entries: [Entry]) -> Int? {
        guard !entries.isEmpty else { return nil }
        var bounds = entries[0].bounds
        for entry in entries.dropFirst() { bounds = Self.union(bounds, entry.bounds) }
        let index = nodes.count
        nodes.append(Node(bounds: bounds, left: nil, right: nil, entries: []))
        if entries.count <= 12 {
            nodes[index] = Node(bounds: bounds, left: nil, right: nil, entries: entries)
        } else {
            let horizontal = bounds.width >= bounds.height
            let ordered = entries.sorted {
                let a = horizontal ? $0.bounds.midX : $0.bounds.midY
                let b = horizontal ? $1.bounds.midX : $1.bounds.midY
                return a == b ? $0.index < $1.index : a < b
            }
            let mid = ordered.count / 2
            let left = build(Array(ordered[..<mid]))
            let right = build(Array(ordered[mid...]))
            nodes[index] = Node(bounds: bounds, left: left, right: right, entries: [])
        }
        return index
    }

    func query(_ rect: CGRect) -> Query {
        guard Self.isFinite(rect), let root else { return Query() }
        var result = Query()
        var pending = [root]
        while let index = pending.popLast() {
            let node = nodes[index]
            guard Self.intersects(node.bounds, rect) else { continue }
            for entry in node.entries {
                result.examinedEntries += 1
                if Self.intersects(entry.bounds, rect) { result.indices.append(entry.index) }
            }
            if let left = node.left { pending.append(left) }
            if let right = node.right { pending.append(right) }
        }
        result.indices.sort()
        return result
    }

    func hitIndex(at point: CGPoint, cells: [DetectedCell], outline: Bool,
                  manualRadius: Double) -> Int? {
        let radius = max(0, manualRadius)
        let region = CGRect(x: point.x - radius, y: point.y - radius,
                            width: radius * 2, height: radius * 2)
        for index in query(region).indices.reversed() {
            let cell = cells[index]
            let dx = point.x - cell.cx, dy = point.y - cell.cy
            if cell.isManual {
                if dx * dx + dy * dy <= radius * radius { return index }
            } else if let contour = cell.contourPx, contour.count >= 3 {
                if Self.pointInPolygon(point, polygon: contour) { return index }
            } else {
                let r = cell.diameterPx / 2
                if outline ? dx * dx + dy * dy <= r * r : abs(dx) <= r && abs(dy) <= r {
                    return index
                }
            }
        }
        return nil
    }

    static func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y) {
                let x = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.minX.isFinite && rect.minY.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
    }
    // CGRect.intersects excludes some zero-area rectangles. Manual centroids
    // and a click are legitimate closed bounds, including exact edge hits.
    private static func intersects(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX <= b.maxX && a.maxX >= b.minX && a.minY <= b.maxY && a.maxY >= b.minY
    }
    private static func union(_ a: CGRect, _ b: CGRect) -> CGRect {
        let x = min(a.minX, b.minX), y = min(a.minY, b.minY)
        return CGRect(x: x, y: y, width: max(a.maxX, b.maxX) - x,
                      height: max(a.maxY, b.maxY) - y)
    }
}
