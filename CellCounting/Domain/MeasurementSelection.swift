import Foundation
import CoreGraphics

/// Value snapshots keep filtering independent of SwiftData fetches and view redraws.
nonisolated struct ReviewRegion: Hashable, Sendable {
    let id: UUID
    let kind: String
    let shape: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    @MainActor init(_ roi: ROIRecord) {
        id = roi.id; kind = roi.kind; shape = roi.shape
        x = roi.x; y = roi.y; width = roi.width; height = roi.height
    }

    init(id: UUID = UUID(), kind: String, shape: String = "rect", x: Double,
         y: Double, width: Double, height: Double) {
        self.id = id; self.kind = kind; self.shape = shape
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    nonisolated func contains(_ cell: DetectedCell) -> Bool {
        guard width > 0, height > 0 else { return false }
        if shape == "ellipse" {
            let nx = (cell.cx - x - width / 2) / (width / 2)
            let ny = (cell.cy - y - height / 2) / (height / 2)
            return nx * nx + ny * ny <= 1
        }
        return cell.cx >= x && cell.cx <= x + width && cell.cy >= y && cell.cy <= y + height
    }
}

nonisolated struct ReviewDataKey: Hashable, Sendable {
    let imageId: UUID?
    let detectionId: UUID?
    let revision: Int
    let confidence: Double
    let regions: [ReviewRegion]
    let pxPerUm: Double
}

nonisolated struct ReviewSummary: Sendable {
    var cells: [DetectedCell] = []
    var totalCount = 0
    var meanDiameter = 0.0
    var diameterDeviation = 0.0
    var means: [String: Double] = [:]
    var excludedCount: Int { max(0, totalCount - cells.count) }

    nonisolated static func make(cells: [DetectedCell], confidence: Double,
                                regions: [ReviewRegion]) -> ReviewSummary {
        let includes = regions.filter { $0.kind == "include" }
        let excludes = regions.filter { $0.kind == "exclude" }
        let filtered = cells.filter { cell in
            cell.confidence >= confidence
                && (includes.isEmpty || includes.contains { $0.contains(cell) })
                && !excludes.contains { $0.contains(cell) }
        }
        var result = ReviewSummary()
        result.cells = filtered; result.totalCount = cells.count
        // Welford's algorithm avoids cancellation when diameters are close together.
        var count = 0, m2 = 0.0
        var sums: [String: Double] = [:], counts: [String: Int] = [:]
        for cell in filtered {
            if cell.diameter.isFinite {
                count += 1
                let delta = cell.diameter - result.meanDiameter
                result.meanDiameter += delta / Double(count)
                m2 += delta * (cell.diameter - result.meanDiameter)
            }
            let values: [(String, Double?)] = [
                ("area", cell.areaMicrons2), ("perimeter", cell.perimeterMicrons),
                ("circularity", cell.circularity), ("eccentricity", cell.eccentricity),
                ("aspectRatio", cell.aspectRatio), ("solidity", cell.solidity)
            ]
            for (key, value) in values {
                if let value, value.isFinite { sums[key, default: 0] += value; counts[key, default: 0] += 1 }
            }
        }
        result.diameterDeviation = count > 1 ? sqrt(max(0, m2 / Double(count))) : 0
        for (key, sum) in sums { result.means[key] = sum / Double(counts[key] ?? 1) }
        return result
    }
}

/// All three review surfaces share these source-cell UUIDs. Hidden/stale selections
/// are removed when the image or inclusion filter changes, before bulk edits run.
nonisolated enum MeasurementSelection {
    nonisolated static func reconciled(_ selected: Set<UUID>, cells: [DetectedCell]) -> Set<UUID> {
        selected.intersection(Set(cells.map(\.id)))
    }

    nonisolated static func selecting(_ ids: Set<UUID>, from selected: Set<UUID>,
                                      extend: Bool) -> Set<UUID> {
        extend ? selected.union(ids) : ids
    }

    /// Overlay edits replace the visible subset while retaining excluded cells.
    /// Use the current visible IDs for each transaction, even during a multi-edit gesture.
    nonisolated static func merging(visible: [DetectedCell], into all: [DetectedCell],
                                    previouslyVisibleIds: Set<UUID>) -> [DetectedCell] {
        let edited = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var result: [DetectedCell] = [], retained = Set<UUID>()
        for cell in all {
            if previouslyVisibleIds.contains(cell.id) {
                if let replacement = edited[cell.id] { result.append(replacement); retained.insert(cell.id) }
            } else { result.append(cell); retained.insert(cell.id) }
        }
        for cell in visible where retained.insert(cell.id).inserted { result.append(cell) }
        return result
    }
}

nonisolated struct MeasurementPoint: Identifiable, Sendable {
    let id: UUID
    let area: Double
    let intensity: Double
}

nonisolated struct MeasurementPlot: Sendable {
    let points: [MeasurementPoint]
    let areaRange: ClosedRange<Double>
    let intensityRange: ClosedRange<Double>

    nonisolated init(cells: [DetectedCell], channel: Int? = nil) {
        points = cells.compactMap { cell in
            // A missing measurement is unknown, never a fabricated zero or circle area.
            let intensity = channel.map { index in cell.channelIntensities?.first { $0.channel == index }?.mean } ?? cell.meanIntensity
            guard let area = cell.areaMicrons2, let intensity, area.isFinite,
                  intensity.isFinite, area >= 0 else { return nil }
            return MeasurementPoint(id: cell.id, area: area, intensity: intensity)
        }
        func range(_ values: [Double]) -> ClosedRange<Double> {
            let lo = values.min() ?? 0, hi = values.max() ?? 1
            let padding = max(0.001, abs(hi - lo) * 0.05, abs(lo) * 0.01)
            return (lo - padding)...(hi + padding)
        }
        areaRange = range(points.map(\.area)); intensityRange = range(points.map(\.intensity))
    }

    nonisolated func position(_ point: MeasurementPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (point.area - areaRange.lowerBound) / (areaRange.upperBound - areaRange.lowerBound) * size.width,
                y: (1 - (point.intensity - intensityRange.lowerBound) / (intensityRange.upperBound - intensityRange.lowerBound)) * size.height)
    }

    nonisolated func selected(in rect: CGRect, size: CGSize) -> Set<UUID> {
        Set(points.lazy.filter { rect.contains(position($0, size: size)) }.map(\.id))
    }

    nonisolated func nearest(to location: CGPoint, size: CGSize, radius: CGFloat = 9) -> UUID? {
        var best: (UUID, CGFloat)?
        for point in points {
            let p = position(point, size: size)
            let distance = hypot(p.x - location.x, p.y - location.y)
            if distance <= radius && distance < (best?.1 ?? .infinity) { best = (point.id, distance) }
        }
        return best?.0
    }
}

