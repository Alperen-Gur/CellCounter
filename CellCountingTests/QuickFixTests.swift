import Foundation
import CoreGraphics
import SwiftData
import Testing
@testable import CellCounting

@Suite(.serialized)
struct QuickFixTests {
    private func cell(_ index: Int) -> DetectedCell {
        let center = Double(40 + index * 12)
        let contour: [CGPoint] = (0..<8).map { CGPoint(x: center + Double($0), y: 30 + Double($0)) }
        return DetectedCell(cx: center, cy: 30, diameter: 8, diameterPx: 16,
                            confidence: 0.5 + Double(index % 3) * 0.1, contourPx: contour)
    }

    /// Two batches; image order within a batch differs from import order.
    @MainActor private func fixture() throws -> (Repositories, [BatchRecord], [[ImageRecord]]) {
        let repos = Repositories(inMemory: true)
        var batches: [BatchRecord] = []
        var all: [[ImageRecord]] = []
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for b in 0..<2 {
            let batch = repos.createBatch(displayName: "Batch \(b)", modelId: "test", pxPerUm: 2, thresholds: [10, 20])
            batch.createdAt = base.addingTimeInterval(Double(b) * 100)
            var images: [ImageRecord] = []
            for i in 0..<4 {
                let image = ImageRecord(fileName: "b\(b)-\(i).png", originalPath: "", widthPx: 100, heightPx: 80)
                repos.context.insert(image)
                image.batch = batch
                // Import order is reversed relative to creation order.
                image.importedAt = base.addingTimeInterval(Double(b) * 100 + Double(10 - i))
                image.sourceOrder = i
                repos.saveDetection((0..<(i + 1)).map(cell), detectorId: "test", for: image, save: false)
                if let detection = image.detection {
                    for k in 0..<(i + b) {
                        let correction = CorrectionRecord(kind: "add", cellId: UUID(), cx: 1, cy: 2, diameter: 3 + Double(k))
                        repos.context.insert(correction)
                        correction.detection = detection
                    }
                }
                images.append(image)
            }
            batch.imageCountSummary = images.count
            batch.cellCountSummary = images.reduce(0) { $0 + ($1.detection?.summaryCellCount ?? 0) }
            batches.append(batch)
            all.append(images)
        }
        // Orphans: neither walk reaches these.
        let orphan = CorrectionRecord(kind: "add", cellId: UUID(), cx: 0, cy: 0, diameter: 1)
        repos.context.insert(orphan)
        let loose = ImageRecord(fileName: "loose.png", originalPath: "", widthPx: 10, heightPx: 10)
        repos.context.insert(loose)
        repos.saveDetection([cell(0)], detectorId: "test", for: loose, save: false)
        let looseCorrection = CorrectionRecord(kind: "add", cellId: UUID(), cx: 0, cy: 0, diameter: 1)
        repos.context.insert(looseCorrection)
        looseCorrection.detection = loose.detection
        try repos.context.save()
        return (repos, batches, all)
    }

    @Test @MainActor func retrainBannerCountMatchesFullWalk() throws {
        let (repos, _, _) = try fixture()
        let walked = repos.allBatches().flatMap { $0.images }.compactMap { $0.detection }.flatMap { $0.corrections }.count
        #expect(walked > 0)
        #expect(repos.reachableCorrectionCount() == walked)
    }

    @Test @MainActor func recentSummariesMatchTheImageWalk() throws {
        let (repos, batches, _) = try fixture()
        let summaries = repos.recentBatchSummaries(limit: 5)
        let expected = repos.allBatches().prefix(5).map { batch -> BatchSummary in
            let first = batch.images.min(by: { $0.importedAt < $1.importedAt })
            return BatchSummary(id: batch.id, displayName: batch.displayName, createdAt: batch.createdAt,
                                imageCount: max(0, batch.imageCountSummary),
                                cellCount: max(0, batch.cellCountSummary),
                                thumbnailURL: first?.thumbURL)
        }
        #expect(summaries == Array(expected))
        #expect(summaries.count == 2)
        #expect(summaries.first?.id == batches[1].id)
        #expect(summaries.allSatisfy { $0.thumbnailURL != nil })
    }

    @Test @MainActor func fineTuneSamplesMatchSynchronousResult() async throws {
        let (repos, _, all) = try fixture()
        let images = all.flatMap { $0 }
        let sync = TrainingDatasetService.samples(from: images)
        let decoded = await TrainingDatasetService.decode(TrainingDatasetService.pendingSamples(from: images))
        #expect(sync.count == images.count)
        #expect(decoded.count == sync.count)
        for (a, b) in zip(sync, decoded) {
            #expect(a.id == b.id)
            #expect(a.name == b.name)
            #expect(a.group == b.group)
            #expect(a.width == b.width && a.height == b.height)
            #expect(a.cells.map(\.id) == b.cells.map(\.id))
            #expect(a.cells.count == b.cells.count)
            #expect(a.detectionID == b.detectionID)
            #expect(a.detectionRevision == b.detectionRevision)
            #expect(a.zProjection == b.zProjection)
            #expect(a.sourceSettingsKnown == b.sourceSettingsKnown)
        }
        #expect(repos.image(id: images[2].id)?.id == images[2].id)
    }

    @Test @MainActor func currentImageFollowsImageBatchAndEdits() throws {
        let (repos, batches, all) = try fixture()
        let state = AppState(repos: repos)
        state.currentBatchId = batches[0].id
        state.currentImageIdx = 0
        #expect(state.currentImage?.id == all[0][0].id)
        state.currentImageIdx = 2
        #expect(state.currentImage?.id == all[0][2].id)
        state.currentBatchId = batches[1].id
        state.currentImageIdx = 1
        #expect(state.currentImage?.id == all[1][1].id)
        state.currentImageIdx = 9
        #expect(state.currentImage == nil)

        state.currentBatchId = batches[0].id
        state.currentImageIdx = 3
        let target = try #require(state.currentImage)
        let detection = try #require(target.detection)
        let old = detection.cells
        let kept = Array(old.dropLast())
        _ = repos.commitCellEdit(cells: kept,
                                 corrections: [CorrectionSpec(kind: "remove", cell: old[old.count - 1])],
                                 detection: detection, image: target)
        #expect(state.currentImage?.id == all[0][3].id)
        #expect(state.currentImage?.detection?.cells.count == kept.count)
    }
}
