import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import CellCounting

/// Recalibration skips batches already stored at the requested scale, writes
/// the same results as before when the scale changes, and finishes a pass
/// that stopped partway. Background upkeep runs only while the library's
/// upkeep note says there is work, every write that leaves work reports it,
/// and each pass reads every candidate row once.
@Suite(.serialized) @MainActor
struct UpkeepAndRecalibrationTests {
    private typealias Job = BackgroundUpkeepNote.Job

    // MARK: - Fixtures

    /// Cells measured at `pxPerUm`. Every third is uncertain (a review row);
    /// with `unsized`, one has no diameter (its scale cannot be inferred, so
    /// recalibration uses the batch's previous scale) and one has no area.
    private func cells(_ count: Int, offset: Double = 0, pxPerUm: Double = 2,
                       unsized: Bool = false) -> [DetectedCell] {
        (0..<count).map { index in
            let x = offset + Double(index) * 20
            let diameterPx = unsized && index == 1 ? 0 : 8 + Double(index % 5) * 2
            let contour = (0..<10).map { point in
                CGPoint(x: x + 4 * cos(Double(point) / 1.6), y: 30 + 4 * sin(Double(point) / 1.6))
            }
            return DetectedCell(cx: x, cy: 30, diameter: diameterPx / pxPerUm, diameterPx: diameterPx,
                                confidence: index % 3 == 0 ? 0.4 : 0.9,
                                areaMicrons2: unsized && index == 2 ? nil : 12 + Double(index),
                                perimeterMicrons: 9 + Double(index) / 2,
                                centroidUmX: x / pxPerUm, centroidUmY: 30 / pxPerUm, contourPx: contour)
        }
    }

    /// A batch at 2 px/µm whose images are analysed with `fixtures` (nil: an
    /// image without a detection), in that order.
    private func makeBatch(in repos: Repositories, _ fixtures: [[DetectedCell]?]) -> (BatchRecord, [ImageRecord]) {
        repos.maskVersionsKept = { 0 }
        let batch = repos.createBatch(displayName: "Calibration", modelId: "cp-cyto3", pxPerUm: 2,
                                      thresholds: [20, 30])
        var images: [ImageRecord] = []
        for (index, fixture) in fixtures.enumerated() {
            let image = ImageRecord(fileName: "field-\(index).tif", originalPath: "/plate/field-\(index).tif",
                                    widthPx: 400, heightPx: 80)
            image.sourceOrder = index
            repos.context.insert(image)
            repos.attach(image: image, to: batch)
            if let fixture { repos.saveDetection(fixture, detectorId: "test", for: image) }
            images.append(image)
        }
        return (batch, images)
    }

    private struct ReviewRow: Equatable {
        let cellId: UUID
        let diameter: Double
        let diameterPx: Double
        let triaged: Bool
    }

    /// Everything a recalibration writes for one image.
    private struct StoredImage: Equatable {
        let cellsData: Data
        let contentHash: String?
        let metrics: Data?
        let metricsVersion: Int
        let minConfidence: Double
        let count: Int
        let revision: Int
        let review: [ReviewRow]
    }

