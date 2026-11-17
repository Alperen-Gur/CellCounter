import SwiftUI

/// Draw plan for the Results cell layer (`CellsCanvas`).
///
/// The layer used to issue one fill and one stroke per visible cell, in cell
/// order. This plan issues the same fills and strokes, with the same colours,
/// opacities and stroke styles, but merges cells into one path per bin colour
/// where that cannot change a single pixel:
///
/// * Every drawn item gets a footprint: its geometry on screen plus the
///   farthest its stroke can reach (miter joins included) plus one point
///   for anti-aliasing.
/// * Items are split into layers. An item goes one layer above every earlier
///   item whose footprint touches its own, so overlapping cells keep their
///   original drawing order. Items within one layer never touch, so drawing
///   them in any order, or as the subpaths of one path, produces the same
///   pixels as drawing them one by one.
/// * Only contour polygons (paths made of straight segments in both forms)
///   are merged. Dashed strokes, boxes/ellipses of cells without a contour,
///   and manual pins are still drawn one per cell, in their layer.
/// * A cell whose geometry is not finite is drawn alone, in a layer of its
///   own, exactly as before.
///
/// The one deliberate visual simplification: a cell smaller than
/// `tinyCellExtent` points on screen is drawn as a filled dot covering the
/// outer edge of its stroke, in its bin colour. At that size the 1–1.5 pt
/// stroke already covers the cell, so the dot looks the same. An uncertain
/// (dashed) cell's dot uses the dash pattern's duty cycle as its opacity.
nonisolated enum OverlayRenderPlan {
    /// Cells smaller than this many points on screen are drawn as dots.
    static let tinyCellExtent: CGFloat = 2

    /// Fraction of a dashed stroke that is ink (`dash: [3.5, 3]`).
    static let uncertainDotOpacity: Double = 3.5 / 6.5

    /// Contours: 1 pt stroke with the default miter limit of 10 reaches at
    /// most 5 pt from a vertex; plus 1 pt for anti-aliasing.
    static let contourMargin: CGFloat = 6
    /// Boxes and ellipses (smooth joins): 0.75 pt half stroke, plus
    /// anti-aliasing, rounded up.
    static let boxMargin: CGFloat = 2.5
    /// Dots are fills only.
    static let dotMargin: CGFloat = 1.5
    /// Manual pins: 7 pt radius, white stroke and the ordinal label, which is
    /// drawn up and to the left of the pin's centre.
    static let pinHalfExtent: CGFloat = 40

    enum Command {
        /// Source-space contour fill (`colour.opacity(0.25)`).
        case fillContours(bin: Int, path: Path)
        /// Source-space contour stroke (1 pt on screen, dashed when uncertain).
        case strokeContours(bin: Int, path: Path, dashed: Bool)
        /// View-space box or ellipse fill of a cell without a contour.
        case fillBox(bin: Int, path: Path)
        /// View-space box or ellipse stroke (1.5 pt, dashed when uncertain).
        case strokeBox(bin: Int, path: Path, dashed: Bool)
        /// View-space dots of tiny cells.
        case fillDots(bin: Int, uncertain: Bool, path: Path)
        /// A manual-count pin with its ordinal; drawn by the canvas.
        case pin(cellIndex: Int)
    }

    static func isTiny(_ size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite else { return false }
        return max(abs(size.width), abs(size.height)) < tinyCellExtent
    }

    /// The polygon of one contour: move to the first point, a line to each
    /// further point, close. `OverlayGeometryCache.path(for:contour:)` and the
    /// merged paths below build every contour with this one function.
    static func appendPolygon(_ contour: [CGPoint], to path: inout Path) {
        guard let first = contour.first else { return }
        path.move(to: first)
        for point in contour.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
    }

    // MARK: — Items

    private enum ItemKind {
        case contour(bin: Int, dashed: Bool)
        case box(bin: Int, dashed: Bool, rect: CGRect)
        case dot(bin: Int, uncertain: Bool, rect: CGRect)
        case pin
    }

    private struct Item {
        let cellIndex: Int
        let kind: ItemKind
    }

    /// Commands for the cells at `drawOrder` (ascending cell indices, as the
    /// spatial index returns them). `sourceBounds[i]` must be
    /// `CellSpatialIndex.sourceBounds(cells[i])`.
    static func commands(cells: [DetectedCell], drawOrder: [Int], sourceBounds: [CGRect],
                         thresholds: [Double], outlineShapes: Bool,
                         uncertaintyThreshold: Double,
                         viewScale: Double, viewOffset: CGPoint) -> [Command] {
        guard !drawOrder.isEmpty else { return [] }
        var items: [Item] = []
        var footprints: [CGRect] = []
        items.reserveCapacity(drawOrder.count)
        footprints.reserveCapacity(drawOrder.count)

        for cellIndex in drawOrder {
            let c = cells[cellIndex]
            let cxv = c.cx * viewScale + viewOffset.x
            let cyv = c.cy * viewScale + viewOffset.y
            if c.isManual {
                items.append(Item(cellIndex: cellIndex, kind: .pin))
                footprints.append(CGRect(x: cxv - pinHalfExtent, y: cyv - pinHalfExtent,
                                         width: pinHalfExtent * 2, height: pinHalfExtent * 2))
                continue
            }
            let bin = BinMath.binIndex(for: c.diameter, thresholds: thresholds)
            let uncertain = c.confidence < uncertaintyThreshold
            if let contour = c.contourPx, contour.count >= 3 {
                let finite = contour.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                let bounds = sourceBounds[cellIndex]
                let view = CGRect(x: bounds.minX * viewScale + viewOffset.x,
                                  y: bounds.minY * viewScale + viewOffset.y,
                                  width: bounds.width * viewScale,
                                  height: bounds.height * viewScale)
                if finite && isUsable(view) && isTiny(view.size) {
                    // Outer edge of the 1 pt stroke.
                    let dot = view.standardized.insetBy(dx: -0.5, dy: -0.5)
                    items.append(Item(cellIndex: cellIndex,
                                      kind: .dot(bin: bin, uncertain: uncertain, rect: dot)))
                    footprints.append(dot.insetBy(dx: -dotMargin, dy: -dotMargin))
                } else {
                    items.append(Item(cellIndex: cellIndex,
                                      kind: .contour(bin: bin, dashed: uncertain)))
                    footprints.append(finite
                        ? view.standardized.insetBy(dx: -contourMargin, dy: -contourMargin)
                        : .infinite)
                }
            } else {
                let r = (c.diameterPx * viewScale) / 2
                let rect = CGRect(x: cxv - r, y: cyv - r, width: r * 2, height: r * 2)
                if isUsable(rect) && isTiny(rect.size) {
                    // Outer edge of the 1.5 pt stroke.
                    let dot = rect.standardized.insetBy(dx: -0.75, dy: -0.75)
                    items.append(Item(cellIndex: cellIndex,
                                      kind: .dot(bin: bin, uncertain: uncertain, rect: dot)))
                    footprints.append(dot.insetBy(dx: -dotMargin, dy: -dotMargin))
                } else {
                    items.append(Item(cellIndex: cellIndex,
                                      kind: .box(bin: bin, dashed: uncertain, rect: rect)))
                    footprints.append(isUsable(rect)
                        ? rect.standardized.insetBy(dx: -boxMargin, dy: -boxMargin)
                        : .infinite)
                }
            }
        }

        let layerOf = layers(for: footprints)
        let layerCount = (layerOf.max() ?? -1) + 1
        // Stable bucket of item positions per layer (counting sort).
        var starts = [Int](repeating: 0, count: layerCount + 1)
        for layer in layerOf { starts[layer + 1] += 1 }
        for i in 0..<layerCount { starts[i + 1] += starts[i] }
        var fill = starts
        var ordered = [Int](repeating: 0, count: items.count)
        for (position, layer) in layerOf.enumerated() {
            ordered[fill[layer]] = position
            fill[layer] += 1
        }

        var commands: [Command] = []
        for layer in 0..<layerCount {
            let members = ordered[starts[layer]..<starts[layer + 1]]
            // Fill paths hold every contour of a bin; a bin's solid outline
            // reuses that path unless some of its contours are dashed.
            var fills: [Int: Path] = [:]
            var solidOnly: [Int: Path] = [:]
            var dashedBins = Set<Int>()
            var dashedContours: [(bin: Int, path: Path)] = []
            var boxes: [(bin: Int, dashed: Bool, path: Path)] = []
            var dots: [DotKey: Path] = [:]
            var pins: [Int] = []
            for position in members {
                let item = items[position]
                guard case .contour(let bin, let dashed) = item.kind, dashed else { continue }
                dashedBins.insert(bin)
            }
            for position in members {
                let item = items[position]
                switch item.kind {
                case .contour(let bin, let dashed):
                    let contour = cells[item.cellIndex].contourPx ?? []
                    appendPolygon(contour, to: &fills[bin, default: Path()])
                    if dashed {
                        // Whether a dash pattern restarts at each subpath is
                        // up to the renderer; keep each dashed outline apart.
                        var path = Path()
                        appendPolygon(contour, to: &path)
                        dashedContours.append((bin, path))
                    } else if dashedBins.contains(bin) {
                        appendPolygon(contour, to: &solidOnly[bin, default: Path()])
                    }
                case .box(let bin, let dashed, let rect):
                    let path = outlineShapes ? Path(ellipseIn: rect)
                                             : Path(roundedRect: rect, cornerRadius: 2)
                    boxes.append((bin, dashed, path))
                case .dot(let bin, let uncertain, let rect):
                    dots[DotKey(bin: bin, uncertain: uncertain), default: Path()].addEllipse(in: rect)
                case .pin:
                    pins.append(item.cellIndex)
                }
            }
            let bins = fills.keys.sorted()
            for bin in bins {
                commands.append(.fillContours(bin: bin, path: fills[bin]!))
            }
            for bin in bins {
                if !dashedBins.contains(bin) {
                    commands.append(.strokeContours(bin: bin, path: fills[bin]!, dashed: false))
                } else if let solid = solidOnly[bin] {
                    commands.append(.strokeContours(bin: bin, path: solid, dashed: false))
                }
            }
            for dashed in dashedContours {
                commands.append(.strokeContours(bin: dashed.bin, path: dashed.path, dashed: true))
            }
            for box in boxes {
                commands.append(.fillBox(bin: box.bin, path: box.path))
                commands.append(.strokeBox(bin: box.bin, path: box.path, dashed: box.dashed))
            }
            for key in dots.keys.sorted() {
                commands.append(.fillDots(bin: key.bin, uncertain: key.uncertain, path: dots[key]!))
            }
            for cellIndex in pins { commands.append(.pin(cellIndex: cellIndex)) }
        }
        return commands
    }

    private struct DotKey: Hashable, Comparable {
        let bin: Int
        let uncertain: Bool
        static func < (l: DotKey, r: DotKey) -> Bool {
            l.bin != r.bin ? l.bin < r.bin : (!l.uncertain && r.uncertain)
        }
    }

    // MARK: — Layers

    /// Layer of each footprint, in order: one above the highest earlier
    /// footprint it touches (0 when it touches none). A footprint that is not
    /// a usable finite rectangle touches everything: it gets a layer of its
    /// own above all earlier ones, and every later footprint goes above it.
    static func layers(for footprints: [CGRect]) -> [Int] {
        var layers = [Int](repeating: 0, count: footprints.count)
        guard !footprints.isEmpty else { return layers }
        var bounds = CGRect.null
        var extentSum: CGFloat = 0
        var usable = 0
        for rect in footprints where isUsable(rect) {
            bounds = bounds.union(rect)
            extentSum += max(rect.width, rect.height)
            usable += 1
        }
        var grid = LayerGrid(bounds: bounds,
                             typicalExtent: usable > 0 ? extentSum / CGFloat(usable) : 1)
        var floor = 0, top = -1
        for j in footprints.indices {
            let rect = footprints[j]
            guard isUsable(rect) else {
                top += 1
                layers[j] = top
                floor = top + 1
                continue
            }
            let range = grid.range(of: rect)
            var layer = floor
            grid.forEachEntry(in: range) { i in
                if layers[i] >= layer, overlaps(footprints[i], rect) { layer = layers[i] + 1 }
            }
            layers[j] = layer
            top = max(top, layer)
            grid.insert(j, in: range)
        }
        return layers
    }

    /// Finite, non-null and within a range the layer grid can index.
    static func isUsable(_ rect: CGRect) -> Bool {
        guard !rect.isNull, !rect.isInfinite else { return false }
        let limit: CGFloat = 1e9
        return [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy { $0.isFinite && abs($0) <= limit }
    }

    /// Closed intervals: touching counts as overlapping.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
    }
}

