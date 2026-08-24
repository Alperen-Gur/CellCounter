import Foundation

struct BatchInsightsSnapshot: Codable, Equatable, Sendable {
    struct RiskImage: Codable, Equatable, Sendable, Identifiable {
        let imageId: UUID
        let fileName: String
        let score: Double
        let reasons: [String]
        let cellCount: Int
        var id: UUID { imageId }
    }

    let revision: Int
    let generatedAt: Date
    let imageCount: Int
    let cellCount: Int
    let confidenceBins: [Int]
    let diameterBins: [Int]
    let diameterRange: ClosedRange<Double>
    let riskImages: [RiskImage]
    let drift: [SequenceWorkflowService.DriftOffset]
    let ensembleAgreement: Int
    let ensembleDisagreement: Int
    let recommendations: [String]
}

/// Materialized input that can safely leave the MainActor. SwiftData models
/// are never captured by the detached analytics task.
struct BatchInsightsInput: Sendable {
    struct ImageInput: Sendable {
        let id: UUID
        let fileName: String
        let cells: [DetectedCell]
        let imageStats: [String: Double]
    }

    let revision: Int
    let images: [ImageInput]
}

enum BatchInsightsService {
    nonisolated static let confidenceBucketCount = 10
    nonisolated static let diameterBucketCount = 20

    nonisolated static func compute(_ input: BatchInsightsInput) -> BatchInsightsSnapshot {
        let allCells = input.images.flatMap(\.cells)
        var confidenceBins = Array(repeating: 0, count: confidenceBucketCount)
        for cell in allCells {
            let index = min(confidenceBucketCount - 1,
                            max(0, Int(cell.confidence * Double(confidenceBucketCount))))
            confidenceBins[index] += 1
        }

        let sortedDiameters = allCells.map(\.diameter).filter { $0.isFinite && $0 >= 0 }.sorted()
        let low = quantile(sortedDiameters, 0.01) ?? 0
        let rawHigh = quantile(sortedDiameters, 0.99) ?? max(1, low + 1)
        let high = max(low + 1, rawHigh)
        var diameterBins = Array(repeating: 0, count: diameterBucketCount)
        for value in sortedDiameters {
            let normalized = (value - low) / (high - low)
            let index = min(diameterBucketCount - 1,
                            max(0, Int(normalized * Double(diameterBucketCount))))
            diameterBins[index] += 1
        }

        let counts = input.images.map { Double($0.cells.count) }
        let countMean = counts.isEmpty ? 0 : counts.reduce(0, +) / Double(counts.count)
        let countVariance = counts.isEmpty ? 0 : counts.reduce(0) {
            $0 + pow($1 - countMean, 2)
        } / Double(counts.count)
        let countSD = sqrt(countVariance)

        let risks = input.images.map { image -> BatchInsightsSnapshot.RiskImage in
            let n = max(1, image.cells.count)
            let lowConfidence = Double(image.cells.filter { $0.confidence < 0.65 }.count) / Double(n)
            let edge = Double(image.cells.filter(\.edgeTouching).count) / Double(n)
            let suspicious = Double(image.cells.filter { $0.likelyClump || $0.likelyDebris }.count) / Double(n)
            let focus = image.imageStats["focus_score"] ?? 1
            let illumination = image.imageStats["illumination_residual"] ?? 0
            let countZ = countSD > 0 ? abs(Double(image.cells.count) - countMean) / countSD : 0
            let score = min(100,
                            lowConfidence * 50
                            + edge * 10
                            + suspicious * 15
                            + max(0, 0.45 - focus) * 45
                            + min(1, illumination) * 15
                            + min(3, countZ) * 4)
            var reasons: [String] = []
            if lowConfidence > 0.15 { reasons.append("many uncertain masks") }
            if focus < 0.45 { reasons.append("low focus") }
            if illumination > 0.18 { reasons.append("uneven illumination") }
            if suspicious > 0.08 { reasons.append("clump/debris flags") }
            if countZ > 2 { reasons.append("unusual cell count") }
            if reasons.isEmpty { reasons.append("minor heuristic variance") }
            return .init(imageId: image.id, fileName: image.fileName, score: score,
                         reasons: reasons, cellCount: image.cells.count)
        }.sorted { $0.score > $1.score }

        let frames = input.images.map(\.cells)
        let drift = SequenceWorkflowService.estimateDrift(frames: frames)
        let agreement = Int(input.images.reduce(0) { $0 + ($1.imageStats["ensemble_agreement"] ?? 0) })
        let disagreement = Int(input.images.reduce(0) { $0 + ($1.imageStats["ensemble_disagreement"] ?? 0) })
        let recommendations = makeRecommendations(images: input.images, risks: risks,
                                                  agreement: agreement,
                                                  disagreement: disagreement)

        return BatchInsightsSnapshot(
            revision: input.revision,
            generatedAt: Date(),
            imageCount: input.images.count,
            cellCount: allCells.count,
            confidenceBins: confidenceBins,
            diameterBins: diameterBins,
            diameterRange: low...high,
            riskImages: Array(risks.prefix(20)),
            drift: drift,
            ensembleAgreement: agreement,
            ensembleDisagreement: disagreement,
            recommendations: recommendations)
    }

    private nonisolated static func makeRecommendations(
        images: [BatchInsightsInput.ImageInput],
        risks: [BatchInsightsSnapshot.RiskImage],
        agreement: Int,
        disagreement: Int
    ) -> [String] {
        var output: [String] = []
        let meanFocus = mean(images.compactMap { $0.imageStats["focus_score"] })
        let meanIllumination = mean(images.compactMap { $0.imageStats["illumination_residual"] })
        if let meanIllumination, meanIllumination > 0.18 {
            output.append("Try CLAHE or rolling-ball background correction; illumination residual is high.")
        }
        if let meanFocus, meanFocus < 0.45 {
            output.append("Try anisotropic diffusion before segmentation; several fields have weak focus/noisy boundaries.")
        }
        if disagreement > 0, Double(disagreement) / Double(max(1, agreement + disagreement)) > 0.18 {
            output.append("Detector disagreement is elevated; review the disagreement queue or compare saved mask variants.")
        }
        if risks.first?.score ?? 0 > 45 {
            output.append("Start with the ranked high-risk fields below instead of reviewing images in import order.")
        }
        let driftMax = SequenceWorkflowService.estimateDrift(frames: images.map(\.cells))
            .map { $0.magnitudePx }.max() ?? 0
        if driftMax > 8 {
            output.append("Enable drift correction for tracking and mask propagation.")
        }
        if output.isEmpty {
            output.append("No strong heuristic issue detected. Keep current settings and review only low-confidence masks.")
        }
        return output
    }

    private nonisolated static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private nonisolated static func quantile(_ sorted: [Double], _ q: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let position = min(1, max(0, q)) * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}
