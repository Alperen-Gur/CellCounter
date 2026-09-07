import Foundation
import CoreGraphics
import SwiftData
import Testing
@testable import CellCounting

@Suite(.serialized)
struct ReviewQueueScalingTests {
    @MainActor private func library(imageCount: Int = 320) throws -> (Repositories, [ImageRecord]) {
        let repos = Repositories(inMemory: true)
        let batch = repos.createBatch(displayName: "Large review fixture", modelId: "test",
                                      pxPerUm: 2, thresholds: [10, 20])
        var images: [ImageRecord] = []
        for index in 0..<imageCount {
            let image = ImageRecord(fileName: "image-\(index).png", originalPath: "",
                                    widthPx: 20_000, heightPx: 20_000)
            repos.context.insert(image)
            image.batch = batch
            let cells: [DetectedCell] = (0..<4).map { offset in
                let center = Double(100 + offset * 20)
                let contour: [CGPoint] = (0..<32).map { point in
                    CGPoint(x: center + Double(point), y: 100 + Double(point))
                }
                return DetectedCell(cx: center, cy: 100,
                                    diameter: 8, diameterPx: 16, confidence: 0.2,
                                    contourPx: contour)
            }
            repos.saveDetection(cells, detectorId: "test", for: image, save: false)
            images.append(image)
        }
        try repos.context.save()
        return (repos, images)
    }

    @Test @MainActor func skipVisitsAll1280CandidatesWithOnly96Retained() throws {
        let (repos, images) = try library()
        let session = ReviewQueueSession()
        session.reload(using: repos)
        #expect(repos.pendingReviewCandidates(limit: 10_000).count == 96)
        #expect(repos.pendingReviewCandidates(limit: 0).isEmpty)
        var seen = Set<UUID>()
        while let item = session.current {
            #expect(session.items.count <= 96)
            #expect(seen.insert(item.id).inserted, "Tied confidence scores must not repeat across pages")
            session.skip(using: repos)
            if seen.count > 1280 { Issue.record("Queue looped"); break }
        }
        #expect(seen.count == 1280)
        #expect(session.skippedCount == 1280)
        #expect(session.items.isEmpty)
        #expect(repos.pendingReviewCandidateCount() == 1280)
        #expect(images.allSatisfy { $0.detection?.corrections.isEmpty == true })
        session.reload(using: repos)
        #expect(session.current != nil, "Skipped cells must return on the next visit")
    }