/// Uniform bucket grid over the footprints, with per-bucket linked lists of
/// earlier items, so each footprint is compared only with nearby ones.
nonisolated private struct LayerGrid {
    struct Range { let c0: Int, c1: Int, r0: Int, r1: Int }

    private let origin: CGPoint
    private let cellSize: CGFloat
    private let cols: Int
    private let rows: Int
    private var head: [Int32]
    private var next: [Int32] = []
    private var item: [Int32] = []

    init(bounds: CGRect, typicalExtent: CGFloat) {
        guard !bounds.isNull else {
            origin = .zero; cellSize = 1; cols = 1; rows = 1
            head = [-1]
            return
        }
        let maxBuckets = 65_536
        let width = max(bounds.width, 1), height = max(bounds.height, 1)
        var size = max(typicalExtent.isFinite ? typicalExtent : 1, 1,
                       (width * height / CGFloat(maxBuckets)).squareRoot())
        while (Int(width / size) + 1) * (Int(height / size) + 1) > maxBuckets { size *= 2 }
        origin = bounds.origin
        cellSize = size
        cols = Int(width / size) + 1
        rows = Int(height / size) + 1
        head = [Int32](repeating: -1, count: cols * rows)
    }

    func range(of rect: CGRect) -> Range {
        func index(_ value: CGFloat, _ start: CGFloat, _ count: Int) -> Int {
            min(count - 1, max(0, Int(((value - start) / cellSize).rounded(.down))))
        }
        return Range(c0: index(rect.minX, origin.x, cols), c1: index(rect.maxX, origin.x, cols),
                     r0: index(rect.minY, origin.y, rows), r1: index(rect.maxY, origin.y, rows))
    }

    func forEachEntry(in range: Range, _ body: (Int) -> Void) {
        for row in range.r0...range.r1 {
            for col in range.c0...range.c1 {
                var entry = head[row * cols + col]
                while entry >= 0 {
                    body(Int(item[Int(entry)]))
                    entry = next[Int(entry)]
                }
            }
        }
    }

    mutating func insert(_ value: Int, in range: Range) {
        for row in range.r0...range.r1 {
            for col in range.c0...range.c1 {
                let bucket = row * cols + col
                item.append(Int32(value))
                next.append(head[bucket])
                head[bucket] = Int32(item.count - 1)
            }
        }
    }
}
