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
/// Concurrency: callers run this on @MainActor for N < 5000 cells. For our
/// typical microscope image (≤ ~1000 cells) the greedy O(N·M) match is fast
/// enough to be invisible inside SwiftUI's body. Document the limit at the
/// call site if cell counts grow.
enum AnnotationMatcher {

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
    /// 1. Compute every (annotation, detection) candidate pair whose Euclidean
    ///    distance ≤ `matchRadiusFactor * detection.diameterPx`.
    /// 2. Sort by distance ascending.
    /// 3. Walk in order, claiming each annotation + detection at most once.
    ///
    /// For the cell counts we care about (≤ ~1000) this is O(N·M log(N·M))
    /// and runs in well under a millisecond on the main actor. If we ever
    /// exceed ~5000 cells per image, swap in a spatial index before the
    /// `MainActor` assumption breaks.
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
            let distance: Double
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(annotations.count * detections.count / 4)
        for (ai, a) in annotations.enumerated() {
            for (di, d) in detections.enumerated() {
                let dx = a.cx - d.cx
                let dy = a.cy - d.cy
                let dist = (dx * dx + dy * dy).squareRoot()
                // Match window: scale by EACH detection's own diameter so a
                // big cell forgives a slightly-off click and a tiny cell
                // doesn't grab a nearby unrelated annotation.
                let radius = matchRadiusFactor * max(d.diameterPx, 1)
                if dist <= radius {
                    candidates.append(Candidate(annIdx: ai, detIdx: di, distance: dist))
                }
            }
        }
        candidates.sort { $0.distance < $1.distance }

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
                              distancePx: c.distance))
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
