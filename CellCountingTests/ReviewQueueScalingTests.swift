import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftData
import Testing
@testable import CellCounting

@Suite(.serialized)
struct ReviewQueueScalingTests {
    @MainActor private func library(imageCount: Int = 320, repository: Repositories? = nil) throws -> (Repositories, [ImageRecord]) {
        let repos = repository ?? Repositories(inMemory: true)
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
        #expect(try repos.pendingReviewCandidates(limit: 10_000).count == 96)
        #expect(try repos.pendingReviewCandidates(limit: 0).isEmpty)
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
        let rejection = try repos.commitReviewCellEdit(
            storage: DetectionRecord.makeStorageSnapshot(remaining), corrections: [CorrectionSpec(kind: "remove", cell: rejected.cell)],
            detection: rejected.detection, image: rejected.image)
        session.remove(rejected.id, using: repos)
        #expect(session.current?.id != rejected.id)
        #expect(session.items.count == 96, "The action on the last card must fetch the next page")
        #expect(!rejected.detection.cells.contains { $0.id == rejected.cell.id })

        let kept = try #require(session.current)
        let keep = try repos.commitReviewCellEdit(
            storage: nil, corrections: [CorrectionSpec(kind: "accept", cell: kept.cell)],
            detection: kept.detection, image: kept.image)
        session.remove(kept.id, using: repos)
        #expect(keep.reviewCountDelta == -1)
        #expect(kept.detection.cells.contains { $0.id == kept.cell.id })

        let resized = try #require(session.current)
        var edited = resized.detection.cells
        let editIndex = try #require(edited.firstIndex { $0.id == resized.cell.id })
        edited[editIndex].diameter = 13
        edited[editIndex].diameterPx = 26
        _ = try repos.commitReviewCellEdit(
            storage: DetectionRecord.makeStorageSnapshot(edited), corrections: [CorrectionSpec(kind: "resize", cell: edited[editIndex])],
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
        let delta = try repos.undoReviewCorrection(
            try #require(rejection.corrections.first), candidate: rejected.candidate,
            restoredStorage: DetectionRecord.makeStorageSnapshot(restored), detection: rejected.detection, image: rejected.image)
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
        try await repos.rebuildPerformanceIndexes()
        let updated = try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>())
        #expect(updated.count == 12)
        #expect(updated.allSatisfy { $0.sortKey == $0.id.uuidString })
        #expect(repos.pendingReviewCandidateCount() == 11)
        #expect(detection.corrections.count == 1)
    }

    @Test @MainActor func legacyResetOrphansCannotOpenDeletedOwnersAndAreRepaired() async throws {
        let (repos, images) = try library(imageCount: 30)
        let batch = try #require(images.first?.batch)
        // Simulate the old reset: it deleted only batches and relied on cascades.
        repos.context.delete(batch)
        try repos.context.save()
        let session = ReviewQueueSession()
        session.reload(using: repos)
        #expect(session.current == nil)
        try await repos.removeOrphanedReviewCandidates()
        #expect(repos.pendingReviewCandidateCount() == 0)
        #expect(try repos.context.fetchCount(FetchDescriptor<ReviewCandidateRecord>()) == 0)
    }

