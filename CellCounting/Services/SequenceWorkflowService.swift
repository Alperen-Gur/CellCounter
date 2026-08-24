import Foundation
import CoreGraphics

/// Lightweight, dependency-free sequence operations inspired by drift and
/// label-propagation workflows in Napari.
///
/// Drift is estimated from robust mutual-nearest centroid matches. It is kept
/// as analysis metadata and applied to tracking/propagation coordinates; source
/// masks are never shifted away from their microscope images.
enum SequenceWorkflowService {
    struct DriftOffset: Codable, Equatable, Sendable, Identifiable {
        var id: Int { frame }
        let frame: Int
        let dxPx: Double
        let dyPx: Double
        let matchedObjects: Int

        nonisolated var magnitudePx: Double { hypot(dxPx, dyPx) }
    }

    struct PropagationResult: Sendable {
        let cellsByFrame: [Int: [DetectedCell]]
        let skippedExisting: Int
    }

    nonisolated static func estimateDrift(frames: [[DetectedCell]],
                                          maxPairDistancePx: Double = 120) -> [DriftOffset] {
        guard !frames.isEmpty else { return [] }
        var result = [DriftOffset(frame: 0, dxPx: 0, dyPx: 0, matchedObjects: 0)]
        var cumulativeX = 0.0
        var cumulativeY = 0.0

        for frame in 1..<frames.count {
            let matches = mutualNearestMatches(from: frames[frame - 1],
                                               to: frames[frame],
                                               maxDistance: maxPairDistancePx)
            if !matches.isEmpty {
                cumulativeX += median(matches.map { $0.1.cx - $0.0.cx })
                cumulativeY += median(matches.map { $0.1.cy - $0.0.cy })
            }
            result.append(DriftOffset(frame: frame, dxPx: cumulativeX,
                                      dyPx: cumulativeY,
                                      matchedObjects: matches.count))
        }
        return result
    }

    nonisolated static func driftCorrected(frames: [[DetectedCell]],
                                           offsets: [DriftOffset]) -> [[DetectedCell]] {
        frames.enumerated().map { index, cells in
            let offset = offsets.indices.contains(index)
                ? offsets[index]
                : DriftOffset(frame: index, dxPx: 0, dyPx: 0, matchedObjects: 0)
            return cells.map { translated($0, dx: -offset.dxPx, dy: -offset.dyPx,
                                          preserveId: true) }
        }
    }

    /// Copy selected masks from one frame into later frames, translated by the
    /// estimated acquisition drift. Existing nearby masks win, preventing a
    /// propagation pass from silently duplicating labels.
    nonisolated static func propagate(sourceCells: [DetectedCell],
                                      sourceFrame: Int,
                                      frames: [[DetectedCell]],
                                      offsets: [DriftOffset],
                                      targetFrames: [Int]) -> PropagationResult {
        guard frames.indices.contains(sourceFrame) else {
            return PropagationResult(cellsByFrame: [:], skippedExisting: 0)
        }
        let sourceOffset = offsets.indices.contains(sourceFrame) ? offsets[sourceFrame] : nil
        var output: [Int: [DetectedCell]] = [:]
        var skipped = 0

        for frameIndex in targetFrames where frames.indices.contains(frameIndex) {
            let targetOffset = offsets.indices.contains(frameIndex) ? offsets[frameIndex] : nil
            let dx = (targetOffset?.dxPx ?? 0) - (sourceOffset?.dxPx ?? 0)
            let dy = (targetOffset?.dyPx ?? 0) - (sourceOffset?.dyPx ?? 0)
            var additions: [DetectedCell] = []
            for source in sourceCells {
                let candidate = translated(source, dx: dx, dy: dy, preserveId: false)
                let conflicts = frames[frameIndex].contains { existing in
                    let gate = max(4, min(existing.diameterPx, candidate.diameterPx) * 0.45)
                    return hypot(existing.cx - candidate.cx, existing.cy - candidate.cy) <= gate
                }
                if conflicts { skipped += 1 } else { additions.append(candidate) }
            }
            if !additions.isEmpty { output[frameIndex] = additions }
        }
        return PropagationResult(cellsByFrame: output, skippedExisting: skipped)
    }