    @Test @MainActor func keepRejectResizeAndUndoSurvivePageBoundaries() throws {
        let (repos, _) = try library()
        let session = ReviewQueueSession()
        session.reload(using: repos)
        for _ in 0..<191 { session.skip(using: repos) }
        let rejected = try #require(session.current)
        let original = rejected.detection.cells
        let removedIndex = try #require(original.firstIndex { $0.id == rejected.cell.id })
        var remaining = original
        remaining.remove(at: removedIndex)
        let rejection = repos.commitCellEdit(
            cells: remaining, corrections: [CorrectionSpec(kind: "remove", cell: rejected.cell)],
            detection: rejected.detection, image: rejected.image)
        session.remove(rejected.id, using: repos)
        #expect(session.current?.id != rejected.id)
        #expect(session.items.count == 96, "The action on the last card must fetch the next page")
        #expect(!rejected.detection.cells.contains { $0.id == rejected.cell.id })

        let kept = try #require(session.current)
        let keep = repos.commitCellEdit(
            cells: nil, corrections: [CorrectionSpec(kind: "accept", cell: kept.cell)],
            detection: kept.detection, image: kept.image)
        session.remove(kept.id, using: repos)
        #expect(keep.reviewCountDelta == -1)
        #expect(kept.detection.cells.contains { $0.id == kept.cell.id })

        let resized = try #require(session.current)
        var edited = resized.detection.cells
        let editIndex = try #require(edited.firstIndex { $0.id == resized.cell.id })
        edited[editIndex].diameter = 13
        edited[editIndex].diameterPx = 26
        _ = repos.commitCellEdit(
            cells: edited, corrections: [CorrectionSpec(kind: "resize", cell: edited[editIndex])],
            detection: resized.detection, image: resized.image)
        session.remove(resized.id, using: repos)

        // A subsequent edit on the rejected cell's image must survive undo,
        // even after the navigation cache has moved on to other images.
        var otherEdited = rejected.detection.cells
        let otherIndex = try #require(otherEdited.firstIndex {
            $0.id != kept.cell.id && $0.id != resized.cell.id
        })
        otherEdited[otherIndex].diameter = 17
        otherEdited[otherIndex].diameterPx = 34
        let otherID = otherEdited[otherIndex].id
        _ = repos.commitCellEdit(
            cells: otherEdited,
            corrections: [CorrectionSpec(kind: "resize", cell: otherEdited[otherIndex])],
            detection: rejected.detection, image: rejected.image)

        // Restore into the latest payload, so edits to other cells on the
        // same image are retained. Undo seeks back across the page boundary.
        var restored = rejected.detection.cells
        restored.insert(original[removedIndex], at: min(removedIndex, restored.count))
        let delta = repos.undoReviewCorrection(
            try #require(rejection.corrections.first), candidate: rejected.candidate,
            restoredCells: restored, detection: rejected.detection, image: rejected.image)
        session.restore(rejected.candidate, using: repos)
        #expect(delta == 1)
        #expect(session.current?.id == rejected.id)
        #expect(session.items.count <= 96)
        #expect(repos.pendingReviewCandidateCount() == 1277)
        #expect(resized.detection.cells.first { $0.id == resized.cell.id }?.diameterPx == 26)
        #expect(rejected.detection.cells.first { $0.id == otherID }?.diameterPx == 34)

        // Re-read a fresh context: review state and edited geometry are durable.
        let fresh = ModelContext(repos.container)
        let triaged = try fresh.fetch(FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { $0.triaged }))
        #expect(Set(triaged.map(\.cellId)) == [kept.cell.id, resized.cell.id, otherID])
        let savedCorrections = try fresh.fetch(FetchDescriptor<CorrectionRecord>())
        #expect(Set(savedCorrections.map(\.kind)) == ["accept", "resize"])
        let savedDetections = try fresh.fetch(FetchDescriptor<DetectionRecord>())
        let savedImage = try #require(savedDetections.first { $0.id == rejected.detection.id })
        let savedCells = DetectionRecord.decodeCellsData(savedImage.cellsData)
        #expect(savedCells.contains { $0.id == rejected.cell.id })
        #expect(savedCells.first { $0.id == otherID }?.diameterPx == 34)
    }

    @Test @MainActor func retainedModelsDoNotRetainEveryDecodedContourArray() throws {
        let (repos, images) = try library()
        defer { withExtendedLifetime(repos) {} }
        let detections = images.compactMap(\.detection)
        #expect(detections.count == 320)
        for detection in detections { #expect(detection.cells.count == 4) }
        #expect(detections.filter { $0.cachedCells != nil }.count <= 6)
        #expect(detections.first?.cachedCells == nil)
        #expect(detections.last?.cachedCells?.count == 4)
        let first = try #require(detections.first)
        let storedIDs = DetectionRecord.decodeCellsData(first.cellsData).map(\.id)
        #expect(first.cells.map(\.id) == storedIDs, "Eviction must never alter stored cells")
    }

    @Test func decodedCacheHonorsByteBudgetAndRevision() {
        let cell = DetectedCell(cx: 10, cy: 20, diameter: 5, diameterPx: 10,
                                confidence: 0.2, contourPx: Array(repeating: .zero, count: 1024))
        let cost = DecodedCellCache.estimatedBytes([cell])
        let cache = DecodedCellCache(countLimit: 6, byteLimit: cost * 2)
        let first = UUID(), second = UUID(), third = UUID()
        cache.insert([cell], for: first, revision: 0)
        cache.insert([cell], for: second, revision: 0)
        #expect(cache.cells(for: first, revision: 0) != nil)
        cache.insert([cell], for: third, revision: 1)
        #expect(cache.retainedCount == 2)
        #expect(cache.retainedBytes <= cost * 2)
        #expect(cache.cells(for: second, revision: 0) == nil)
        #expect(cache.cells(for: third, revision: 0) == nil)
        cache.insert([cell, cell, cell], for: third, revision: 2)
        #expect(cache.cells(for: third, revision: 2) == nil)
        #expect(cache.retainedBytes <= cost * 2)
    }

    @Test @MainActor func indexUpgradePreservesTriagedRowsAndBackfillsStableKeys() async throws {
        let (repos, images) = try library(imageCount: 3)
        let rows = try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>())
        let kept = try #require(rows.first)
        let detection = try #require(kept.detection)
        let image = try #require(kept.image)
        _ = repos.commitCellEdit(cells: nil,
                                 corrections: [CorrectionSpec(kind: "accept", cell: kept.fallbackCell)],
                                 detection: detection, image: image)
        for row in rows { row.sortKey = "" }
        // One old, unindexed detection also needs its JSON normalized once.
        let legacy = try #require(images.last?.detection)
        legacy.reviewIndexVersion = 0
        try repos.context.save()
        await repos.rebuildPerformanceIndexes()
        let updated = try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>())
        #expect(updated.count == 12)
        #expect(updated.allSatisfy { $0.sortKey == $0.id.uuidString })
        #expect(repos.pendingReviewCandidateCount() == 11)
        #expect(detection.corrections.count == 1)
    }
}
