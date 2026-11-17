import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import CellCounting

/// Saved mask versions (`SegmentationVariantRecord`): compressed storage,
/// saving without re-encoding, de-duplication, swap-on-use, the per-image
/// limit and the background compaction. Every test uses an in-memory store
/// and sets the per-image limit explicitly, so no preference is read.
@Suite(.serialized) @MainActor
struct MaskVariantStorageTests {
    private func cells(_ count: Int, offset: Double = 0, confidence: Double = 0.9) -> [DetectedCell] {
        (0..<count).map { index in
            let x = offset + Double(index) * 20
            let contour = (0..<16).map { point in
                CGPoint(x: x + 5 * cos(Double(point) / 2.5), y: 30 + 5 * sin(Double(point) / 2.5))
            }
            return DetectedCell(cx: x, cy: 30, diameter: 5, diameterPx: 10,
                                confidence: confidence - Double(index % 3) * 0.2,
                                areaMicrons2: 19.6, perimeterMicrons: 15.7,
                                centroidUmX: x / 2, centroidUmY: 15, contourPx: contour)
        }
    }

    private func json(_ cells: [DetectedCell]) -> Data {
        DetectionRecord.encodePlainCellsJSON(cells)
    }

    private func mean(_ cells: [DetectedCell]) -> Double {
        cells.reduce(0) { $0 + $1.confidence } / Double(cells.count)
    }

    private func library(limit: Int = 5) -> (Repositories, BatchRecord, ImageRecord) {
        let repos = Repositories(inMemory: true)
        repos.maskVersionsKept = { limit }
        let batch = repos.createBatch(displayName: "Versions", modelId: "cp-cyto3", pxPerUm: 2,
                                      thresholds: [20, 30])
        let image = ImageRecord(fileName: "field.tif", originalPath: "/field.tif", widthPx: 400, heightPx: 80)
        repos.context.insert(image)
        repos.attach(image: image, to: batch)
        return (repos, batch, image)
    }

