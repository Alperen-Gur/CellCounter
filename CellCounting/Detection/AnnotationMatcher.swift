import Foundation

extension Notification.Name {
    /// Pass-17 (Lane B): posted whenever a `GroundTruthAnnotation` is added or
    /// removed for a given image. `object` is the `ImageRecord.id` (UUID) so
    /// subscribers can filter to only the image they're rendering. The Results
    /// viewer + the F1 sidebar panel both subscribe.
    static let ccAnnotationsChanged = Notification.Name("ccAnnotationsChanged")
}

/// Pass-17 (Lane B): match user-placed `GroundTruthAnnotation` points to model
/// `DetectedCell` instances and compute precision / recall / F1.
///
/// All distance math is in SOURCE-PIXEL space — annotations store `cx,cy` in
/// the same coordinate system that detections use (`DetectedCell.cx,cy` and
/// `diameterPx`), so no scaling is needed.
///
/// Candidate discovery uses a uniform spatial index. The final global greedy
/// ordering is unchanged, but sparse microscope fields avoid the previous
/// O(annotations × detections) scan and its oversized candidate allocation.
enum AnnotationMatcher {

    private struct GridKey: Hashable {
        let x: Int
        let y: Int
    }

    /// One annotation ↔ detection pair, with the distance that linked them.
    struct Pair {
        let annotation: GroundTruthAnnotation
        let detection: DetectedCell
        let distancePx: Double
    }

    /// Score summary returned by `evaluate`.
    struct Score {
        let pairs: [Pair]
        /// Detections that did NOT match any annotation.
        let unmatchedDetections: [DetectedCell]
        /// Annotations that did NOT match any detection.
        let unmatchedAnnotations: [GroundTruthAnnotation]
        /// Multiplier on each detection's diameter_px used as the match radius.
        let matchRadiusFactor: Double

        var tp: Int { pairs.count }
        var fp: Int { unmatchedDetections.count }
        var fn: Int { unmatchedAnnotations.count }

        /// Precision = TP / (TP + FP). Returns nil when the denominator is 0
        /// (no detections at all), so callers can render "—" instead of 0/0.
        var precision: Double? {
            let denom = tp + fp
            guard denom > 0 else { return nil }
            return Double(tp) / Double(denom)
        }
        /// Recall = TP / (TP + FN). Returns nil when there are no annotations.
        var recall: Double? {
            let denom = tp + fn
            guard denom > 0 else { return nil }
            return Double(tp) / Double(denom)
        }
        /// F1 = 2·P·R / (P+R). Nil when either P or R is nil, or both are zero.
        var f1: Double? {
            guard let p = precision, let r = recall else { return nil }
            let denom = p + r
            guard denom > 0 else { return nil }
            return 2 * p * r / denom
        }
    }

    /// Greedy nearest-neighbour matcher.
    ///
    /// Algorithm:
    /// 1. Spatially query every (annotation, detection) candidate pair whose
    ///    distance ≤ `matchRadiusFactor * detection.diameterPx`.
    /// 2. Sort by distance ascending.
    /// 3. Walk in order, claiming each annotation + detection at most once.
    ///
    /// Candidate lookup is near O(N + M) for ordinary sparse fields; only
    /// genuinely dense/overlapping masks produce a large candidate set.
    static func evaluate(annotations: [GroundTruthAnnotation],
                         detections: [DetectedCell],
                         matchRadiusFactor: Double = 1.0) -> Score {
        // Empty-input fast paths so the panel can render sensible numbers.
        if annotations.isEmpty {
            return Score(pairs: [],
                         unmatchedDetections: detections,
                         unmatchedAnnotations: [],
                         matchRadiusFactor: matchRadiusFactor)
        }
        if detections.isEmpty {
            return Score(pairs: [],
                         unmatchedDetections: [],
                         unmatchedAnnotations: annotations,
                         matchRadiusFactor: matchRadiusFactor)
        }

        struct Candidate {
            let annIdx: Int
            let detIdx: Int
            let distanceSquared: Double
        }

        let positiveRadii = detections.map {
            matchRadiusFactor * max($0.diameterPx, 1)
        }.filter { $0 > 0 && $0.isFinite }
        let averageRadius = positiveRadii.isEmpty
            ? 16
            : positiveRadii.reduce(0, +) / Double(positiveRadii.count)
        let cellSize = max(8, min(256, averageRadius))

        func key(x: Double, y: Double) -> GridKey {
            GridKey(x: Int(floor(x / cellSize)),
                    y: Int(floor(y / cellSize)))
        }

        var annotationGrid: [GridKey: [Int]] = [:]
        annotationGrid.reserveCapacity(annotations.count)
        for (index, annotation) in annotations.enumerated() {
            annotationGrid[key(x: annotation.cx, y: annotation.cy), default: []]
                .append(index)
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(min(65_536, annotations.count * 4))
        for (di, d) in detections.enumerated() {
            let radius = matchRadiusFactor * max(d.diameterPx, 1)
            guard radius >= 0, radius.isFinite else { continue }
            let minX = Int(floor((d.cx - radius) / cellSize))
            let maxX = Int(floor((d.cx + radius) / cellSize))
            let minY = Int(floor((d.cy - radius) / cellSize))
            let maxY = Int(floor((d.cy + radius) / cellSize))
            let bucketCount = (maxX - minX + 1) * (maxY - minY + 1)
            let annotationIndices: AnySequence<Int>
            if bucketCount >= annotations.count {
                annotationIndices = AnySequence(annotations.indices)
            } else {
                annotationIndices = AnySequence(
                    (minY...maxY).lazy.flatMap { gy in
                        (minX...maxX).lazy.flatMap { gx in
                            annotationGrid[GridKey(x: gx, y: gy)] ?? []
                        }
                    })
            }
            let radiusSquared = radius * radius
            for ai in annotationIndices {
                let a = annotations[ai]
                let dx = a.cx - d.cx
                let dy = a.cy - d.cy
                let distanceSquared = dx * dx + dy * dy
                if distanceSquared <= radiusSquared {
                    candidates.append(Candidate(
                        annIdx: ai, detIdx: di,
                        distanceSquared: distanceSquared))
                }
            }
        }
        candidates.sort {
            if $0.distanceSquared != $1.distanceSquared {
                return $0.distanceSquared < $1.distanceSquared
            }
            if $0.annIdx != $1.annIdx { return $0.annIdx < $1.annIdx }
            return $0.detIdx < $1.detIdx
        }

        var claimedAnns = Set<Int>()
        var claimedDets = Set<Int>()
        var pairs: [Pair] = []
        pairs.reserveCapacity(min(annotations.count, detections.count))
        for c in candidates {
            if claimedAnns.contains(c.annIdx) { continue }
            if claimedDets.contains(c.detIdx) { continue }
            claimedAnns.insert(c.annIdx)
            claimedDets.insert(c.detIdx)
            pairs.append(Pair(annotation: annotations[c.annIdx],
                              detection: detections[c.detIdx],
                              distancePx: c.distanceSquared.squareRoot()))
        }

        let unmatchedAnns = annotations.enumerated()
            .filter { !claimedAnns.contains($0.offset) }
            .map { $0.element }
        let unmatchedDets = detections.enumerated()
            .filter { !claimedDets.contains($0.offset) }
            .map { $0.element }

        return Score(pairs: pairs,
                     unmatchedDetections: unmatchedDets,
                     unmatchedAnnotations: unmatchedAnns,
                     matchRadiusFactor: matchRadiusFactor)
    }
}
