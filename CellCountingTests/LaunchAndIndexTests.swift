import Foundation
import SwiftData
import Testing
@testable import CellCounting

/// Launch-time review-index upkeep, the indexed queries it relies on, and the
/// batched deletion paths.
@Suite(.serialized)
struct LaunchAndIndexTests {

    // MARK: - Fixtures

    /// Deterministic ids, so two stores can hold identical fixtures and the
    /// fixture's row keys sort in creation order.
    private struct IDs {
        private var next = 0
        mutating func make() -> UUID {
            next += 1
            return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", next))!
        }
    }

    private struct MixedFixture {
        var batchID = UUID()
        var validRowIDs: Set<UUID> = []
        var staleRowIDs: Set<UUID> = []
        var triagedValidRowIDs: Set<UUID> = []
        var batchImageCount = 0
        var batchCellCount = 0
    }

    private struct RowState: Hashable {
        let id: UUID
        let sortKey: String
        let triaged: Bool
        let imageId: UUID
        let detectionId: UUID
    }

    /// One batch of twelve analysed images with valid review rows, plus every
    /// kind of stale row the check removes: missing image, missing detection,
    /// a replaced detection that still exists, and an image outside any batch.
    /// Some rows of both kinds carry legacy empty sort keys, and the batch has
    /// no stored totals yet. Every row has its own `createdAt`.
    @MainActor
    private func buildMixedFixture(in repos: Repositories) throws -> MixedFixture {
        let context = repos.context
        var ids = IDs()
        var fixture = MixedFixture()
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var rowNumber = 0

        func makeCells(_ count: Int) -> [DetectedCell] {
            (0..<count).map { n in
                DetectedCell(id: ids.make(), cx: Double(20 + n * 10), cy: 40,
                             diameter: 5, diameterPx: 10, confidence: 0.1 + Double(n % 5) / 10)
            }
        }
        func makeDetection(_ cells: [DetectedCell]) -> DetectionRecord {
            let detection = DetectionRecord(detectorId: "fixture", cells: cells)
            detection.id = ids.make()
            detection.reviewIndexVersion = 1
            context.insert(detection)
            return detection
        }
        @discardableResult
        func addRow(cell: DetectedCell, detection: DetectionRecord, image: ImageRecord,
                    imageId: UUID? = nil, detectionId: UUID? = nil,
                    triaged: Bool = false, legacyKey: Bool = false) -> UUID {
            let row = ReviewCandidateRecord(cell: cell, detection: detection, image: image)
            row.id = ids.make()
            row.sortKey = legacyKey ? "" : row.id.uuidString
            row.imageId = imageId ?? image.id
            row.detectionId = detectionId ?? detection.id
            row.triaged = triaged
            row.createdAt = base.addingTimeInterval(Double(rowNumber))
            rowNumber += 1
            context.insert(row)
            return row.id
        }

        let batch = BatchRecord(id: ids.make(), name: "Mixed", displayName: "Mixed",
                                modelId: "fixture", pxPerUm: 2, thresholds: [10, 20])
        context.insert(batch)
        fixture.batchID = batch.id
        var images: [ImageRecord] = []
        var detections: [DetectionRecord] = []
        var cellsByImage: [[DetectedCell]] = []
        for index in 0..<12 {
            let image = ImageRecord(id: ids.make(), fileName: "", originalPath: "",
                                    widthPx: 512, heightPx: 512)
            context.insert(image)
            image.batch = batch
            let cells = makeCells(20)
            let detection = makeDetection(cells)
            detection.image = image
            image.detection = detection
            for (n, cell) in cells.enumerated() {
                let triaged = n % 5 == 0
                let id = addRow(cell: cell, detection: detection, image: image,
                                triaged: triaged, legacyKey: index < 3 && n < 10)
                fixture.validRowIDs.insert(id)
                if triaged { fixture.triagedValidRowIDs.insert(id) }
            }
            images.append(image)
            detections.append(detection)
            cellsByImage.append(cells)
            fixture.batchImageCount += 1
            fixture.batchCellCount += cells.count
        }

        // Owners that no longer exist.
        for n in 0..<15 {
            fixture.staleRowIDs.insert(addRow(cell: cellsByImage[1][n], detection: detections[1],
                                              image: images[1], imageId: ids.make(),
                                              legacyKey: n < 3))
            fixture.staleRowIDs.insert(addRow(cell: cellsByImage[2][n], detection: detections[2],
                                              image: images[2], detectionId: ids.make()))
        }
        // A replaced detection that still exists but is not the image's live one.
        let replaced = makeDetection(makeCells(10))
        for n in 0..<10 {
            fixture.staleRowIDs.insert(addRow(cell: cellsByImage[0][n], detection: replaced,
                                              image: images[0], triaged: n == 0))
        }
        // An analysed image that belongs to no batch.
        let loose = ImageRecord(id: ids.make(), fileName: "", originalPath: "",
                                widthPx: 512, heightPx: 512)
        context.insert(loose)
        let looseCells = makeCells(10)
        let looseDetection = makeDetection(looseCells)
        looseDetection.image = loose
        loose.detection = looseDetection
        for cell in looseCells {
            fixture.staleRowIDs.insert(addRow(cell: cell, detection: looseDetection, image: loose,
                                              legacyKey: cell.id == looseCells[0].id))
        }

        batch.imageCountSummary = -1
        batch.cellCountSummary = -1
        try context.save()
        return fixture
    }