    @Test @MainActor func ownerResolutionUsesLiveIDsAndRepairPreservesValidCorrections() async throws {
        let (repos, _) = try library(imageCount: 30)
        let rows = try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>())
        let kept = try #require(try repos.reviewItems(for: rows).first)
        _ = repos.commitCellEdit(cells: nil,
                                corrections: [CorrectionSpec(kind: "accept", cell: kept.cell)],
                                detection: kept.detection, image: kept.image)
        // Missing relationship links do not invalidate live scalar owners.
        kept.candidate.image = nil
        kept.candidate.detection = nil
        for row in rows where row.id != kept.id { row.imageId = UUID() }
        try repos.context.save()
        try await repos.removeOrphanedReviewCandidates()
        let remaining = try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>())
        #expect(remaining.map(\.id) == [kept.id])
        #expect(remaining.first?.triaged == true)
        #expect(try repos.reviewItems(for: remaining).first?.image.id == kept.image.id)
        #expect(kept.detection.corrections.count == 1)
        #expect(kept.detection.cells.count == 4)
    }

    @Test @MainActor func resetClearsReviewIndexAndEmptyFilenamesDoNotBypassDeletion() throws {
        let (repos, images) = try library(imageCount: 3)
        let first = try #require(images.first)
        first.fileName = ""
        repos.deleteImage(first)
        #expect(repos.pendingReviewCandidateCount() == 8)
        let batch = try #require(images.last?.batch)
        for image in batch.images { image.fileName = "" }
        repos.deleteBatch(batch)
        #expect(repos.pendingReviewCandidateCount() == 0)

        _ = try library(imageCount: 2, repository: repos)
        // Exercise the exact database operation used by Reset without touching
        // FileStore.shared or any real image/thumbnail directories.
        try repos.deleteAllLibraryRecords()
        #expect(repos.pendingReviewCandidateCount() == 0)
        #expect(try repos.context.fetchCount(FetchDescriptor<ReviewCandidateRecord>()) == 0)
        #expect(repos.allBatches().isEmpty)
        #expect(!repos.calibrationPresets().isEmpty)
    }

    @Test @MainActor func submicronDiameterEditorIncludesTheCellWithoutInvertingBounds() throws {
        let (repos, images) = try library(imageCount: 1)
        let image = try #require(images.first)
        repos.saveDetection([DetectedCell(cx: 10, cy: 10, diameter: 0.2,
                                         diameterPx: 0.4, confidence: 0.2)],
                            detectorId: "test", for: image)
        let session = ReviewQueueSession()
        session.reload(using: repos)
        let item = try #require(session.current)
        #expect(item.diameterEditRange.contains(0.2))
        #expect(item.diameterEditRange.lowerBound < item.diameterEditRange.upperBound)
    }

    @Test @MainActor func sqliteReviewPagingAndResetUseThePersistentStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Repositories(inMemory: true).container.schema
        let config = ModelConfiguration("ReviewRegression", schema: schema,
                                        url: directory.appendingPathComponent("store.sqlite"))
        let container = try ModelContainer(for: schema, configurations: [config])
        let (repos, _) = try library(imageCount: 30, repository: Repositories(container: container))
        let session = ReviewQueueSession()
        session.reload(using: repos)
        var seen = Set<UUID>()
        while let item = session.current {
            guard seen.insert(item.id).inserted else {
                Issue.record("SQLite queue repeated a candidate")
                break
            }
            session.skip(using: repos)
            if seen.count > 120 { Issue.record("SQLite queue looped"); break }
        }
        #expect(seen.count == 120)
        try repos.deleteAllLibraryRecords()
        try await repos.rebuildPerformanceIndexes()
        session.reload(using: repos)
        #expect(session.current == nil)
        #expect(repos.pendingReviewCandidateCount() == 0)
    }

    @Test @MainActor func invalidReviewMeasurementsCannotTrapPresentation() throws {
        let (repos, images) = try library(imageCount: 1)
        let image = try #require(images.first)
        let detection = try #require(image.detection)
        let row = try #require(try repos.pendingReviewCandidates(limit: 1).first)
        // Inspect in memory; non-finite values must never be saved to SQLite.
        row.confidence = .infinity
        row.cx = .nan
        row.diameter = -1
        let invalid = try #require(ReviewItem(row, image: image, detection: detection))
        #expect(invalid.confidenceFraction == nil)
        #expect(invalid.confidenceLabel == "Invalid confidence")
        #expect(!invalid.hasValidGeometry)
        #expect(invalid.diameterEditRange.contains(1))
        row.confidence = Double.greatestFiniteMagnitude
        let extreme = try #require(ReviewItem(row, image: image, detection: detection))
        #expect(extreme.confidenceLabel == "100%")
        repos.context.rollback()
    }

    @Test @MainActor func failedEncodingPreservesCellsAndPendingReview() throws {
        let (repos, _) = try library(imageCount: 1)
        let item = try #require(try repos.reviewItems(for: repos.pendingReviewCandidates(limit: 1)).first)
        let original = item.detection.cellsData
        let invalid = DetectionRecord.CellsStorageSnapshot(data: Data(), minimumConfidence: 0, count: 0)
        #expect(throws: (any Error).self) {
            try repos.commitReviewCellEdit(storage: invalid,
                corrections: [CorrectionSpec(kind: "remove", cell: item.cell)],
                detection: item.detection, image: item.image)
        }
        #expect(item.detection.cellsData == original)
        #expect(item.detection.corrections.isEmpty)
        #expect(!item.candidate.triaged)
        #expect(repos.pendingReviewCandidateCount() == 4)
    }

    @Test @MainActor func readOnlyStoreCannotReportASuccessfulReviewDecision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Repositories(inMemory: true).container.schema
        let url = directory.appendingPathComponent("store.sqlite")
        do {
            let config = ModelConfiguration("ReviewSaveFailure", schema: schema, url: url)
            let container = try ModelContainer(for: schema, configurations: [config])
            _ = try library(imageCount: 1, repository: Repositories(container: container))
        }
        let config = ModelConfiguration("ReviewSaveFailure", schema: schema, url: url, allowsSave: false)
        let container = try ModelContainer(for: schema, configurations: [config])
        let repos = Repositories(container: container)
        let item = try #require(try repos.reviewItems(for: repos.pendingReviewCandidates(limit: 1)).first)
        let original = item.detection.cellsData
        #expect(throws: (any Error).self) {
            try repos.commitReviewCellEdit(storage: nil,
                corrections: [CorrectionSpec(kind: "accept", cell: item.cell)],
                detection: item.detection, image: item.image)
        }
        #expect(item.detection.cellsData == original)
        #expect(!item.candidate.triaged)
        #expect(try repos.context.fetchCount(FetchDescriptor<CorrectionRecord>()) == 0)
        #expect(repos.pendingReviewCandidateCount() == 4)
    }

    @Test @MainActor func unreadableLegacyPayloadDoesNotEraseTheExistingIndex() async throws {
        let (repos, images) = try library(imageCount: 1)
        let detection = try #require(images.first?.detection)
        let damaged = Data("{truncated".utf8)
        detection.cellsData = damaged
        detection.cellsRevision &+= 1
        detection.reviewIndexVersion = 0
        try repos.context.save()
        // Exercise the old accessor's empty-cache sentinel as well.
        #expect(detection.cells.isEmpty)
        do {
            try await repos.rebuildPerformanceIndexes()
            Issue.record("Unreadable measurements must fail index repair")
        } catch {
            #expect(detection.cellsData == damaged)
            #expect(detection.reviewIndexVersion == 0)
            #expect(detection.cellCountSummary == 4)
            #expect(repos.pendingReviewCandidateCount() == 4)
        }
    }

    @Test @MainActor func reviewReadsWaitForPendingResultsEdits() async throws {
        let (repos, images) = try library(imageCount: 1)
        let state = AppState(repos: repos)
        let image = try #require(images.first)
        let detection = try #require(image.detection)
        var edited = detection.cells
        let removed = edited.removeFirst()
        state.scheduleCellEdit(cells: edited,
            corrections: [CorrectionSpec(kind: "remove", cell: removed)], detection: detection, image: image)

        let reviewCells = try await state.loadReviewCells(for: detection)
        #expect(reviewCells.count == 3)
        #expect(!reviewCells.contains { $0.id == removed.id })
        #expect(repos.pendingReviewCandidateCount() == 3)
        #expect(detection.corrections.count == 1)
    }

    @Test @MainActor func delayedResultsEditCannotOverwriteANewerAnalysis() async throws {
        let (repos, images) = try library(imageCount: 1)
        let state = AppState(repos: repos)
        let image = try #require(images.first)
        let detection = try #require(image.detection)
        var olderEdit = detection.cells
        let removed = olderEdit.removeFirst()
        state.scheduleCellEdit(cells: olderEdit,
            corrections: [CorrectionSpec(kind: "remove", cell: removed)], detection: detection, image: image)
        var newerCells = detection.cells
        newerCells[0].diameter = 11
        newerCells[0].diameterPx = 22
        detection.cells = newerCells
        try repos.context.save()

        try await state.finishPendingCellEdits(for: detection)
        #expect(detection.cells.count == 4)
        #expect(detection.cells.first?.diameter == 11)
        #expect(detection.corrections.isEmpty)
    }

    @Test @MainActor func recalibrationRefreshesReviewGeometryWithoutLosingTriage() async throws {
        let (repos, images) = try library(imageCount: 1)
        let state = AppState(repos: repos)
        let image = try #require(images.first)
        let batch = try #require(image.batch)
        let detection = try #require(image.detection)
        let rows = try repos.pendingReviewCandidates()
        let item = try #require(try repos.reviewItems(for: rows).first)
        _ = try repos.commitReviewCellEdit(storage: nil,
            corrections: [CorrectionSpec(kind: "accept", cell: item.cell)], detection: detection, image: image)

        try await state.recalibrateBatch(batch, pxPerUm: 4, source: "manual")
        #expect(!state.isRecalibrating)
        #expect(!item.hasCurrentCalibration)
        #expect(rows.allSatisfy { $0.diameter == 4 && $0.diameterPx == 16 })
        #expect(item.candidate.triaged)
        #expect(repos.pendingReviewCandidateCount() == 3)
        #expect(detection.corrections.count == 1)
    }

    @Test @MainActor func reviewPreviewsKeepRawCoordinatesAndRecoverMissingThumbnails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try #require(CGContext(data: nil, width: 320, height: 80, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let source = directory.appendingPathComponent("rotated.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(
            source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                                  [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let preview = try #require(ImageLoader.cachedReviewPreview(at: source, maxPixelSize: 160))
        #expect(preview.size.width == 160 && preview.size.height == 40)
        let smaller = try #require(ImageLoader.cachedReviewPreview(at: source, maxPixelSize: 64))
        #expect(smaller.size.width == 64 && smaller.size.height == 16)

        for name in ["missing.jpg", "damaged.jpg"] {
            let thumbnail = directory.appendingPathComponent(name)
            if name == "damaged.jpg" { try Data("not an image".utf8).write(to: thumbnail) }
            let recovered = try #require(ImageLoader.cachedThumbnail(at: thumbnail, fallbackURL: source))
            #expect(recovered.size.width <= 256 && recovered.size.height <= 256)
            #expect(recovered.size.width > recovered.size.height)
        }
    }

    @Test @MainActor func panoramicImagesStillProduceANonzeroThumbnail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(data: nil, width: 2048, height: 1, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        #expect(ImageLoader.writeThumbnail(try #require(context.makeImage()), to: url))
        #expect(ImageLoader.pixelSize(at: url) == CGSize(width: 256, height: 1))
    }

    @Test @MainActor func failedDelayedEditCannotCorruptTheNextReviewSession() async throws {
        let (repos, images) = try library(imageCount: 1)
        let state = AppState(repos: repos)
        let image = try #require(images.first)
        let detection = try #require(image.detection)
        let saved = detection.cellsData
        var invalidCells = detection.cells
        invalidCells[0].diameter = .infinity
        state.scheduleCellEdit(cells: invalidCells,
            corrections: [CorrectionSpec(kind: "resize", cell: invalidCells[0])],
            detection: detection, image: image)

        try await state.finishPendingCellEdits(for: detection)
        #expect(detection.cellsData == saved)
        #expect(detection.corrections.isEmpty)
        #expect(repos.pendingReviewCandidateCount() == 4)
        #expect(try await state.loadReviewCells(for: detection).count == 4)
    }
}