    private func variants(_ repos: Repositories, _ image: ImageRecord) throws -> [SegmentationVariantRecord] {
        let imageId = image.id
        return try repos.context.fetch(FetchDescriptor<SegmentationVariantRecord>(
            predicate: #Predicate { $0.imageId == imageId },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    // MARK: - Codec

    @Test func codecRoundTripsAndPassesLegacyJSONThrough() throws {
        let plain = json(cells(40))
        #expect(plain.first == UInt8(ascii: "["))
        #expect(!CellsBlobCodec.isCompressed(plain))
        #expect(CellsBlobCodec.storageFormat(of: plain) == CellsBlobCodec.plainJSONFormat)

        let stored = CellsBlobCodec.compress(plain)
        #expect(stored.prefix(4) == Data("CCZ1".utf8))
        #expect(CellsBlobCodec.isCompressed(stored))
        #expect(CellsBlobCodec.storageFormat(of: stored) == CellsBlobCodec.compressedFormat)
        #expect(stored.count < plain.count)
        #expect(try CellsBlobCodec.plainJSON(stored) == plain)
        // Legacy blobs come back unchanged; compressing twice changes nothing.
        #expect(try CellsBlobCodec.plainJSON(plain) == plain)
        #expect(CellsBlobCodec.compress(stored) == stored)
        #expect(CellsBlobCodec.compress(Data()) == Data())

        var damaged = Data("CCZ1".utf8)
        damaged.append(contentsOf: [1, 2, 3, 4, 5])
        #expect(throws: (any Error).self) { try CellsBlobCodec.plainJSON(damaged) }
        #expect(CellsBlobCodec.sha256Hex(plain).count == 64)
        #expect(CellsBlobCodec.sha256Hex(plain) == CellsBlobCodec.sha256Hex(try CellsBlobCodec.plainJSON(stored)))
    }

    @Test func cellDecodersReadPlainAndCompressedBlobs() throws {
        let (repos, _, image) = library()
        let original = cells(25)
        let plain = json(original)
        let stored = CellsBlobCodec.compress(plain)
        #expect(DetectionRecord.decodeCellsData(plain) == original)
        #expect(DetectionRecord.decodeCellsData(stored) == original)
        #expect(try DetectionRecord.decodeCellsDataForReview(stored) == original)

        let variant = SegmentationVariantRecord(image: image, detectorId: "test", label: "Compressed",
                                                plainJSON: stored, cellCount: original.count,
                                                meanConfidence: -1, contentHash: nil)
        repos.context.insert(variant)
        try repos.context.save()
        #expect(variant.storageFormat == CellsBlobCodec.compressedFormat)
        #expect(variant.cells == original)
    }

    // MARK: - Saving

    @Test func rerunStoresThePreviousDetectionBytesAsTheyAre() throws {
        let (repos, _, image) = library()
        let first = cells(12)
        repos.saveDetection(first, detectorId: "Cellpose/cp-cyto3", for: image)
        let detection = try #require(image.detection)
        // Same cells, different bytes: a re-encode would drop the extra space.
        // Stored as plain JSON, like a detection saved before compression.
        let plain = try CellsBlobCodec.plainJSON(detection.cellsData)
        let spaced = Data(("[ " + String(decoding: plain.dropFirst(), as: UTF8.self)).utf8)
        detection.cellsData = spaced
        detection.cellsRevision &+= 1
        try repos.context.save()
        #expect(DetectionRecord.decodeCellsData(spaced) == first)

        repos.saveDetection(cells(5, offset: 300), detectorId: "Classical/threshold", for: image)
        let saved = try #require(try variants(repos, image).first)
        #expect(try variants(repos, image).count == 1)
        #expect(saved.cellsData == spaced)
        #expect(saved.storageFormat == CellsBlobCodec.plainJSONFormat)
        #expect(saved.contentHash == CellsBlobCodec.sha256Hex(spaced))
        #expect(saved.cellCount == 12)
        #expect(saved.detectorId == "Cellpose/cp-cyto3")
        #expect(saved.label == "Before Classical/threshold")
        // The old cells were not decoded for this save, so the mean is pending.
        #expect(saved.meanConfidence == -1)
        #expect(saved.cells == first)
    }

    @Test func rerunUsesAlreadyDecodedCellsForTheMeanConfidence() throws {
        let (repos, _, image) = library()
        let first = cells(9)
        repos.saveDetection(first, detectorId: "A", for: image)
        let detection = try #require(image.detection)
        detection.cacheDecodedCells(first, revision: detection.cellsRevision)
        let bytes = detection.cellsData
        repos.saveDetection(cells(3, offset: 300), detectorId: "B", for: image)
        let saved = try #require(try variants(repos, image).first)
        #expect(saved.cellsData == bytes)
        #expect(abs(saved.meanConfidence - mean(first)) < 1e-12)
    }

    @Test func identicalContentIsSavedOnlyOnce() throws {
        let (repos, _, image) = library()
        let content = cells(7)
        let first = repos.saveSegmentationVariant(image: image, detectorId: "A", label: "First", cells: content)
        let firstDate = first.createdAt
        let again = repos.saveSegmentationVariant(image: image, detectorId: "B", label: "Second", cells: content)
        #expect(again.id == first.id)
        #expect(again.label == "First")
        #expect(again.createdAt > firstDate)
        #expect(try variants(repos, image).count == 1)

        // A re-run whose previous mask has the same content reuses it too.
        repos.saveDetection(content, detectorId: "A", for: image)
        repos.saveDetection(cells(2, offset: 300), detectorId: "C", for: image)
        let all = try variants(repos, image)
        #expect(all.count == 1)
        #expect(all.first?.id == first.id && all.first?.label == "First")

        // Different content is a new version.
        repos.saveSegmentationVariant(image: image, detectorId: "D", label: "Other", cells: cells(7, offset: 1))
        #expect(try variants(repos, image).count == 2)
    }

    // MARK: - Use = swap

    @Test func usingAVersionSwapsItWithTheLiveMask() throws {
        let (repos, _, image) = library()
        let a = cells(8), b = cells(4, offset: 200)
        repos.saveDetection(a, detectorId: "Cellpose/cp-cyto3", for: image)
        let aBytes = try #require(image.detection).cellsData
        repos.saveDetection(b, detectorId: "Classical/threshold", for: image)
        let bBytes = try #require(image.detection).cellsData
        let saved = try #require(try variants(repos, image).first)
        let savedID = saved.id
        #expect(saved.cellsData == aBytes)

        #expect(repos.applySegmentationVariant(saved, to: image) != nil)
        let detection = try #require(image.detection)
        #expect(detection.cells == a)
        // Same scale: the version's own bytes go live, not a re-encode.
        #expect(detection.cellsData == aBytes)
        #expect(detection.detectorId == "Cellpose/cp-cyto3")
        #expect(repos.segmentationVariant(id: savedID) == nil)
        let afterFirstUse = try variants(repos, image)
        #expect(afterFirstUse.count == 1)
        #expect(afterFirstUse.first?.cellsData == bBytes)
        #expect(afterFirstUse.first?.label == "Before applying Before Classical/threshold")

        // Switching back and forth keeps exactly one saved version.
        for _ in 0..<3 {
            let other = try #require(try variants(repos, image).first)
            #expect(repos.applySegmentationVariant(other, to: image) != nil)
            #expect(try variants(repos, image).count == 1)
        }
        #expect(image.detection?.cellsData == bBytes)
        #expect(try variants(repos, image).first?.cellsData == aBytes)
    }

    @Test func anUnreadableVersionIsNeitherUsedNorRemoved() throws {
        let (repos, _, image) = library()
        repos.saveDetection(cells(6), detectorId: "A", for: image)
        let liveBytes = try #require(image.detection).cellsData
        var damaged = Data("CCZ1".utf8)
        damaged.append(contentsOf: [9, 9, 9])
        let broken = SegmentationVariantRecord(image: image, detectorId: "B", label: "Broken",
                                               plainJSON: damaged, cellCount: 3,
                                               meanConfidence: -1, contentHash: nil)
        repos.context.insert(broken)
        try repos.context.save()
        #expect(repos.applySegmentationVariant(broken, to: image) == nil)
        #expect(image.detection?.cellsData == liveBytes)
        #expect(try variants(repos, image).count == 1)
    }

    // MARK: - Per-image limit

    @Test func limitKeepsTheNewestVersionsAndZeroKeepsAll() async throws {
        var limit = 3
        let (repos, batch, image) = library()
        repos.maskVersionsKept = { limit }
        let other = ImageRecord(fileName: "other.tif", originalPath: "/other.tif", widthPx: 400, heightPx: 80)
        repos.context.insert(other)
        repos.attach(image: other, to: batch)
        repos.saveDetection(cells(5, offset: 900), detectorId: "Live", for: image)
        let live = try #require(image.detection)
        let liveID = live.id, liveBytes = live.cellsData

        let past = Date().addingTimeInterval(-1_000)
        for index in 0..<6 {
            let saved = repos.saveSegmentationVariant(image: image, detectorId: "A", label: "v\(index)",
                                                      cells: cells(3, offset: Double(index)))
            saved.createdAt = past.addingTimeInterval(Double(index))
        }
        try repos.context.save()
        #expect(try variants(repos, image).map(\.label) == ["v5", "v4", "v3"])
        for index in 0..<2 {
            repos.saveSegmentationVariant(image: other, detectorId: "A", label: "o\(index)",
                                          cells: cells(3, offset: Double(index)))
        }
        #expect(try variants(repos, other).count == 2)
        #expect(try variants(repos, image).count == 3)
        #expect(image.detection?.id == liveID && image.detection?.cellsData == liveBytes)

        limit = 0
        for index in 6..<10 {
            repos.saveSegmentationVariant(image: image, detectorId: "A", label: "v\(index)",
                                          cells: cells(3, offset: Double(index)))
        }
        #expect(try variants(repos, image).count == 7)

        // Settings → "Remove older versions now" with a limit of 3.
        #expect(try repos.excessSegmentationVariantIDs(keeping: 3).count == 4)
        #expect(try repos.excessSegmentationVariantIDs(keeping: 0).isEmpty)
        let removed = try await repos.removeExcessSegmentationVariants(keeping: 3, chunkSize: 3)
        #expect(removed == 4)
        #expect(try variants(repos, image).map(\.label) == ["v9", "v8", "v7"])
        #expect(try variants(repos, other).count == 2)
        #expect(image.detection?.id == liveID && image.detection?.cellsData == liveBytes)
    }

    @Test func listingSkipsBlobsButComparingCanStillReadThem() throws {
        let (repos, _, image) = library()
        let content = cells(5)
        let saved = repos.saveSegmentationVariant(image: image, detectorId: "A", label: "Listed", cells: content)
        let summaries = repos.segmentationVariantSummaries(for: image.id)
        #expect(summaries.map(\.id) == [saved.id])
        #expect(summaries.first?.cellCount == 5)
        #expect(summaries.first?.isMeanConfidencePending == false)
        #expect(repos.segmentationVariant(id: saved.id)?.cells == content)
    }

    // MARK: - Background compaction

    @Test func compactionCompressesFillsMissingFieldsAndIsIdempotent() async throws {
        let (repos, _, image) = library(limit: 0)
        let newCells = cells(30)
        let newJSON = json(newCells)
        let pending = repos.saveSegmentationVariant(image: image, detectorId: "A", label: "Pending",
                                                    plainJSON: newJSON, cellCount: newCells.count,
                                                    meanConfidence: nil)
        #expect(pending.meanConfidence == -1)
        #expect(pending.contentHash == CellsBlobCodec.sha256Hex(newJSON))

        // A row as written before hashes and compression existed.
        let legacyCells = cells(20, offset: 500, confidence: 0.7)
        let legacy = SegmentationVariantRecord(image: image, detectorId: "B", label: "Legacy", cells: legacyCells)
        legacy.contentHash = nil
        repos.context.insert(legacy)

        var damaged = Data("CCZ1".utf8)
        damaged.append(contentsOf: [7, 7, 7])
        let broken = SegmentationVariantRecord(image: image, detectorId: "C", label: "Broken",
                                               plainJSON: damaged, cellCount: 2,
                                               meanConfidence: -1, contentHash: nil)
        repos.context.insert(broken)
        try repos.context.save()
        let legacyJSON = legacy.cellsData
        let legacyMean = legacy.meanConfidence

        let updated = try await repos.compactSegmentationVariants(chunkSize: 2)
        #expect(updated == 2)

        #expect(pending.storageFormat == CellsBlobCodec.compressedFormat)
        #expect(CellsBlobCodec.isCompressed(pending.cellsData))
        #expect(pending.cellsData.count < newJSON.count)
        #expect(try CellsBlobCodec.plainJSON(pending.cellsData) == newJSON)
        #expect(pending.cells == newCells)
        #expect(abs(pending.meanConfidence - mean(newCells)) < 1e-12)
        #expect(pending.contentHash == CellsBlobCodec.sha256Hex(newJSON))

        #expect(legacy.storageFormat == CellsBlobCodec.compressedFormat)
        #expect(try CellsBlobCodec.plainJSON(legacy.cellsData) == legacyJSON)
        #expect(legacy.cells == legacyCells)
        #expect(legacy.meanConfidence == legacyMean)
        #expect(legacy.contentHash == CellsBlobCodec.sha256Hex(legacyJSON))

        // Unreadable rows are left exactly as they were.
        #expect(broken.cellsData == damaged)
        #expect(broken.meanConfidence == -1 && broken.contentHash == nil)

        let compressed = pending.cellsData
        #expect(try await repos.compactSegmentationVariants(chunkSize: 2) == 0)
        #expect(pending.cellsData == compressed)
        #expect(pending.cells == newCells)

        // A compressed version still de-duplicates and goes live as stored.
        repos.saveDetection(cells(3, offset: 800), detectorId: "Live", for: image)
        #expect(repos.saveSegmentationVariant(image: image, detectorId: "A", label: "Again",
                                              cells: newCells).id == pending.id)
        #expect(repos.applySegmentationVariant(pending, to: image) != nil)
        let detection = try #require(image.detection)
        #expect(detection.cellsData == compressed)
        #expect(try CellsBlobCodec.plainJSON(detection.cellsData) == newJSON)
        #expect(detection.cellsContentHash == CellsBlobCodec.sha256Hex(newJSON))
        #expect(detection.cells == newCells)
    }

    // MARK: - Exports and archives

    @Test func workbenchExportReceivesPlainJSON() {
        let plain = json(cells(10))
        #expect(NativeLibraryArchiveExporter.exportedCellsData(CellsBlobCodec.compress(plain)) == plain)
        #expect(NativeLibraryArchiveExporter.exportedCellsData(plain) == plain)
        var damaged = Data("CCZ1".utf8)
        damaged.append(contentsOf: [1, 2])
        #expect(NativeLibraryArchiveExporter.exportedCellsData(damaged) == damaged)
    }

    @Test func archiveSnapshotCopiesVersionStorageFields() async throws {
        let (repos, batch, image) = library(limit: 0)
        repos.saveDetection(cells(6), detectorId: "Live", for: image)
        let compactCells = cells(8, offset: 100)
        let compact = repos.saveSegmentationVariant(image: image, detectorId: "A", label: "Compact",
                                                    cells: compactCells)
        _ = try await repos.compactSegmentationVariants()
        #expect(compact.storageFormat == CellsBlobCodec.compressedFormat)
        // A row as written before hashes and compression existed.
        let legacy = SegmentationVariantRecord(image: image, detectorId: "B", label: "Legacy",
                                               cells: cells(4, offset: 300))
        legacy.contentHash = nil
        repos.context.insert(legacy)
        try repos.context.save()

        let snapshot = try await BatchRecordsSnapshotter.snapshot(batch: batch, in: repos.context)
        let rows = try #require(snapshot.images.first?.variants)
        let compactRow = try #require(rows.first { $0.id == compact.id })
        let legacyRow = try #require(rows.first { $0.id == legacy.id })
        #expect(compactRow.storageFormat == CellsBlobCodec.compressedFormat)
        #expect(compactRow.contentHash == compact.contentHash && compactRow.contentHash != nil)
        #expect(compactRow.cellsData == compact.cellsData)
        // The shape an archive from before these fields opens with.
        #expect(legacyRow.storageFormat == CellsBlobCodec.plainJSONFormat && legacyRow.contentHash == nil)

        let target = Repositories(inMemory: true)
        try await BatchRecordsSnapshotter.insert(snapshot, into: target.context, saveEveryChunk: true)
        let batchId = batch.id
        let copied = try #require(try target.context.fetch(FetchDescriptor<BatchRecord>(
            predicate: #Predicate { $0.id == batchId })).first)
        let reread = try await BatchRecordsSnapshotter.snapshot(batch: copied, in: target.context)
        #expect(reread.images == snapshot.images)
        let copiedCompact = try #require(target.segmentationVariant(id: compact.id))
        #expect(copiedCompact.storageFormat == CellsBlobCodec.compressedFormat)
        #expect(copiedCompact.cells == compactCells)
    }
}