    private func stored(_ image: ImageRecord, in repos: Repositories) throws -> StoredImage? {
        guard let detection = image.detection else { return nil }
        let detectionID = detection.id
        let rows = try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { $0.detectionId == detectionID }))
            .map { ReviewRow(cellId: $0.cellId, diameter: $0.diameter, diameterPx: $0.diameterPx, triaged: $0.triaged) }
            .sorted { $0.cellId.uuidString < $1.cellId.uuidString }
        return StoredImage(cellsData: detection.cellsData, contentHash: detection.cellsContentHash,
                           metrics: detection.cellMetricsData, metricsVersion: detection.cellMetricsVersion,
                           minConfidence: detection.minConfidence, count: detection.cellCountSummary,
                           revision: detection.cellsRevision, review: rows)
    }

    private func decoded(_ image: ImageRecord) throws -> [DetectedCell] {
        try DetectionRecord.decodeCellsDataForReview(try #require(image.detection).cellsData)
    }

    /// `AppState.recalibrateBatch` before the skip and the chunked saves, for
    /// a batch nobody edits meanwhile: every analysed image rewritten,
    /// whatever the batch's scale, then one save.
    private func previousRecalibration(_ batch: BatchRecord, in repos: Repositories,
                                       pxPerUm scale: Double, source: String) throws {
        let oldScale = batch.pxPerUm
        batch.pxPerUm = scale; batch.pxPerUmSource = source
        for image in batch.images {
            guard let detection = image.detection else { continue }
            let cells = detection.cells
            let snapshot = DetectionRecord.makeStorageSnapshot(
                AppState.calibratedCells(cells, pxPerUm: scale, fallbackScale: oldScale))
            try repos.recalibrateReviewCandidates(for: detection, pxPerUm: scale)
            detection.applyStorageSnapshot(snapshot)
        }
        batch.contentRevision &+= 1
        try repos.context.save()
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpkeepAndRecalibrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func openStore(in folder: URL) throws -> Repositories {
        let schema = Repositories.librarySchema()
        let configuration = ModelConfiguration("CellCounter", schema: schema,
                                               url: folder.appendingPathComponent(LibraryLayout.storeFileName))
        return Repositories(container: try ModelContainer(for: schema, configurations: [configuration]))
    }

    /// Records every job as done, as on a library already upgraded.
    private func completeEveryJob(_ repos: Repositories) async throws {
        _ = try await repos.compactSegmentationVariants()
        _ = try await repos.migrateDetectionCellStorage()
        _ = try await repos.backfillCellMetrics()
        for job in Job.allCases { #expect(!repos.upkeepNote.needsRun(job)) }
    }

    /// Runs the passes the background upkeep would run for reported work.
    private func runReportedUpkeep(_ repos: Repositories) async throws {
        #expect(try await repos.compactReportedSegmentationVariants())
        #expect(try await repos.migrateReportedDetectionCellStorage())
        #expect(try await repos.backfillReportedCellMetrics())
        for job in Job.allCases { #expect(!repos.upkeepNote.needsRun(job)) }
    }

    /// Visits per job, in order.
    private final class Visits {
        var ids: [Job: [UUID]] = [:]
        func record(_ job: Job, _ rows: [UUID]) { ids[job, default: []].append(contentsOf: rows) }
        func reset() { ids = [:] }
    }

    // MARK: - Recalibration

    @Test func unchangedScaleRewritesNothing() async throws {
        let repos = Repositories(inMemory: true)
        let (batch, images) = makeBatch(in: repos, [cells(9), cells(7, offset: 300), nil, cells(5, offset: 600)])
        batch.pxPerUmSource = "manual"
        try repos.context.save()
        let state = AppState(repos: repos)
        let before = try images.map { try stored($0, in: repos) }
        let contentRevision = batch.contentRevision

        let changed = try await state.recalibrateBatchIfNeeded(batch, pxPerUm: 2, source: "manual")
        #expect(!changed)
        #expect(!repos.context.hasChanges)
        #expect(try images.map { try stored($0, in: repos) } == before)
        #expect(batch.contentRevision == contentRevision)
        #expect(!batch.recalibrationPending)

        // Same scale, other source: only the source is stored.
        #expect(try await state.recalibrateBatchIfNeeded(batch, pxPerUm: 2, source: "exif-tiff"))
        #expect(batch.pxPerUmSource == "exif-tiff")
        #expect(!repos.context.hasChanges)
        #expect(try images.map { try stored($0, in: repos) } == before)
        #expect(batch.contentRevision == contentRevision)

        // A pass recorded as stopped partway is completed even at the same scale.
        batch.recalibrationPending = true
        try repos.context.save()
        #expect(try await state.recalibrateBatchIfNeeded(batch, pxPerUm: 2, source: "exif-tiff"))
        #expect(!batch.recalibrationPending)
        let after = try images.map { try stored($0, in: repos) }
        for (old, new) in zip(before, after) {
            #expect(old?.revision.advanced(by: 1) == new?.revision)
        }
    }

    @Test func changedScaleWritesWhatThePreviousAlgorithmWrote() async throws {
        let fixtures: [[DetectedCell]?] = [
            cells(9, unsized: true), cells(6, offset: 200), nil,
            cells(12, offset: 400, unsized: true), cells(4, offset: 700), cells(8, offset: 900),
        ]
        let repos = Repositories(inMemory: true)
        let reference = Repositories(inMemory: true)
        let (batch, images) = makeBatch(in: repos, fixtures)
        let (referenceBatch, referenceImages) = makeBatch(in: reference, fixtures)
        let state = AppState(repos: repos)
        state.recalibrationSaveInterval = 2
        let contentRevision = batch.contentRevision

        #expect(try await state.recalibrateBatchIfNeeded(batch, pxPerUm: 5, source: "manual"))
        try previousRecalibration(referenceBatch, in: reference, pxPerUm: 5, source: "manual")

        #expect(batch.pxPerUm == referenceBatch.pxPerUm)
        #expect(batch.pxPerUmSource == referenceBatch.pxPerUmSource)
        #expect(batch.contentRevision == contentRevision + 1)
        #expect(!batch.recalibrationPending)
        #expect(!repos.context.hasChanges)
        for (image, referenceImage) in zip(images, referenceImages) {
            #expect(image.fileName == referenceImage.fileName)
            let result = try stored(image, in: repos)
            let expected = try stored(referenceImage, in: reference)
            #expect(result == expected, "\(image.fileName)")
            if image.detection != nil {
                #expect(try decoded(image) == decoded(referenceImage))
            }
        }
        // Unsized cells keep using the batch's previous scale for their area.
        let unsized = try decoded(images[0])[1]
        #expect(unsized.diameter == 0)
        #expect(unsized.areaMicrons2 == 13 * (2.0 / 5) * (2.0 / 5))
    }

    @Test func interruptedRecalibrationIsSavedWithItsMarkerAndCompletedNextTime() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixtures = [cells(6), cells(5, offset: 200), cells(7, offset: 400)]
        let first = try openStore(in: folder)
        let (batch, images) = makeBatch(in: first, fixtures)
        // The middle image cannot be read, so the pass stops there.
        let broken = try #require(images[1].detection)
        broken.cellsData = Data("not cells".utf8)
        DecodedCellCache.shared.remove(broken.id)
        try first.context.save()

        let state = AppState(repos: first)
        state.recalibrationSaveInterval = 1
        await #expect(throws: (any Error).self) {
            try await state.recalibrateBatchIfNeeded(batch, pxPerUm: 4, source: "manual")
        }

        // Reopened as after quitting: the marker was saved with the first image.
        let reopened = try openStore(in: folder)
        let batchID = batch.id
        let saved = try #require(reopened.batch(id: batchID))
        #expect(saved.pxPerUm == 4)
        #expect(saved.recalibrationPending)
        let savedImages = saved.images.sorted { ($0.sourceOrder ?? 0) < ($1.sourceOrder ?? 0) }
        #expect(try decoded(savedImages[0]) == AppState.calibratedCells(fixtures[0], pxPerUm: 4, fallbackScale: 2))
        #expect(try decoded(savedImages[2]) == fixtures[2], "Not reached before the pass stopped")

        // Once the image is readable again, the same scale completes the pass.
        let repaired = try #require(savedImages[1].detection)
        repaired.cells = fixtures[1]
        try reopened.context.save()
        let firstImage = try decoded(savedImages[0])
        let resumed = AppState(repos: reopened)
        #expect(try await resumed.recalibrateBatchIfNeeded(saved, pxPerUm: 4, source: "manual"))
        #expect(!saved.recalibrationPending)
        #expect(try decoded(savedImages[0]) == firstImage, "Already rewritten: unchanged")
        #expect(try decoded(savedImages[1]) == AppState.calibratedCells(fixtures[1], pxPerUm: 4, fallbackScale: 4))
        #expect(try decoded(savedImages[2]) == AppState.calibratedCells(fixtures[2], pxPerUm: 4, fallbackScale: 4))
        #expect(try decoded(savedImages[2]) == AppState.calibratedCells(fixtures[2], pxPerUm: 4, fallbackScale: 2))

        // Complete now: the same request changes nothing.
        let revisions = savedImages.map { $0.detection?.cellsRevision }
        #expect(try await resumed.recalibrateBatchIfNeeded(saved, pxPerUm: 4, source: "manual") == false)
        #expect(savedImages.map { $0.detection?.cellsRevision } == revisions)
        let check = try openStore(in: folder)
        #expect(try #require(check.batch(id: batchID)).recalibrationPending == false)
    }

    // MARK: - Upkeep note

    @Test func noteRecordsDoneJobsPerStoreFileAndForgetsThemOnReportedWork() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent(LibraryLayout.storeFileName)
        try Data("store".utf8).write(to: store)

        let first = BackgroundUpkeepNote(storeURL: store)
        #expect(first.fileURL == folder.appendingPathComponent(BackgroundUpkeepNote.fileName))
        for job in Job.allCases {
            #expect(first.needsFullPass(job), "A library this version has not upgraded")
            let work = first.beginPass(job)
            #expect(work == .all)
            first.endPass(job, work, finished: true)
            #expect(!first.needsRun(job))
        }

        // Next launch: every job is skipped.
        let second = BackgroundUpkeepNote(storeURL: store)
        #expect(Job.allCases.allSatisfy { !second.needsRun($0) })

        // Reported work leaves the file at once, so quitting before the pass
        // leaves the job due (as a full pass) on the next launch.
        let row = UUID()
        second.noteWork(.maskVersions, ids: [row])
        #expect(second.needsRun(.maskVersions) && !second.needsFullPass(.maskVersions))
        #expect(second.reportedRows(.maskVersions) == [row])
        let afterQuit = BackgroundUpkeepNote(storeURL: store)
        #expect(afterQuit.needsFullPass(.maskVersions))
        #expect(!afterQuit.needsRun(.detectionCellStorage) && !afterQuit.needsRun(.cellMetrics))

        // A pass over just the reported rows records the job done again.
        let work = second.beginPass(.maskVersions)
        #expect(work == .rows([row]))
        second.endPass(.maskVersions, work, finished: true)
        #expect(!BackgroundUpkeepNote(storeURL: store).needsRun(.maskVersions))

        // A note written for an older version of a job runs that job again.
        let fileNumber = try #require(
            (try FileManager.default.attributesOfItem(atPath: store.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
        let older: [String: Any] = [
            "done": [Job.maskVersions.rawValue: Job.maskVersions.version,
                     Job.detectionCellStorage.rawValue: Job.detectionCellStorage.version,
                     Job.cellMetrics.rawValue: Job.cellMetrics.version - 1],
            "storeFile": fileNumber,
        ]
        try JSONSerialization.data(withJSONObject: older).write(to: try #require(first.fileURL))
        let upgraded = BackgroundUpkeepNote(storeURL: store)
        #expect(upgraded.needsFullPass(.cellMetrics))
        #expect(!upgraded.needsRun(.maskVersions) && !upgraded.needsRun(.detectionCellStorage))

        // Another store file in the same place (a restored backup, a copied
        // database) is checked again.
        let replacement = folder.appendingPathComponent("replacement.sqlite")
        try Data("store".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: store)
        try FileManager.default.moveItem(at: replacement, to: store)
        let replaced = BackgroundUpkeepNote(storeURL: store)
        #expect(Job.allCases.allSatisfy { replaced.needsFullPass($0) })
    }

    @Test func passesGiveWorkBackUntilTheyFinish() {
        let note = BackgroundUpkeepNote(storeURL: URL(fileURLWithPath: "/dev/null"))
        #expect(note.fileURL == nil)
        #expect(note.needsFullPass(.cellMetrics), "In-memory stores start out unchecked")
        let full = note.beginPass(.cellMetrics)
        note.endPass(.cellMetrics, full, finished: false)
        #expect(note.needsFullPass(.cellMetrics), "A held or cancelled pass gives its work back")
        note.endPass(.cellMetrics, note.beginPass(.cellMetrics), finished: true)
        #expect(!note.needsRun(.cellMetrics))

        let a = UUID(), b = UUID()
        note.noteWork(.cellMetrics, ids: [a])
        let first = note.beginPass(.cellMetrics)
        #expect(first == .rows([a]))
        note.noteWork(.cellMetrics, ids: [b])   // reported while the pass runs
        note.endPass(.cellMetrics, first, finished: true)
        #expect(note.needsRun(.cellMetrics))
        #expect(note.reportedRows(.cellMetrics) == [b])
        let second = note.beginPass(.cellMetrics)
        note.endPass(.cellMetrics, second, finished: false)
        #expect(note.reportedRows(.cellMetrics) == [b])
        note.endPass(.cellMetrics, note.beginPass(.cellMetrics), finished: true)
        #expect(!note.needsRun(.cellMetrics))

        note.noteUnknownWork(.cellMetrics)
        #expect(note.needsFullPass(.cellMetrics))
    }

    @Test func everyWriteThatLeavesWorkReportsItAndOthersDoNot() async throws {
        let repos = Repositories(inMemory: true)
        let (batch, images) = makeBatch(in: repos, [cells(6), cells(5, offset: 200)])
        let image = images[0]
        try await completeEveryJob(repos)
        let note = repos.upkeepNote

        // A normal analysis leaves nothing to do.
        repos.saveDetection(cells(4, offset: 500), detectorId: "rerun", for: images[1])
        #expect(!note.needsRun(.detectionCellStorage) && !note.needsRun(.cellMetrics))
        try await runReportedUpkeep(repos)

        // An analysis saved from bytes without a content hash.
        let plainCells = cells(6)
        let plain = DetectionRecord.encodePlainCellsJSON(plainCells)
        repos.saveDetection(snapshot: DetectionRecord.CellsStorageSnapshot(data: plain, minimumConfidence: 0.4, count: 6),
                            cells: plainCells, detectorId: "plain", for: image)
        let saved = try #require(image.detection)
        #expect(note.reportedRows(.detectionCellStorage) == [try #require(saved.cellsStorage).id])
        try await runReportedUpkeep(repos)
        #expect(saved.cellsStorage?.storageFormat == CellsBlobCodec.compressedFormat)
        #expect(saved.cellsContentHash == CellsBlobCodec.sha256Hex(plain))

        // A mask version saved from plain bytes with no mean confidence.
        let versionCells = cells(3, offset: 800)
        let version = repos.saveSegmentationVariant(image: image, detectorId: "A", label: "Plain",
                                                    plainJSON: DetectionRecord.encodePlainCellsJSON(versionCells),
                                                    cellCount: 3, meanConfidence: nil)
        #expect(note.reportedRows(.maskVersions) == [version.id])
        try await runReportedUpkeep(repos)
        #expect(version.storageFormat == CellsBlobCodec.compressedFormat && version.meanConfidence >= 0)

        // A version saved from cells is stored compact: nothing to report.
        _ = repos.saveSegmentationVariant(image: image, detectorId: "B", label: "Compact",
                                          cells: cells(2, offset: 900))
        #expect(!note.needsRun(.maskVersions))

        // Using a version saved as plain JSON puts plain bytes live.
        let plainVersion = repos.saveSegmentationVariant(
            image: image, detectorId: "C", label: "Plain again",
            plainJSON: DetectionRecord.encodePlainCellsJSON(cells(4, offset: 1000)), cellCount: 4, meanConfidence: 0.7)
        #expect(note.reportedRows(.maskVersions) == [plainVersion.id])
        #expect(repos.applySegmentationVariant(plainVersion, to: image) != nil)
        let live = try #require(image.detection)
        #expect(note.reportedRows(.detectionCellStorage) == [try #require(live.cellsStorage).id])
        try await runReportedUpkeep(repos)
        #expect(CellsBlobCodec.isCompressed(live.cellsData))

        // An edit stored without metrics or content hash.
        func bare(_ cells: [DetectedCell]) -> DetectionRecord.CellsStorageSnapshot {
            DetectionRecord.CellsStorageSnapshot(data: DetectionRecord.encodePlainCellsJSON(cells),
                                                 minimumConfidence: cells.map(\.confidence).min() ?? 1,
                                                 count: cells.count)
        }
        var edited = live.cells
        edited.removeLast()
        _ = repos.commitCellEdit(storage: bare(edited), corrections: [], detection: live, image: image)
        #expect(note.reportedRows(.cellMetrics) == [live.id])
        #expect(note.reportedRows(.detectionCellStorage) == [try #require(live.cellsStorage).id])
        try await runReportedUpkeep(repos)
        #expect(live.cellMetricsVersion == CellMetricsCodec.version)

        // The same from Review, and its undo.
        let uncertain = try #require(live.cells.first { $0.confidence < 0.65 })
        let review = try repos.commitReviewCellEdit(storage: bare(live.cells),
                                                    corrections: [CorrectionSpec(kind: "accept", cell: uncertain)],
                                                    detection: live, image: image)
        #expect(note.reportedRows(.cellMetrics) == [live.id])
        try await runReportedUpkeep(repos)
        let liveID = live.id, cellID = uncertain.id
        let candidate = try #require(try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { $0.detectionId == liveID && $0.cellId == cellID })).first)
        _ = try repos.undoReviewCorrection(try #require(review.corrections.first), candidate: candidate,
                                           restoredStorage: bare(live.cells), detection: live, image: image)
        #expect(note.reportedRows(.cellMetrics) == [live.id])
        try await runReportedUpkeep(repos)

        // Recalibration stores complete snapshots: nothing to report.
        let state = AppState(repos: repos)
        #expect(try await state.recalibrateBatchIfNeeded(batch, pxPerUm: 3, source: "manual"))
        for job in Job.allCases { #expect(!note.needsRun(job)) }

        // Rows from a restore are not named: every job reads its query again.
        repos.noteRestoredRows()
        for job in Job.allCases { #expect(note.needsFullPass(job)) }
    }

    @Test func restoreReportsItsRowsAndArchiveDoesNot() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let live = folder.appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let repos = try openStore(in: live)
        let (batch, images) = makeBatch(in: repos, [cells(5)])
        let image = images[0]
        // The image's own file, under the test data root.
        let imageFiles = [image.storedURL, image.thumbURL, image.displayURL]
        defer { for url in imageFiles { try? FileManager.default.removeItem(at: url) } }
        try FileManager.default.createDirectory(at: image.storedURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: image.storedURL)
        try repos.context.save()
        try await completeEveryJob(repos)

        let service = BatchArchiveService(repos: repos)
        let archive = folder.appendingPathComponent("Archives", isDirectory: true)
            .appendingPathComponent("Calibration.cellcounterlibrary", isDirectory: true)
        _ = try await service.archive(batchId: batch.id, to: archive)
        for job in Job.allCases { #expect(!repos.upkeepNote.needsRun(job), "Archiving adds no rows") }

        _ = try await service.restore(from: archive)
        #expect(repos.batch(id: batch.id) != nil)
        for job in Job.allCases { #expect(repos.upkeepNote.needsFullPass(job)) }
        try await completeEveryJob(repos)
    }

    // MARK: - Paging

    @Test func maskVersionPassesVisitEveryCandidateOnce() async throws {
        let repos = Repositories(inMemory: true)
        let (_, images) = makeBatch(in: repos, [cells(4)])
        let image = images[0]
        var readable: Set<UUID> = []
        var unreadable: Set<UUID> = []
        // Written directly, as rows saved by older versions.
        for index in 0..<9 {
            let variant: SegmentationVariantRecord
            if index % 3 == 2 {
                var damaged = Data("CCZ1".utf8)
                damaged.append(contentsOf: [7, 7, UInt8(index)])
                variant = SegmentationVariantRecord(image: image, detectorId: "D", label: "Broken \(index)",
                                                    plainJSON: damaged, cellCount: 2,
                                                    meanConfidence: -1, contentHash: nil)
                unreadable.insert(variant.id)
            } else {
                variant = SegmentationVariantRecord(image: image, detectorId: "P", label: "Plain \(index)",
                                                    cells: cells(3 + index, offset: Double(index) * 100))
                readable.insert(variant.id)
            }
            repos.context.insert(variant)
        }
        let compact = repos.saveSegmentationVariant(image: image, detectorId: "C", label: "Compact",
                                                    cells: cells(2, offset: 5000))
        try repos.context.save()
        let visits = Visits()
        repos.upkeepVisitObserver = { visits.record($0, $1) }

        #expect(try await repos.compactSegmentationVariants(chunkSize: 2) == readable.count)
        let first = visits.ids[.maskVersions] ?? []
        #expect(first.count == Set(first).count, "No row is read twice")
        #expect(Set(first) == readable.union(unreadable))
        #expect(!first.contains(compact.id))
        #expect(!repos.upkeepNote.needsRun(.maskVersions))

        // Unreadable rows stay as they are and are read once per full pass.
        visits.reset()
        #expect(try await repos.compactSegmentationVariants(chunkSize: 2) == 0)
        let second = visits.ids[.maskVersions] ?? []
        #expect(second.count == unreadable.count && Set(second) == unreadable)

        // While the note records the job as done, the background pass reads nothing.
        visits.reset()
        let unreported = SegmentationVariantRecord(image: image, detectorId: "U", label: "Unreported",
                                                   cells: cells(3, offset: 7000))
        repos.context.insert(unreported)
        try repos.context.save()
        #expect(try await repos.compactReportedSegmentationVariants(chunkSize: 2))
        #expect(visits.ids[.maskVersions, default: []].isEmpty)
        #expect(unreported.storageFormat == CellsBlobCodec.plainJSONFormat)

        // A reported row is read on its own, by id.
        let reported = repos.saveSegmentationVariant(
            image: image, detectorId: "R", label: "Reported",
            plainJSON: DetectionRecord.encodePlainCellsJSON(cells(5, offset: 8000)), cellCount: 5, meanConfidence: nil)
        #expect(try await repos.compactReportedSegmentationVariants(chunkSize: 2))
        #expect(visits.ids[.maskVersions] == [reported.id])
        #expect(reported.storageFormat == CellsBlobCodec.compressedFormat)
        #expect(!repos.upkeepNote.needsRun(.maskVersions))
    }

    @Test func cellStoragePassesVisitEveryCandidateOnce() async throws {
        let repos = Repositories(inMemory: true)
        let fixtures = (0..<6).map { cells(4 + $0, offset: Double($0) * 100) }
        let (_, images) = makeBatch(in: repos, fixtures)
        var inline: Set<UUID> = []
        for (index, image) in images.enumerated() where index != 4 {
            // As written before cells had their own row; one is unreadable.
            let detection = try #require(image.detection)
            if let storage = detection.cellsStorage {
                detection.cellsStorage = nil
                repos.context.delete(storage)
            }
            detection.legacyCellsData = index == 5 ? Data("{truncated".utf8)
                : DetectionRecord.encodePlainCellsJSON(fixtures[index])
            DecodedCellCache.shared.remove(detection.id)
            inline.insert(detection.id)
        }
        try repos.context.save()
        let visits = Visits()
        repos.upkeepVisitObserver = { visits.record($0, $1) }

        #expect(try await repos.migrateDetectionCellStorage(chunkSize: 2) == inline.count)
        let visited = visits.ids[.detectionCellStorage] ?? []
        #expect(visited.count == Set(visited).count, "No row is read twice")
        #expect(Set(visited).intersection(inline) == inline)
        let truncated = try #require(images[5].detection)
        // The unreadable row moves as is, and its separate row is read once in phase two.
        #expect(Set(visited).subtracting(inline) == [try #require(truncated.cellsStorage).id])
        for (index, image) in images.enumerated() where index != 5 {
            #expect(try decoded(image) == fixtures[index])
            #expect(image.detection?.cellsStorage?.storageFormat == CellsBlobCodec.compressedFormat)
        }
        #expect(!repos.upkeepNote.needsRun(.detectionCellStorage))
    }

    @Test func cellMetricsPassesVisitEveryCandidateOnce() async throws {
        let repos = Repositories(inMemory: true)
        let fixtures = (0..<7).map { cells(4 + $0, offset: Double($0) * 100) }
        let (_, images) = makeBatch(in: repos, fixtures)
        var missing: Set<UUID> = []
        for (index, image) in images.enumerated() where index % 2 == 0 {
            let detection = try #require(image.detection)
            if index == 6 {
                detection.cellsData = Data("not cells".utf8)
                DecodedCellCache.shared.remove(detection.id)
            }
            detection.storeCellMetrics(nil)
            missing.insert(detection.id)
        }
        try repos.context.save()
        let visits = Visits()
        repos.upkeepVisitObserver = { visits.record($0, $1) }

        #expect(try await repos.backfillCellMetrics(chunkSize: 2) == missing.count - 1)
        let first = visits.ids[.cellMetrics] ?? []
        #expect(first.count == Set(first).count, "No row is read twice")
        #expect(Set(first) == missing)
        #expect(!repos.upkeepNote.needsRun(.cellMetrics))

        visits.reset()
        #expect(try await repos.backfillCellMetrics(chunkSize: 2) == 0)
        #expect(visits.ids[.cellMetrics] == [try #require(images[6].detection).id])

        // Reported rows only, once each.
        visits.reset()
        let edited = try #require(images[1].detection)
        edited.storeCellMetrics(nil)
        repos.noteUpkeepWork(for: edited)
        #expect(try await repos.backfillReportedCellMetrics(chunkSize: 2))
        #expect(visits.ids[.cellMetrics] == [edited.id])
        #expect(edited.cellMetricsVersion == CellMetricsCodec.version)
    }
}