    /// The repair as it ran before: offset pages ordered by `createdAt`, the
    /// sort-key backfill, then batch totals. Kept as the reference result.
    @MainActor
    private func previousRepair(_ repos: Repositories) async throws {
        let context = repos.context
        var offset = 0
        while true {
            var desc = FetchDescriptor<ReviewCandidateRecord>(sortBy: [SortDescriptor(\.createdAt)])
            desc.fetchLimit = ReviewQueueSession.pageSize
            desc.fetchOffset = offset
            let rows = try context.fetch(desc)
            guard !rows.isEmpty else { break }
            let liveIDs = Set(try repos.reviewItems(for: rows).map(\.id))
            for row in rows where !liveIDs.contains(row.id) { context.delete(row) }
            try context.save()
            offset += liveIDs.count
            if rows.count < ReviewQueueSession.pageSize { break }
        }
        var legacy = FetchDescriptor<ReviewCandidateRecord>(predicate: #Predicate { $0.sortKey == "" })
        legacy.fetchLimit = 96
        while true {
            let rows = try context.fetch(legacy)
            guard !rows.isEmpty else { break }
            for row in rows { row.sortKey = row.id.uuidString }
            try context.save()
        }
        for batch in repos.allBatches() where batch.imageCountSummary < 0 || batch.cellCountSummary < 0 {
            batch.imageCountSummary = batch.images.count
            batch.cellCountSummary = batch.images.reduce(0) { $0 + ($1.detection?.summaryCellCount ?? 0) }
        }
        try context.save()
    }

    @MainActor
    private func rowStates(_ repos: Repositories) throws -> Set<RowState> {
        Set(try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>()).map {
            RowState(id: $0.id, sortKey: $0.sortKey, triaged: $0.triaged,
                     imageId: $0.imageId, detectionId: $0.detectionId)
        })
    }