    /// Interpolate a pair of anchor masks through intermediate frames. Polygon
    /// vertices are resampled to a common count before linear interpolation;
    /// circular/legacy masks interpolate their centroids and diameter.
    nonisolated static func interpolate(start: DetectedCell, startFrame: Int,
                                        end: DetectedCell, endFrame: Int) -> [Int: DetectedCell] {
        guard endFrame - startFrame > 1 else { return [:] }
        var result: [Int: DetectedCell] = [:]
        for frame in (startFrame + 1)..<endFrame {
            let t = Double(frame - startFrame) / Double(endFrame - startFrame)
            let cx = lerp(start.cx, end.cx, t)
            let cy = lerp(start.cy, end.cy, t)
            let diameter = lerp(start.diameter, end.diameter, t)
            let diameterPx = lerp(start.diameterPx, end.diameterPx, t)
            var contour: [CGPoint]? = nil
            if let a = start.contourPx, let b = end.contourPx,
               a.count >= 3, b.count >= 3 {
                let count = min(128, max(16, max(a.count, b.count)))
                let ar = resampleClosedPolygon(a, count: count)
                let br = resampleClosedPolygon(b, count: count)
                contour = zip(ar, br).map { p, q in
                    CGPoint(x: lerp(p.x, q.x, t), y: lerp(p.y, q.y, t))
                }
            }
            result[frame] = DetectedCell(
                cx: cx, cy: cy, diameter: diameter, diameterPx: diameterPx,
                confidence: min(start.confidence, end.confidence),
                areaMicrons2: interpolateOptional(start.areaMicrons2, end.areaMicrons2, t),
                perimeterMicrons: interpolateOptional(start.perimeterMicrons, end.perimeterMicrons, t),
                circularity: interpolateOptional(start.circularity, end.circularity, t),
                eccentricity: interpolateOptional(start.eccentricity, end.eccentricity, t),
                centroidUmX: interpolateOptional(start.centroidUmX, end.centroidUmX, t),
                centroidUmY: interpolateOptional(start.centroidUmY, end.centroidUmY, t),
                aspectRatio: interpolateOptional(start.aspectRatio, end.aspectRatio, t),
                solidity: interpolateOptional(start.solidity, end.solidity, t),
                contourPx: contour)
        }
        return result
    }

    private nonisolated static func mutualNearestMatches(
        from a: [DetectedCell], to b: [DetectedCell], maxDistance: Double
    ) -> [(DetectedCell, DetectedCell)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        let nearestB: [Int?] = a.map { source in
            b.indices.min { lhs, rhs in
                hypot(source.cx - b[lhs].cx, source.cy - b[lhs].cy)
                    < hypot(source.cx - b[rhs].cx, source.cy - b[rhs].cy)
            }
        }
        let nearestA: [Int?] = b.map { target in
            a.indices.min { lhs, rhs in
                hypot(target.cx - a[lhs].cx, target.cy - a[lhs].cy)
                    < hypot(target.cx - a[rhs].cx, target.cy - a[rhs].cy)
            }
        }
        var matches: [(DetectedCell, DetectedCell)] = []
        for i in a.indices {
            guard let j = nearestB[i], nearestA[j] == i else { continue }
            guard hypot(a[i].cx - b[j].cx, a[i].cy - b[j].cy) <= maxDistance else { continue }
            matches.append((a[i], b[j]))
        }
        return matches
    }

    private nonisolated static func translated(_ cell: DetectedCell, dx: Double, dy: Double,
                                               preserveId: Bool) -> DetectedCell {
        DetectedCell(
            id: preserveId ? cell.id : UUID(),
            cx: cell.cx + dx, cy: cell.cy + dy,
            diameter: cell.diameter, diameterPx: cell.diameterPx,
            confidence: cell.confidence,
            areaMicrons2: cell.areaMicrons2,
            perimeterMicrons: cell.perimeterMicrons,
            circularity: cell.circularity,
            eccentricity: cell.eccentricity,
            meanIntensity: cell.meanIntensity,
            integratedDensity: cell.integratedDensity,
            // Recomputed by the caller from the target batch calibration.
            centroidUmX: nil,
            centroidUmY: nil,
            aspectRatio: cell.aspectRatio, solidity: cell.solidity,
            edgeTouching: cell.edgeTouching,
            likelyClump: cell.likelyClump, likelyDebris: cell.likelyDebris,
            sizeClass: cell.sizeClass, isManual: cell.isManual,
            contourPx: cell.contourPx?.map {
                CGPoint(x: $0.x + CGFloat(dx), y: $0.y + CGFloat(dy))
            },
            channelIntensities: cell.channelIntensities)
    }

    private nonisolated static func resampleClosedPolygon(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count >= 2, count > 1 else { return points }
        let closed = points + [points[0]]
        var cumulative = [0.0]
        for i in 1..<closed.count {
            cumulative.append(cumulative.last! + Double(hypot(closed[i].x - closed[i - 1].x,
                                                               closed[i].y - closed[i - 1].y)))
        }
        guard let total = cumulative.last, total > 0 else { return Array(repeating: points[0], count: count) }
        return (0..<count).map { sample in
            let distance = total * Double(sample) / Double(count)
            var segment = 0
            while segment + 1 < cumulative.count && cumulative[segment + 1] < distance {
                segment += 1
            }
            let length = max(0.0001, cumulative[segment + 1] - cumulative[segment])
            let t = (distance - cumulative[segment]) / length
            return CGPoint(x: lerp(closed[segment].x, closed[segment + 1].x, t),
                           y: lerp(closed[segment].y, closed[segment + 1].y, t))
        }
    }

    private nonisolated static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private nonisolated static func lerp<T: BinaryFloatingPoint>(_ a: T, _ b: T, _ t: Double) -> T {
        a + (b - a) * T(t)
    }

    private nonisolated static func interpolateOptional(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        guard let a, let b else { return a ?? b }
        return lerp(a, b, t)
    }
}
