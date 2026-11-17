import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import CellCounting

/// Detection cells (`DetectionRecord.cellsData`) live in their own
/// `StoredCellsRecord` row, compressed. Covers new saves, the off-main save
/// path, edits, the background move of rows written before the split, mask
/// versions made from compressed detections, and archive copies. Every test
/// uses an in-memory store except the size report, which needs a file.
@Suite(.serialized) @MainActor
struct DetectionCellStorageTests {
    private func cells(_ count: Int, offset: Double = 0, confidence: Double = 0.9) -> [DetectedCell] {
        (0..<count).map { index in
            let x = offset + Double(index) * 20
            let contour = (0..<16).map { point in
                CGPoint(x: x + 5 * cos(Double(point) / 2.5), y: 30 + 5 * sin(Double(point) / 2.5))
            }
            return DetectedCell(cx: x, cy: 30, diameter: 5, diameterPx: 10,
                                confidence: confidence - Double(index % 4) * 0.15,
                                areaMicrons2: 19.6, perimeterMicrons: 15.7,
                                centroidUmX: x / 2, centroidUmY: 15, contourPx: contour)
        }
    }

    private func library(images count: Int = 1,
                         repos existing: Repositories? = nil) -> (Repositories, BatchRecord, [ImageRecord]) {
        let repos = existing ?? Repositories(inMemory: true)
        repos.maskVersionsKept = { 0 }
        let batch = repos.createBatch(displayName: "Storage", modelId: "cp-cyto3", pxPerUm: 2,
                                      thresholds: [20, 30])
        let images = (0..<count).map { index in
            let image = ImageRecord(fileName: "field-\(index).tif", originalPath: "/field-\(index).tif",
                                    widthPx: 400, heightPx: 80)
            repos.context.insert(image)
            repos.attach(image: image, to: batch)
            return image
        }
        return (repos, batch, images)
    }

    /// Turns a saved detection into a row as written before the split: its
    /// cells inline in the detection row and no separate row.
    private func makeLegacy(_ detection: DetectionRecord, inline bytes: Data, in context: ModelContext) throws {
        if let storage = detection.cellsStorage {
            detection.cellsStorage = nil
            context.delete(storage)
        }
        detection.legacyCellsData = bytes
        try context.save()
    }

    private func storedRowCount(_ repos: Repositories) throws -> Int {
        try repos.context.fetchCount(FetchDescriptor<StoredCellsRecord>())
    }

    // MARK: - New detections

    @Test func newDetectionsAreStoredInTheirOwnRowCompressed() throws {
        let (repos, batch, images) = library()
        let image = try #require(images.first)
        let original = cells(30)
        repos.saveDetection(original, detectorId: "Cellpose/cp-cyto3", for: image)
        let detection = try #require(image.detection)
        let storage = try #require(detection.cellsStorage)
        let json = DetectionRecord.encodePlainCellsJSON(original)

        #expect(detection.legacyCellsData.isEmpty)
        #expect(storage.data == detection.cellsData)
        #expect(CellsBlobCodec.isCompressed(detection.cellsData))
        #expect(storage.storageFormat == CellsBlobCodec.compressedFormat)
        #expect(detection.cellsData.count < json.count)
        #expect(try CellsBlobCodec.plainJSON(detection.cellsData) == json)
        #expect(detection.cellsContentHash == CellsBlobCodec.sha256Hex(json))
        #expect(try DetectionRecord.decodeCellsDataForReview(detection.cellsData) == original)
        #expect(detection.cellsRevision == 0 && detection.summaryCellCount == 30)
        #expect(batch.cellCountSummary == 30)
        #expect(try storedRowCount(repos) == 1)

        // A re-run replaces the detection; its cells row goes with it.
        repos.saveDetection(cells(4, offset: 900), detectorId: "Classical/threshold", for: image)
        #expect(try storedRowCount(repos) == 1)
        #expect(try repos.context.fetchCount(FetchDescriptor<DetectionRecord>()) == 1)
        #expect(image.detection?.cellsStorage != nil)

        // Deleting the image deletes the detection and its cells row.
        try repos.deleteImage(image)
        #expect(try storedRowCount(repos) == 0)
    }