    @MainActor
    private func rowIDs(_ repos: Repositories) throws -> Set<UUID> {
        Set(try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>()).map(\.id))
    }

    @MainActor
    private func count<T: PersistentModel>(_ type: T.Type, in repos: Repositories) throws -> Int {
        try repos.context.fetchCount(FetchDescriptor<T>())
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchAndIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func openStore(in folder: URL, name: String, allowsSave: Bool = true) throws -> Repositories {
        let schema = Repositories.librarySchema()
        let config = ModelConfiguration(name, schema: schema,
                                        url: folder.appendingPathComponent(LibraryLayout.storeFileName),
                                        allowsSave: allowsSave)
        return Repositories(container: try ModelContainer(for: schema, configurations: [config]))
    }

    // MARK: - Stale-row check

    @Test @MainActor func repairResultMatchesThePreviousAlgorithm() async throws {
        let repaired = Repositories(inMemory: true)
        let reference = Repositories(inMemory: true)
        let fixture = try buildMixedFixture(in: repaired)
        _ = try buildMixedFixture(in: reference)
        #expect(try rowStates(repaired) == rowStates(reference))
        #expect(repaired.reviewIndexCheck.needsCheck, "A library this version never checked must be checked")

        try await repaired.rebuildPerformanceIndexes()
        try await previousRepair(reference)

        let after = try rowStates(repaired)
        #expect(after == (try rowStates(reference)))
        #expect(Set(after.map(\.id)) == fixture.validRowIDs, "Stale rows go, valid rows stay")
        #expect(fixture.staleRowIDs.isDisjoint(with: after.map(\.id)))
        #expect(after.allSatisfy { $0.sortKey == $0.id.uuidString }, "Legacy keys are backfilled")
        #expect(Set(after.filter(\.triaged).map(\.id)) == fixture.triagedValidRowIDs)
        #expect(!repaired.reviewIndexCheck.needsCheck)

        let batch = try #require(repaired.batch(id: fixture.batchID))
        let referenceBatch = try #require(reference.batch(id: fixture.batchID))
        #expect(batch.imageCountSummary == fixture.batchImageCount)
        #expect(batch.cellCountSummary == fixture.batchCellCount)
        #expect(batch.imageCountSummary == referenceBatch.imageCountSummary)
        #expect(batch.cellCountSummary == referenceBatch.cellCountSummary)
        // Only index rows are removed; owners and their detections remain.
        #expect(try count(DetectionRecord.self, in: repaired) == count(DetectionRecord.self, in: reference))
        #expect(try count(ImageRecord.self, in: repaired) == 13)
    }

    @Test @MainActor func staleRowCheckIsSkippedWhileTheLibraryIsRecordedClean() async throws {
        let repos = Repositories(inMemory: true)
        let fixture = try buildMixedFixture(in: repos)
        let everyRow = fixture.validRowIDs.union(fixture.staleRowIDs)
        #expect(try rowIDs(repos) == everyRow)

        // Recorded as clean: the background upkeep must leave every row alone.
        repos.reviewIndexCheck.markVerified(sinceGeneration: repos.reviewIndexCheck.generation)
        #expect(!repos.reviewIndexCheck.needsCheck)
        try await repos.performDeferredIndexMaintenance()
        #expect(try rowIDs(repos) == everyRow, "No check runs while the library is recorded clean")

        // The queue meeting stale rows re-arms the check and asks for it once.
        var requests = 0
        repos.onStaleReviewRows = { requests += 1 }
        let rows = try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>())
        let shown = try repos.reviewItems(for: rows)
        #expect(Set(shown.map(\.id)) == fixture.validRowIDs)
        #expect(requests == 1)
        #expect(repos.reviewIndexCheck.needsCheck)
        _ = try repos.reviewItems(for: rows)
        #expect(requests == 1, "An already pending check is not requested again")

        try await repos.performDeferredIndexMaintenance()
        #expect(try rowIDs(repos) == fixture.validRowIDs)
        #expect(!repos.reviewIndexCheck.needsCheck)
    }

    @Test @MainActor func queueIsCorrectBeforeTheStaleRowCheckRuns() async throws {
        let repos = Repositories(inMemory: true)
        let fixture = try buildMixedFixture(in: repos)
        let staleCount = fixture.staleRowIDs.count

        // The part the queue waits for upgrades keys but leaves stale rows to
        // the background check.
        let upgraded = try await repos.prepareReviewQueueIndex()
        let upgradedAgain = try await repos.prepareReviewQueueIndex()
        #expect(upgraded, "Legacy keys were backfilled")
        #expect(!upgradedAgain, "Nothing left to upgrade")
        #expect(try rowIDs(repos).count == fixture.validRowIDs.count + staleCount)
        #expect(repos.reviewIndexCheck.needsCheck)

        let session = ReviewQueueSession()
        session.reload(using: repos)
        var seen = Set<UUID>()
        while let item = session.current {
            guard seen.insert(item.id).inserted else { Issue.record("Queue repeated a row"); break }
            session.skip(using: repos)
        }
        #expect(seen == fixture.validRowIDs.subtracting(fixture.triagedValidRowIDs),
                "Stale rows are never shown, so Review need not wait for the check")
    }

    @Test @MainActor func checkStartedBeforeAStaleReportDoesNotRecordTheLibraryClean() {
        let check = ReviewIndexCheck(fileURL: nil)
        #expect(check.needsCheck)
        let started = check.generation
        check.markNeedsCheck()
        check.markVerified(sinceGeneration: started)
        #expect(check.needsCheck)
        check.markVerified(sinceGeneration: check.generation)
        #expect(!check.needsCheck)
    }

    @Test @MainActor func checkNoteBelongsToEachLibraryFolder() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderA = root.appendingPathComponent("A.cellcounterlibrary", isDirectory: true)
        let folderB = root.appendingPathComponent("B.cellcounterlibrary", isDirectory: true)
        for folder in [folderA, folderB] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let libraryA = try openStore(in: folderA, name: "LaunchCheckA")
        let libraryB = try openStore(in: folderB, name: "LaunchCheckB")
        let noteA = folderA.appendingPathComponent(ReviewIndexCheck.fileName)
        let noteB = folderB.appendingPathComponent(ReviewIndexCheck.fileName)
        // The note sits next to the library's own store.
        #expect(libraryA.reviewIndexCheck.fileURL?.lastPathComponent == ReviewIndexCheck.fileName)
        #expect(libraryA.reviewIndexCheck.fileURL?.deletingLastPathComponent().lastPathComponent
                == folderA.lastPathComponent)
        #expect(libraryA.reviewIndexCheck.needsCheck)
        #expect(libraryB.reviewIndexCheck.needsCheck)

        try await libraryA.performDeferredIndexMaintenance()
        #expect(!libraryA.reviewIndexCheck.needsCheck)
        #expect(FileManager.default.fileExists(atPath: noteA.path))
        #expect(libraryB.reviewIndexCheck.needsCheck, "Checking one library says nothing about another")
        #expect(!FileManager.default.fileExists(atPath: noteB.path))
        // The note outlives the session that wrote it.
        #expect(!ReviewIndexCheck(storeURL: folderA.appendingPathComponent(LibraryLayout.storeFileName)).needsCheck)

        // A note from an older version of the check does not count.
        try Data(#"{"repairVersion":0}"#.utf8).write(to: noteB)
        #expect(libraryB.reviewIndexCheck.needsCheck)
        // Stale rows reported later remove the note again.
        libraryA.reviewIndexCheck.markNeedsCheck()
        #expect(!FileManager.default.fileExists(atPath: noteA.path))
        // In-memory stores keep the state in memory only.
        #expect(Repositories(inMemory: true).reviewIndexCheck.fileURL == nil)
    }

    // MARK: - Key paging

    @Test @MainActor func keyPagingVisitsEveryRowExactlyOnce() async throws {
        let repos = Repositories(inMemory: true)
        let batch = repos.createBatch(displayName: "Paging", modelId: "test", pxPerUm: 2, thresholds: [10, 20])
        let image = ImageRecord(fileName: "", originalPath: "", widthPx: 512, heightPx: 512)
        repos.context.insert(image)
        repos.attach(image: image, to: batch, save: false)
        let cells = (0..<300).map { n in
            DetectedCell(cx: Double(n), cy: 10, diameter: 4, diameterPx: 8, confidence: 0.2)
        }
        repos.saveDetection(cells, detectorId: "test", for: image, save: false)
        try repos.context.save()
        // Equal keys inside and across page boundaries, including empty legacy keys.
        let rows = try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>())
        #expect(rows.count == 300)
        for (index, row) in rows.enumerated() {
            if index < 40 { row.sortKey = "" } else if index < 100 { row.sortKey = "SHARED-KEY" }
        }
        try repos.context.save()
        let all = Set(rows.map(\.id))

        var visits: [UUID: Int] = [:]
        let finished = try await repos.forEachReviewCandidatePage(pageSize: 7) { page in
            for row in page { visits[row.id, default: 0] += 1 }
        }
        #expect(finished)
        #expect(Set(visits.keys) == all)
        #expect(visits.values.allSatisfy { $0 == 1 })

        // Rows deleted by the visitor cannot shift the pages that follow.
        var secondVisits: [UUID: Int] = [:]
        var deleted = Set<UUID>()
        try await repos.forEachReviewCandidatePage(pageSize: 7) { page in
            for row in page { secondVisits[row.id, default: 0] += 1 }
            for (index, row) in page.enumerated() where index % 2 == 0 {
                deleted.insert(row.id)
                repos.context.delete(row)
            }
            try repos.context.save()
        }
        #expect(Set(secondVisits.keys) == all)
        #expect(secondVisits.values.allSatisfy { $0 == 1 })
        #expect(try rowIDs(repos) == all.subtracting(deleted))
    }

    // MARK: - Deletion

    @Test @MainActor func batchedDeletionRemovesTheSameRowsAndFilesAsBefore() throws {
        let repos = Repositories(inMemory: true)
        var removedFiles: [Set<URL>] = []
        repos.removeDeletedImageFiles = { removedFiles.append($0) }
        let first = repos.createBatch(displayName: "First", modelId: "test", pxPerUm: 2, thresholds: [10, 20])
        let second = repos.createBatch(displayName: "Second", modelId: "test", pxPerUm: 2, thresholds: [10, 20])
        var images: [ImageRecord] = []
        for batch in [first, second] {
            for index in 0..<3 {
                let image = ImageRecord(fileName: "\(batch.displayName)-\(index).png", originalPath: "",
                                        widthPx: 512, heightPx: 512)
                repos.context.insert(image)
                repos.attach(image: image, to: batch, save: false)
                let cells = (0..<(index + 2)).map { n in
                    DetectedCell(cx: Double(10 + n * 20), cy: 10, diameter: 4, diameterPx: 8, confidence: 0.3)
                }
                repos.saveDetection(cells, detectorId: "test", for: image, save: false)
                repos.saveSegmentationVariant(image: image, detectorId: "test", label: "Earlier",
                                              cells: Array(cells.prefix(1)), save: false)
                repos.context.insert(GroundTruthAnnotation(imageId: image.id, cx: 5, cy: 5))
                let roi = ROIRecord(imageId: image.id, kind: "include", shape: "rect",
                                    x: 0, y: 0, width: 5, height: 5)
                repos.context.insert(roi)
                roi.image = image
                images.append(image)
            }
        }
        images[1].fileName = ""
        try repos.context.save()

        // What the previous per-image deletion removed: rows keyed by the
        // selected images, their files (when named), and their stored counts.
        let selected = [images[0], images[1], images[3]]
        let selectedIDs = Set(selected.map(\.id))
        let expectedFiles = Set(selected.filter { !$0.fileName.isEmpty }.flatMap {
            [$0.storedURL, $0.displayURL, $0.thumbURL]
        })
        let keptReview = Set(try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>())
            .filter { !selectedIDs.contains($0.imageId) }.map(\.id))
        let keptVariants = Set(try repos.context.fetch(FetchDescriptor<SegmentationVariantRecord>())
            .filter { !selectedIDs.contains($0.imageId) }.map(\.id))
        let keptAnnotations = Set(try repos.context.fetch(FetchDescriptor<GroundTruthAnnotation>())
            .filter { !selectedIDs.contains($0.imageId) }.map(\.id))
        let keptROIs = Set(try repos.context.fetch(FetchDescriptor<ROIRecord>())
            .filter { !selectedIDs.contains($0.imageId) }.map(\.id))
        func cells(_ image: ImageRecord) -> Int { image.detection?.cellCountSummary ?? 0 }
        let firstCells = first.cellCountSummary - cells(images[0]) - cells(images[1])
        let secondCells = second.cellCountSummary - cells(images[3])
        let secondRemainingFiles = Set([images[4], images[5]].flatMap { [$0.storedURL, $0.displayURL, $0.thumbURL] })
        let secondImageIDs = Set([images[4], images[5]].map(\.id))

        // A repeated entry is deleted, and subtracted, once.
        try repos.deleteImages(selected + [images[0]])

        #expect(removedFiles == [expectedFiles])
        #expect(Set(try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>()).map(\.id)) == keptReview)
        #expect(Set(try repos.context.fetch(FetchDescriptor<SegmentationVariantRecord>()).map(\.id)) == keptVariants)
        #expect(Set(try repos.context.fetch(FetchDescriptor<GroundTruthAnnotation>()).map(\.id)) == keptAnnotations)
        #expect(Set(try repos.context.fetch(FetchDescriptor<ROIRecord>()).map(\.id)) == keptROIs)
        #expect(try count(ImageRecord.self, in: repos) == 3)
        #expect(try count(DetectionRecord.self, in: repos) == 3)
        #expect(first.imageCountSummary == 1)
        #expect(first.cellCountSummary == firstCells)
        #expect(second.imageCountSummary == 2)
        #expect(second.cellCountSummary == secondCells)

        try repos.deleteBatch(second)
        #expect(removedFiles.count == 2)
        #expect(removedFiles.last == secondRemainingFiles)
        #expect(repos.allBatches().map(\.id) == [first.id])
        #expect(try repos.context.fetch(FetchDescriptor<ReviewCandidateRecord>())
            .allSatisfy { !secondImageIDs.contains($0.imageId) })
        #expect(try count(ImageRecord.self, in: repos) == 1)
        #expect(try count(SegmentationVariantRecord.self, in: repos) == 1)
        #expect(try count(GroundTruthAnnotation.self, in: repos) == 1)
    }

    @Test @MainActor func deletionRemovesFilesOnlyAfterTheSaveCommits() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writable = try openStore(in: folder, name: "LaunchDeletion")
        let batch = writable.createBatch(displayName: "Kept", modelId: "test", pxPerUm: 2, thresholds: [10, 20])
        let image = ImageRecord(fileName: "kept.png", originalPath: "", widthPx: 512, heightPx: 512)
        writable.context.insert(image)
        writable.attach(image: image, to: batch, save: false)
        let cells = (0..<4).map { n in
            DetectedCell(cx: Double(10 + n * 20), cy: 10, diameter: 4, diameterPx: 8, confidence: 0.3)
        }
        writable.saveDetection(cells, detectorId: "test", for: image, save: false)
        try writable.context.save()
        let imageID = image.id
        let expectedFiles = Set([image.storedURL, image.displayURL, image.thumbURL])

        // The same library opened read-only: the deletion's save must fail.
        let readOnly = try openStore(in: folder, name: "LaunchDeletion", allowsSave: false)
        var readOnlyRemoved: [Set<URL>] = []
        readOnly.removeDeletedImageFiles = { readOnlyRemoved.append($0) }
        let readOnlyImage = try #require(readOnly.image(id: imageID))
        #expect(throws: (any Error).self) { try readOnly.deleteImages([readOnlyImage]) }
        #expect(readOnlyRemoved.isEmpty, "Files stay when the deletion was not saved")
        let check = ModelContext(readOnly.container)
        #expect(try check.fetch(FetchDescriptor<ImageRecord>()).count == 1)
        #expect(try check.fetch(FetchDescriptor<ReviewCandidateRecord>()).count == cells.count)

        var removed: [Set<URL>] = []
        writable.removeDeletedImageFiles = { removed.append($0) }
        try writable.deleteImages([image])
        #expect(removed == [expectedFiles])
        #expect(try count(ImageRecord.self, in: writable) == 0)
        #expect(try count(ReviewCandidateRecord.self, in: writable) == 0)
    }

    // MARK: - Empty batches

    @Test @MainActor func cleanupEmptyBatchesNeverDeletesANonEmptyBatch() throws {
        let repos = Repositories(inMemory: true)
        func addImages(_ count: Int, to batch: BatchRecord, save: Bool = true) {
            for index in 0..<count {
                let image = ImageRecord(fileName: "", originalPath: "\(index)", widthPx: 64, heightPx: 64)
                repos.context.insert(image)
                repos.attach(image: image, to: batch, save: save)
            }
        }
        let normal = repos.createBatch(displayName: "Normal", modelId: "test", pxPerUm: 2, thresholds: [10])
        let drifted = repos.createBatch(displayName: "Count says empty", modelId: "test", pxPerUm: 2, thresholds: [10])
        let legacy = repos.createBatch(displayName: "No stored count", modelId: "test", pxPerUm: 2, thresholds: [10])
        let empty = repos.createBatch(displayName: "Empty", modelId: "test", pxPerUm: 2, thresholds: [10])
        let emptyDrifted = repos.createBatch(displayName: "Count says four", modelId: "test", pxPerUm: 2, thresholds: [10])
        let unsaved = repos.createBatch(displayName: "Unsaved image", modelId: "test", pxPerUm: 2, thresholds: [10])
        addImages(1, to: normal)
        addImages(2, to: drifted)
        addImages(1, to: legacy)
        drifted.imageCountSummary = 0
        legacy.imageCountSummary = -1
        emptyDrifted.imageCountSummary = 4
        try repos.context.save()
        // An image attached but not saved yet still makes its batch non-empty.
        addImages(1, to: unsaved, save: false)

        repos.cleanupEmptyBatches()

        for batch in [normal, drifted, legacy, unsaved] {
            #expect(repos.batch(id: batch.id) != nil, "\(batch.displayName) has images and must stay")
        }
        #expect(repos.batch(id: empty.id) == nil)
        #expect(repos.batch(id: emptyDrifted.id) == nil, "A drifted stored count does not keep an empty batch")
        #expect(repos.totalImageCount() == 5)
    }

    // MARK: - Reset

    @Test @MainActor func resetEmptiesALargeLibraryAndRecordsTheIndexChecked() throws {
        let repos = Repositories(inMemory: true)
        let batch = repos.createBatch(displayName: "Large", modelId: "test", pxPerUm: 2, thresholds: [10, 20])
        for index in 0..<40 {
            let image = ImageRecord(fileName: "", originalPath: "\(index)", widthPx: 256, heightPx: 256)
            repos.context.insert(image)
            repos.attach(image: image, to: batch, save: false)
            let cells = (0..<3).map { n in
                DetectedCell(cx: Double(10 + n * 20), cy: 10, diameter: 4, diameterPx: 8, confidence: 0.3)
            }
            repos.saveDetection(cells, detectorId: "test", for: image, save: false)
            repos.saveSegmentationVariant(image: image, detectorId: "test", label: "Earlier",
                                          cells: cells, save: false)
            repos.context.insert(GroundTruthAnnotation(imageId: image.id, cx: 1, cy: 1))
            let roi = ROIRecord(imageId: image.id, kind: "include", shape: "rect", x: 0, y: 0, width: 4, height: 4)
            repos.context.insert(roi)
            roi.image = image
            let correction = CorrectionRecord(kind: "accept", cellId: cells[0].id, cx: 10, cy: 10, diameter: 4)
            repos.context.insert(correction)
            correction.detection = image.detection
        }
        // A detached detection with its own correction, as earlier versions left behind.
        let detached = DetectionRecord(detectorId: "test", cells: [])
        repos.context.insert(detached)
        let detachedCorrection = CorrectionRecord(kind: "remove", cellId: UUID(), cx: 1, cy: 1, diameter: 1)
        repos.context.insert(detachedCorrection)
        detachedCorrection.detection = detached
        try repos.context.save()
        #expect(repos.reviewIndexCheck.needsCheck)

        try repos.deleteAllLibraryRecords()

        #expect(try count(BatchRecord.self, in: repos) == 0)
        #expect(try count(ImageRecord.self, in: repos) == 0)
        #expect(try count(DetectionRecord.self, in: repos) == 0)
        #expect(try count(CorrectionRecord.self, in: repos) == 0)
        #expect(try count(ReviewCandidateRecord.self, in: repos) == 0)
        #expect(try count(ROIRecord.self, in: repos) == 0)
        #expect(try count(GroundTruthAnnotation.self, in: repos) == 0)
        #expect(try count(SegmentationVariantRecord.self, in: repos) == 0)
        #expect(!repos.calibrationPresets().isEmpty)
        #expect(!repos.binPresets().isEmpty)
        #expect(!repos.reviewIndexCheck.needsCheck, "An empty review index has nothing stale")
    }
}