/// Relative to the saved mask: a cell visible only in Current is added.
nonisolated struct VariantMaskComparison: Sendable {
    var added = Set<UUID>()
    var removed = Set<UUID>()
    var changedCurrent = Set<UUID>()
    var changedSaved = Set<UUID>()
    var unchangedCurrent = Set<UUID>()
    var unchangedSaved = Set<UUID>()

    nonisolated static func compare(saved: [DetectedCell], current: [DetectedCell]) -> VariantMaskComparison {
        var result = VariantMaskComparison()
        let savedBounds = saved.map(geometryBounds)
        let currentBounds = current.map(geometryBounds)
        let byId = Dictionary(saved.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var used = Set<Int>()
        var pairs: [(Int, Int)] = []
        var unmatched: [Int] = []
        for (i, cell) in current.enumerated() {
            if let old = byId[cell.id], used.insert(old).inserted { pairs.append((old, i)) }
            else { unmatched.append(i) }
        }
        // Re-detection assigns new UUIDs. Spatial buckets avoid comparing every pair.
        let step = max(16, saved.map(\.diameterPx).filter { $0.isFinite && $0 > 0 }.sorted().dropFirst(saved.count / 2).first ?? 32)
        struct Bucket: Hashable { let x: Int; let y: Int }
        var buckets: [Bucket: [Int]] = [:]
        for (i, cell) in saved.enumerated() where !used.contains(i) && cell.cx.isFinite && cell.cy.isFinite {
            buckets[Bucket(x: Int(floor(cell.cx / step)), y: Int(floor(cell.cy / step))), default: []].append(i)
        }
        var candidates: [(Double, Int, Int)] = []
        for i in unmatched {
            let cell = current[i]
            guard cell.cx.isFinite, cell.cy.isFinite else { continue }
            let bx = Int(floor(cell.cx / step)), by = Int(floor(cell.cy / step))
            // Centers farther than one median diameter are conservatively reported
            // as removal/addition. This is a geometric comparison, not lineage.
            for x in (bx - 1)...(bx + 1) { for y in (by - 1)...(by + 1) {
                for j in buckets[Bucket(x: x, y: y)] ?? [] {
                    let a = savedBounds[j], b = currentBounds[i]
                    let intersection = a.intersection(b)
                    let area = max(0, intersection.width) * max(0, intersection.height)
                    let union = a.width * a.height + b.width * b.height - area
                    let score = union > 0 ? area / union : 0
                    if score >= 0.3 { candidates.append((score, j, i)) }
                }
            } }
        }
        candidates.sort { $0.0 == $1.0 ? ($0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1) : $0.0 > $1.0 }
        var matchedCurrent = Set(pairs.map { $0.1 })
        for (_, j, i) in candidates where !used.contains(j) && !matchedCurrent.contains(i) {
            used.insert(j); matchedCurrent.insert(i); pairs.append((j, i))
        }
        for (j, i) in pairs {
            if sameGeometry(saved[j], current[i]) {
                result.unchangedSaved.insert(saved[j].id); result.unchangedCurrent.insert(current[i].id)
            } else {
                result.changedSaved.insert(saved[j].id); result.changedCurrent.insert(current[i].id)
            }
        }
        for (i, cell) in saved.enumerated() where !used.contains(i) { result.removed.insert(cell.id) }
        for (i, cell) in current.enumerated() where !matchedCurrent.contains(i) { result.added.insert(cell.id) }
        return result
    }

    nonisolated static func geometryBounds(_ cell: DetectedCell) -> CGRect {
        guard let points = cell.contourPx, points.count >= 3 else {
            return CGRect(x: cell.cx - cell.diameterPx / 2, y: cell.cy - cell.diameterPx / 2,
                          width: max(0, cell.diameterPx), height: max(0, cell.diameterPx))
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    nonisolated static func sameGeometry(_ lhs: DetectedCell, _ rhs: DetectedCell) -> Bool {
        if let lhsContour = lhs.contourPx, lhsContour.count >= 3,
           let rhsContour = rhs.contourPx, rhsContour.count >= 3 {
            func close(_ p: CGPoint, _ q: CGPoint) -> Bool { hypot(p.x - q.x, p.y - q.y) <= 0.05 }
            func openRing(_ points: [CGPoint]) -> [CGPoint] {
                if points.count > 3, let first = points.first, let last = points.last,
                   close(first, last) { return Array(points.dropLast()) }
                return points
            }
            let a = openRing(lhsContour), b = openRing(rhsContour)
            guard a.count == b.count else { return false }
            for offset in b.indices where close(a[0], b[offset]) {
                if a.indices.allSatisfy({ close(a[$0], b[(offset + $0) % b.count]) })
                    || a.indices.allSatisfy({ close(a[$0], b[(offset - $0 + b.count) % b.count]) }) { return true }
            }
            return false
        }
        if (lhs.contourPx?.count ?? 0) >= 3 || (rhs.contourPx?.count ?? 0) >= 3 { return false }
        return abs(lhs.cx - rhs.cx) <= 0.05 && abs(lhs.cy - rhs.cy) <= 0.05
            && abs(lhs.diameterPx - rhs.diameterPx) <= 0.05
    }
}

/// Describe persisted facts only; legacy records must never inherit a new model's name.
nonisolated enum AnalysisStateDescription {
    static func model(detectorId: String?, savedModelName: String?) -> String {
        guard let detectorId else { return "Not analyzed" }
        if let savedModelName, !savedModelName.isEmpty { return savedModelName }
        return "\(detectorId) · settings unavailable"
    }

    nonisolated static func review(pending: Int?, correctionCount: Int) -> String {
        guard let pending else { return "Not analyzed" }
        if pending < 0 { return "Review status unavailable" }
        if pending > 0 { return "\(pending) awaiting review" }
        return correctionCount > 0 ? "Review queue clear · corrected" : "Review queue clear"
    }
}

/// One image snapshot is retained. Styling/selection/viewport redraws reuse this
/// result; only source revisions, confidence, ROI geometry or calibration invalidate it.
@MainActor
final class ReviewSummaryCache {
    private(set) var key: ReviewDataKey?
    private(set) var rebuildCount = 0
    private var snapshot = ReviewSummary()

    func value(for key: ReviewDataKey, cells: [DetectedCell]) -> ReviewSummary {
        guard self.key != key else { return snapshot }
        snapshot = ReviewSummary.make(cells: cells, confidence: key.confidence, regions: key.regions)
        self.key = key; rebuildCount += 1
        return snapshot
    }
}

/// A shared source-coordinate transform drives both comparison panes.
nonisolated struct ReviewViewport: Sendable {
    let sourceSize: CGSize
    let viewSize: CGSize
    let zoom: Double
    let center: CGPoint

    var scale: CGFloat {
        max(0.0001, min(viewSize.width / max(1, sourceSize.width),
                       viewSize.height / max(1, sourceSize.height)) * zoom)
    }
    var offset: CGPoint {
        CGPoint(x: viewSize.width / 2 - center.x * sourceSize.width * scale,
                y: viewSize.height / 2 - center.y * sourceSize.height * scale)
    }
    var visibleSourceRect: CGRect {
        CGRect(x: -offset.x / scale, y: -offset.y / scale,
               width: viewSize.width / scale, height: viewSize.height / scale)
    }
    func centerAfterPan(from origin: CGPoint, translation: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, origin.x - translation.width / (max(1, sourceSize.width) * scale))),
                y: min(1, max(0, origin.y - translation.height / (max(1, sourceSize.height) * scale))))
    }
}