    @Test func snapshotSaveEqualsCellsSave() throws {
        let (repos, batch, images) = library(images: 2)
        let original = cells(25, confidence: 0.8)
        var settings = AnalysisRunSettings()
        settings.modelId = "cp-cyto3"
        let stats = ["focus_score": 0.7]
        repos.saveDetection(original, detectorId: "Cellpose/cp-cyto3", for: images[0],
                            imageStats: stats, runSettings: settings)
        let snapshot = DetectionRecord.makeStorageSnapshot(original)
        repos.saveDetection(snapshot: snapshot, cells: original, detectorId: "Cellpose/cp-cyto3",
                            for: images[1], imageStats: stats, runSettings: settings)
        let a = try #require(images[0].detection), b = try #require(images[1].detection)

        #expect(a.cellsData == b.cellsData)
        #expect(b.cellsData == snapshot.data)
        #expect(a.cellsContentHash == b.cellsContentHash && b.cellsContentHash == snapshot.contentHash)
        #expect(a.minConfidence == b.minConfidence)
        #expect(a.cellCountSummary == b.cellCountSummary)
        #expect(a.cellsRevision == b.cellsRevision)
        #expect(a.reviewPendingCount == b.reviewPendingCount && a.reviewPendingCount > 0)
        #expect(a.reviewIndexVersion == b.reviewIndexVersion)
        #expect(a.imageStatsData == b.imageStatsData)
        #expect(a.runSettings == b.runSettings && b.runSettings == settings)
        #expect(a.detectorId == b.detectorId)
        #expect(a.cells == b.cells && b.cells == original)
        let aID = a.id, bID = b.id
        let aRows = try repos.context.fetchCount(FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { $0.detectionId == aID }))
        let bRows = try repos.context.fetchCount(FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { $0.detectionId == bID }))
        #expect(aRows == bRows && aRows == a.reviewPendingCount)
        #expect(batch.cellCountSummary == 50)
    }

    @Test func editsStayCompressedAndDecodable() throws {
        let (repos, _, images) = library(images: 2)
        let image = images[0]
        let original = cells(12)
        repos.saveDetection(original, detectorId: "A", for: image)
        let detection = try #require(image.detection)
        let storageID = try #require(detection.cellsStorage).id

        var edited = original
        let removed = edited.remove(at: 3)
        let result = try repos.commitReviewCellEdit(
            storage: DetectionRecord.makeStorageSnapshot(edited),
            corrections: [CorrectionSpec(kind: "remove", cell: removed)],
            detection: detection, image: image)
        #expect(result.corrections.count == 1)
        #expect(detection.cellsRevision == 1)
        #expect(CellsBlobCodec.isCompressed(detection.cellsData))
        #expect(try DetectionRecord.decodeCellsDataForReview(detection.cellsData) == edited)
        #expect(detection.cellsContentHash
                == CellsBlobCodec.sha256Hex(DetectionRecord.encodePlainCellsJSON(edited)))
        // The edit rewrites the existing cells row rather than adding one.
        #expect(detection.cellsStorage?.id == storageID)
        #expect(try storedRowCount(repos) == 1)

        // The `cells` setter stores the same compressed form.
        detection.cells = original
        #expect(CellsBlobCodec.isCompressed(detection.cellsData))
        #expect(DetectionRecord.decodeCellsData(detection.cellsData) == original)
        #expect(detection.cellsRevision == 2)

        // Editing a row written before the split moves it in the same change.
        let other = images[1]
        repos.saveDetection(original, detectorId: "B", for: other)
        let legacy = try #require(other.detection)
        try makeLegacy(legacy, inline: DetectionRecord.encodePlainCellsJSON(original), in: repos.context)
        _ = repos.commitCellEdit(storage: DetectionRecord.makeStorageSnapshot(edited),
                                 corrections: [], detection: legacy, image: other)
        #expect(legacy.legacyCellsData.isEmpty)
        #expect(legacy.cellsStorage != nil)
        #expect(CellsBlobCodec.isCompressed(legacy.cellsData))
        #expect(legacy.cells == edited)
    }

    // MARK: - Rows written before the split

    @Test func getterFallsBackToInlineBytesUntilTheRowIsMoved() throws {
        let (repos, _, images) = library()
        let image = try #require(images.first)
        let original = cells(9)
        repos.saveDetection(original, detectorId: "A", for: image)
        let detection = try #require(image.detection)
        let json = DetectionRecord.encodePlainCellsJSON(original)
        try makeLegacy(detection, inline: json, in: repos.context)
        DecodedCellCache.shared.remove(detection.id)

        #expect(detection.cellsStorage == nil)
        #expect(detection.cellsData == json)
        #expect(detection.cellsContentHash == nil)
        #expect(detection.cells == original)
        #expect(try storedRowCount(repos) == 0)

        // Writing through `cellsData` moves the bytes as given.
        detection.cellsData = json
        try repos.context.save()
        #expect(detection.legacyCellsData.isEmpty)
        #expect(detection.cellsStorage?.data == json)
        #expect(detection.cellsStorage?.storageFormat == CellsBlobCodec.plainJSONFormat)
        #expect(try storedRowCount(repos) == 1)
    }

    @Test func legacyRowsMoveCompressedWithIdenticalCellsAndIdempotently() async throws {
        let (repos, _, images) = library(images: 5)
        var expected: [UUID: (json: Data, cells: [DetectedCell], revision: Int)] = [:]
        for (index, image) in images.enumerated() {
            let original = cells(6 + index, offset: Double(index) * 10)
            repos.saveDetection(original, detectorId: "A", for: image)
            let detection = try #require(image.detection)
            let json = DetectionRecord.encodePlainCellsJSON(original)
            try makeLegacy(detection, inline: json, in: repos.context)
            DecodedCellCache.shared.remove(detection.id)
            #expect(DetectionRecord.decodeCellsData(detection.cellsData) == original)
            expected[detection.id] = (json, original, detection.cellsRevision)
        }
        // Unreadable rows are moved exactly as they are, never dropped.
        let truncated = Data("{truncated".utf8)
        var damaged = Data("CCZ1".utf8)
        damaged.append(contentsOf: [7, 7, 7])
        let extra = library(images: 2, repos: repos).2
        repos.saveDetection(cells(2), detectorId: "B", for: extra[0])
        repos.saveDetection(cells(2), detectorId: "B", for: extra[1])
        let truncatedRow = try #require(extra[0].detection)
        let damagedRow = try #require(extra[1].detection)
        try makeLegacy(truncatedRow, inline: truncated, in: repos.context)
        try makeLegacy(damagedRow, inline: damaged, in: repos.context)

        let moved = try await repos.migrateDetectionCellStorage(chunkSize: 2)
        #expect(moved == 7)
        for image in images {
            let detection = try #require(image.detection)
            let want = try #require(expected[detection.id])
            #expect(detection.legacyCellsData.isEmpty)
            #expect(detection.cellsStorage?.storageFormat == CellsBlobCodec.compressedFormat)
            #expect(CellsBlobCodec.isCompressed(detection.cellsData))
            #expect(detection.cellsData.count < want.json.count)
            #expect(try CellsBlobCodec.plainJSON(detection.cellsData) == want.json)
            #expect(detection.cellsContentHash == CellsBlobCodec.sha256Hex(want.json))
            // Content is unchanged, so the revision (and any decoded cache) stays valid.
            #expect(detection.cellsRevision == want.revision)
            #expect(try DetectionRecord.decodeCellsDataForReview(detection.cellsData) == want.cells)
        }
        #expect(truncatedRow.legacyCellsData.isEmpty)
        #expect(try CellsBlobCodec.plainJSON(truncatedRow.cellsData) == truncated)
        #expect(damagedRow.legacyCellsData.isEmpty)
        #expect(damagedRow.cellsData == damaged && damagedRow.cellsContentHash == nil)
        #expect(try storedRowCount(repos) == 7)

        // Running again changes nothing and stops despite the unreadable row.
        let before = images.compactMap { $0.detection?.cellsData }
        #expect(try await repos.migrateDetectionCellStorage(chunkSize: 2) == 0)
        #expect(images.compactMap { $0.detection?.cellsData } == before)
        #expect(damagedRow.cellsData == damaged)
        #expect(try storedRowCount(repos) == 7)
    }

    @Test func plainSeparateRowsAreCompressedAndHashed() async throws {
        let (repos, _, images) = library()
        let image = try #require(images.first)
        let original = cells(14)
        repos.saveDetection(original, detectorId: "A", for: image)
        let detection = try #require(image.detection)
        let json = DetectionRecord.encodePlainCellsJSON(original)
        // As restored from an archive written before compression.
        detection.cellsData = json
        try repos.context.save()
        #expect(detection.cellsContentHash == nil)

        #expect(try await repos.migrateDetectionCellStorage() == 1)
        #expect(CellsBlobCodec.isCompressed(detection.cellsData))
        #expect(try CellsBlobCodec.plainJSON(detection.cellsData) == json)
        #expect(detection.cellsContentHash == CellsBlobCodec.sha256Hex(json))
        #expect(detection.cells == original)
        #expect(try await repos.migrateDetectionCellStorage() == 0)
    }

    @Test func archiveAndRestoreHoldPauseTheMove() async throws {
        let (repos, _, images) = library()
        let image = try #require(images.first)
        repos.saveDetection(cells(5), detectorId: "A", for: image)
        let detection = try #require(image.detection)
        let json = DetectionRecord.encodePlainCellsJSON(cells(5))
        try makeLegacy(detection, inline: json, in: repos.context)

        repos.holdVariantCompaction()
        #expect(try await repos.migrateDetectionCellStorage() == 0)
        #expect(detection.cellsStorage == nil && detection.legacyCellsData == json)
        repos.releaseVariantCompaction()
        #expect(try await repos.migrateDetectionCellStorage() == 1)
        #expect(detection.cellsStorage != nil && detection.legacyCellsData.isEmpty)
    }

    // MARK: - Saved mask versions

    @Test func versionsOfCompressedDetectionsKeepTheirBytesAndDeduplicate() async throws {
        let (repos, _, images) = library()
        let image = try #require(images.first)
        let a = cells(10), b = cells(4, offset: 300), c = cells(3, offset: 600)
        let aJSON = DetectionRecord.encodePlainCellsJSON(a)
        repos.saveDetection(a, detectorId: "A", for: image)
        let aBytes = try #require(image.detection).cellsData
        #expect(CellsBlobCodec.isCompressed(aBytes))

        // The compressed bytes are saved as they are, with the plain-JSON hash.
        repos.saveDetection(b, detectorId: "B", for: image)
        let imageId = image.id
        func versions() throws -> [SegmentationVariantRecord] {
            try repos.context.fetch(FetchDescriptor<SegmentationVariantRecord>(
                predicate: #Predicate { $0.imageId == imageId }))
        }
        let saved = try #require(try versions().first)
        #expect(try versions().count == 1)
        #expect(saved.cellsData == aBytes)
        #expect(saved.storageFormat == CellsBlobCodec.compressedFormat)
        #expect(saved.contentHash == CellsBlobCodec.sha256Hex(aJSON))
        #expect(saved.cells == a)

        // Same content from cells, and from a compressed live mask, is not stored twice.
        #expect(repos.saveSegmentationVariant(image: image, detectorId: "A", label: "Again", cells: a).id == saved.id)
        repos.saveDetection(a, detectorId: "A", for: image)   // b becomes a version
        repos.saveDetection(c, detectorId: "C", for: image)   // a again
        #expect(try versions().count == 2)
        #expect(try versions().filter { $0.contentHash == CellsBlobCodec.sha256Hex(aJSON) }.map(\.id) == [saved.id])

        // A live mask still stored inline as plain JSON (a row written before
        // the split) matches the compressed version of the same content.
        repos.saveDetection(a, detectorId: "A", for: image)   // c becomes a version
        #expect(try versions().count == 3)
        let live = try #require(image.detection)
        try makeLegacy(live, inline: aJSON, in: repos.context)
        repos.saveDetection(b, detectorId: "B", for: image)   // a again, from plain JSON
        #expect(try versions().count == 3)
        #expect(try versions().filter { $0.contentHash == CellsBlobCodec.sha256Hex(aJSON) }.map(\.id) == [saved.id])

        // Compaction has nothing to change in the compressed version.
        _ = try await repos.compactSegmentationVariants()
        #expect(repos.segmentationVariant(id: saved.id)?.cellsData == aBytes)
    }

    // MARK: - Archive copies

    @Test func archiveSnapshotRoundTripKeepsTheCells() async throws {
        let (repos, batch, images) = library(images: 3)
        let originals = [cells(8), cells(5, offset: 200), cells(6, offset: 400)]
        for (image, original) in zip(images, originals) {
            repos.saveDetection(original, detectorId: "A", for: image)
        }
        // One row as written before the split, one stored as plain JSON.
        let legacy = try #require(images[1].detection)
        try makeLegacy(legacy, inline: DetectionRecord.encodePlainCellsJSON(originals[1]), in: repos.context)
        let plain = try #require(images[2].detection)
        plain.cellsData = DetectionRecord.encodePlainCellsJSON(originals[2])
        try repos.context.save()

        let snapshot = try await BatchRecordsSnapshotter.snapshot(batch: batch, in: repos.context)
        let rows = snapshot.images.compactMap(\.detection)
        #expect(rows.count == 3)
        #expect(rows.contains { $0.id == images[0].detection?.id && $0.cellsContentHash != nil })
        #expect(rows.contains { $0.id == legacy.id && $0.cellsData == legacy.legacyCellsData })

        let target = Repositories(inMemory: true)
        try await BatchRecordsSnapshotter.insert(snapshot, into: target.context, saveEveryChunk: true)
        let batchId = batch.id
        let copied = try #require(try target.context.fetch(FetchDescriptor<BatchRecord>(
            predicate: #Predicate { $0.id == batchId })).first)
        let reread = try await BatchRecordsSnapshotter.snapshot(batch: copied, in: target.context)
        #expect(reread.images == snapshot.images)
        #expect(try target.context.fetchCount(FetchDescriptor<StoredCellsRecord>()) == 3)
        for (image, original) in zip(images, originals) {
            let imageId = image.id
            let copy = try #require(try target.context.fetch(FetchDescriptor<ImageRecord>(
                predicate: #Predicate { $0.id == imageId })).first?.detection)
            // Copies always use the separate row, with the exact stored bytes.
            #expect(copy.cellsStorage != nil && copy.legacyCellsData.isEmpty)
            #expect(copy.cellsData == image.detection?.cellsData)
            DecodedCellCache.shared.remove(copy.id)
            #expect(try DetectionRecord.decodeCellsDataForReview(copy.cellsData) == original)
        }
        #expect(BatchArchiveService.storedCellCount(reread) == originals.reduce(0) { $0 + $1.count })
    }

    // MARK: - Size report

    @Test func sizeReportSumsSeparateAndInlineCells() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-cell-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("store.sqlite")
        let schema = Repositories.librarySchema()
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration("CellCounter", schema: schema, url: url)])
        let (repos, _, images) = library(images: 2, repos: Repositories(container: container))
        repos.saveDetection(cells(20), detectorId: "A", for: images[0])
        repos.saveDetection(cells(7), detectorId: "A", for: images[1])
        let legacy = try #require(images[1].detection)
        try makeLegacy(legacy, inline: DetectionRecord.encodePlainCellsJSON(cells(7)), in: repos.context)

        let totals = try #require(LibraryStorageMeasurement.blobTotals(storeURL: url))
        let detections = try repos.context.fetch(FetchDescriptor<DetectionRecord>())
        #expect(totals.detections == 2)
        #expect(totals.detectionBlobBytes == Int64(detections.reduce(0) { $0 + $1.cellsData.count }))
    }
}
