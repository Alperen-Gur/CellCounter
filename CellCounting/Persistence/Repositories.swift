import Foundation
import SwiftData

struct BatchSummary: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let createdAt: Date
    let imageCount: Int
    let cellCount: Int
    let thumbnailURL: URL?
}

struct CorrectionSpec: Sendable {
    let kind: String
    let cellId: UUID
    let cx: Double
    let cy: Double
    let diameter: Double

    init(kind: String, cell: DetectedCell) {
        self.init(kind: kind, cellId: cell.id, cx: cell.cx, cy: cell.cy,
                  diameter: cell.diameter)
    }

    init(kind: String, cellId: UUID, cx: Double, cy: Double, diameter: Double) {
        self.kind = kind
        self.cellId = cellId
        self.cx = cx
        self.cy = cy
        self.diameter = diameter
    }
}

struct CellEditCommitResult {
    let corrections: [CorrectionRecord]
    /// Negative when pending review rows were triaged, positive on undo.
    let reviewCountDelta: Int
}

@MainActor
final class Repositories {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    /// Set when the library's store could not be opened from disk and an
    /// in-memory store is used instead. Nothing done in this session is saved;
    /// the UI keeps a visible warning up while this is non-nil.
    private(set) var diskStoreError: String?
    var isUsingInMemoryFallback: Bool { diskStoreError != nil }
    /// Set when this launch copied the store before upgrading it
    /// (`LibraryStoreBackup`); the UI tells the user once where the copy is.
    private(set) var upgradeBackupURL: URL?

    /// Saved mask versions kept per image; 0 keeps all. The app's own library
    /// reads the user's setting. Isolated stores (tests, tools) use the
    /// default unless the caller replaces this, so they never depend on
    /// preferences.
    var maskVersionsKept: () -> Int = { MaskVersionRetention.defaultLimit }

    /// Background upkeep of stored cell data: saved mask versions
    /// (compression, content hashes, mean confidence) and detections (moving
    /// inline cell bytes into `StoredCellsRecord`, compressed). On for the
    /// app's own library; isolated stores only run it when a caller runs
    /// `compactSegmentationVariants()` / `migrateDetectionCellStorage()`.
    var automaticVariantCompaction = false
    private var variantCompactionTask: Task<Void, Never>?
    private var variantCompactionDebounce: Task<Void, Never>?
    private var variantCompactionGeneration = 0
    /// Held by archive and restore; pauses both kinds of upkeep.
    private var variantCompactionHolds = 0
    private var detectionStorageTask: Task<Void, Never>?
    private var detectionStorageDebounce: Task<Void, Never>?
    private var detectionStorageGeneration = 0

    /// Which background upkeep jobs may have work in this library. Kept next
    /// to the store (see `BackgroundUpkeepNote`), never in preferences.
    private(set) lazy var upkeepNote = BackgroundUpkeepNote(storeURL: container.configurations.first?.url)

    /// Starts the cell-metrics job after a write reported metrics to fill in.
    /// Set by `CellMetricsBackfill` for the app's own library.
    var onCellMetricsWork: (() -> Void)?

    /// Called with the ids of the rows each upkeep chunk reads (tests).
    var upkeepVisitObserver: ((BackgroundUpkeepNote.Job, [UUID]) -> Void)?

    /// Whether this library's review index still needs its stale-row check.
    /// Kept next to the store (see `ReviewIndexCheck`), never in preferences.
    private(set) lazy var reviewIndexCheck = ReviewIndexCheck(storeURL: container.configurations.first?.url)

    /// Called when the Review queue meets stale rows in a library whose
    /// index was recorded as clean. AppState starts the check in the background.
    var onStaleReviewRows: (() -> Void)?

    /// Unlinks image files after a deletion has been saved. Replaceable so
    /// tests can see what would be removed without touching any file.
    var removeDeletedImageFiles: (Set<URL>) -> Void = { urls in
        Task.detached(priority: .utility) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Allows isolated persistent stores (including SQLite regression fixtures)
    /// without falling back silently to an in-memory store.
    init(container: ModelContainer) {
        self.container = container
        seedDefaultsIfNeeded()
    }

    /// Shared authoritative entity set for normal stores and read-only archive decoding.
    static func librarySchema() -> Schema {
        Schema([
            BatchRecord.self,
            ImageRecord.self,
            DetectionRecord.self,
            CorrectionRecord.self,
            CalibrationPresetRecord.self,
            BinPresetRecord.self,
            ModelVersionRecord.self,
            ROIRecord.self,
            ConditionRecord.self,
            GroundTruthAnnotation.self,
            ReviewCandidateRecord.self,
            SegmentationVariantRecord.self,
            StoredCellsRecord.self,
        ])
    }

    init(inMemory: Bool = false) {
        let schema = Self.librarySchema()
        if inMemory {
            do {
                self.container = try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            } catch {
                fatalError("CellCounter could not create its in-memory data store: \(error)")
            }
            seedDefaultsIfNeeded()
            return
        }
        let opened = Self.openOnDiskStore(at: FileStore.shared.library, schema: schema)
        self.upgradeBackupURL = opened.backupURL
        if let container = opened.container {
            self.container = container
        } else {
            // Last-ditch fall back to in-memory if the disk store is unwritable
            // (or its pre-upgrade safety copy could not be made).
            // If even that throws it's almost certainly a schema/migration error
            // (not disk-related), so surface an actionable message instead of an
            // opaque try! trap.
            // The fallback keeps the app usable, but `diskStoreError` makes
            // the session's unsaved state visible instead of silent.
            do {
                self.container = try ModelContainer(for: schema,
                                                    configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
                self.diskStoreError = opened.error ?? "unknown error"
            } catch let memoryError {
                fatalError("""
                CellCounter could not open its data store.
                On-disk store failed: \(opened.error ?? "unknown error")
                In-memory fallback also failed: \(memoryError)
                This usually indicates a schema/migration problem rather than a disk issue. \
                Please report this with the messages above.
                """)
            }
        }
        maskVersionsKept = { MaskVersionRetention.limit(in: .standard) }
        automaticVariantCompaction = true
        seedDefaultsIfNeeded()
    }

    /// Result of `openOnDiskStore`: a container, or why there is none.
    struct OnDiskStoreOpening {
        let container: ModelContainer?
        /// Plain-language reason the store was not opened.
        let error: String?
        /// The safety copy made just before this open upgraded the store.
        let backupURL: URL?
    }

    /// Opens a library's on-disk store. A store written before
    /// `StoredCellsRecord` existed is first copied into the library's
    /// `Backups` folder while no connection to it is open
    /// (`LibraryStoreBackup`); if that copy cannot be made and verified, the
    /// store is not opened at all, so it is neither upgraded nor changed.
    static func openOnDiskStore(at layout: LibraryLayout, schema: Schema,
                                now: Date = Date()) -> OnDiskStoreOpening {
        var backup: URL?
        switch LibraryStoreBackup.makeIfNeeded(storeURL: layout.storeURL, backupsDir: layout.backupsDir, now: now) {
        case .notNeeded:
            break
        case .created(let url):
            backup = url
        case .failed(let reason):
            return OnDiskStoreOpening(container: nil, error: LibraryStoreBackup.failureMessage(reason),
                                      backupURL: nil)
        }
        let config = ModelConfiguration("CellCounter", schema: schema, url: layout.storeURL)
        do {
            return OnDiskStoreOpening(container: try ModelContainer(for: schema, configurations: [config]),
                                      error: nil, backupURL: backup)
        } catch {
            // Not upgraded after all: the copy stays, but there is no notice.
            return OnDiskStoreOpening(container: nil, error: error.localizedDescription, backupURL: nil)
        }
    }

    // MARK: — Seeding

    private func seedDefaultsIfNeeded() {
        // No calibration presets are seeded: a px/µm value is only right for
        // the microscope it was measured on (`CalibrationPreset`).
        let binCount = (try? context.fetchCount(FetchDescriptor<BinPresetRecord>())) ?? 0
        if binCount == 0 {
            context.insert(BinPresetRecord(name: "Keratinocytes — early passage", thresholds: [18, 26]))
            context.insert(BinPresetRecord(name: "Keratinocytes — late passage",  thresholds: [22, 34]))
            context.insert(BinPresetRecord(name: "Fibroblasts",                   thresholds: [24, 38]))
        }
        // Pass-10: use a UserDefaults flag so we seed the "Control" condition exactly
        // once, even if the user later deletes it. The old condCount==0 guard would
        // re-seed on every clean launch after the user removed all their conditions.
        // Decision: same pattern intentionally NOT applied to calibration/bin presets
        // because those are destructive-delete rare; conditions are routinely managed.
        let seededKey = "cc-seeded-conditions-v1"
        if !UserDefaults.standard.bool(forKey: seededKey) {
            let condCount = (try? context.fetchCount(FetchDescriptor<ConditionRecord>())) ?? 0
            if condCount == 0 {
                context.insert(ConditionRecord(name: "Control", color: "#4db3a8", order: 0))
            }
            UserDefaults.standard.set(true, forKey: seededKey)
        }
        try? context.save()
    }

    // MARK: — Batches

    func allBatches() -> [BatchRecord] {
        let desc = FetchDescriptor<BatchRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(desc)) ?? []
    }

    func recentBatchSummaries(limit: Int = 5) -> [BatchSummary] {
        var desc = FetchDescriptor<BatchRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        desc.fetchLimit = max(0, limit)
        return ((try? context.fetch(desc)) ?? []).map { batch in
            let first = firstImage(inBatch: batch.id)
            return BatchSummary(
                id: batch.id,
                displayName: batch.displayName,
                createdAt: batch.createdAt,
                // Legacy -1 summaries deliberately show 0 briefly while the
                // yielding background index catches up; Home never decodes
                // hundreds of cell blobs merely to paint Recents.
                imageCount: max(0, batch.imageCountSummary),
                cellCount: max(0, batch.cellCountSummary),
                thumbnailURL: first?.thumbURL
            )
        }
    }

    /// Earliest-imported image of a batch via a single limited fetch, so the
    /// batch's image relationship is never faulted in just to pick a thumbnail.
    func firstImage(inBatch batchId: UUID) -> ImageRecord? {
        var desc = FetchDescriptor<ImageRecord>(
            predicate: #Predicate { $0.batch?.id == batchId },
            sortBy: [SortDescriptor(\.importedAt, order: .forward)])
        desc.fetchLimit = 1
        return (try? context.fetch(desc))?.first
    }

    /// Number of corrections attached to a detection of an image that belongs
    /// to a batch; the same set a batch -> image -> detection -> corrections
    /// walk visits, answered by a count query. Written with `flatMap`: the
    /// SQLite store cannot translate a chain of two optional relationships
    /// (`$0.detection?.image?.batch`) and throws an Objective-C exception
    /// that ends the app; `flatMap` becomes two outer joins in one count.
    func reachableCorrectionCount() -> Int {
        let desc = FetchDescriptor<CorrectionRecord>(
            predicate: #Predicate<CorrectionRecord> { correction in
                correction.detection.flatMap { $0.image.flatMap { $0.batch } } != nil
            })
        return (try? context.fetchCount(desc)) ?? 0
    }

    func batch(id: UUID) -> BatchRecord? {
        let desc = FetchDescriptor<BatchRecord>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(desc).first) ?? nil
    }

    func createBatch(displayName: String, modelId: String, pxPerUm: Double,
                     thresholds: [Double], condition: String? = nil) -> BatchRecord {
        let b = BatchRecord(name: displayName, displayName: displayName,
                            modelId: modelId, pxPerUm: pxPerUm, thresholds: thresholds,
                            condition: condition)
        context.insert(b)
        try? context.save()
        return b
    }

    /// All batches tagged with a given condition name (case-sensitive match).
    func batches(matching condition: String) -> [BatchRecord] {
        let desc = FetchDescriptor<BatchRecord>(
            predicate: #Predicate { $0.condition == condition },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(desc)) ?? []
    }

    func deleteBatch(_ batch: BatchRecord) throws {
        try deleteImages(batch.images, deletingBatch: batch)
    }

    /// Pass-12: Delete every `BatchRecord` that has no images.
    /// Called at app launch (`AppState.init`). Failed imports can leave orphan
    /// empty batches behind that would otherwise litter the sidebar / Recents
    /// and trigger K4's duplicate-name disambiguator with "(1)" suffixes.
    /// No on-disk files to clean up because empty batches have no images.
    ///
    /// Reads no image rows and no other batches: candidates are batches whose
    /// stored image count is zero or unknown, plus batches with no linked image
    /// rows (in case a stored count drifted). Each candidate is confirmed with a
    /// count of the images that point at it (and its in-memory image list,
    /// which also holds unsaved images) before it is deleted, so a batch with
    /// images is never deleted. A failed read deletes nothing.
    func cleanupEmptyBatches() {
        var candidates: [UUID: BatchRecord] = [:]
        let bySummary = FetchDescriptor<BatchRecord>(predicate: #Predicate { $0.imageCountSummary <= 0 })
        for batch in (try? context.fetch(bySummary)) ?? [] { candidates[batch.id] = batch }
        let unlinked = FetchDescriptor<BatchRecord>(predicate: #Predicate { $0.images.isEmpty })
        for batch in (try? context.fetch(unlinked)) ?? [] { candidates[batch.id] = batch }

        var deleted = false
        for (batchID, batch) in candidates where !batch.isDeleted && batch.modelContext != nil {
            let linked = FetchDescriptor<ImageRecord>(predicate: #Predicate { $0.batch?.id == batchID })
            guard let imageCount = try? context.fetchCount(linked), imageCount == 0,
                  batch.images.isEmpty else { continue }
            context.delete(batch)
            deleted = true
        }
        if deleted { try? context.save() }
    }

    // MARK: — Images

    /// Returns all images across all batches, sorted by importedAt descending.
    func image(id: UUID) -> ImageRecord? {
        var query = FetchDescriptor<ImageRecord>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        return try? context.fetch(query).first
    }

    func image(jobItemId: UUID) -> ImageRecord? {
        var query = FetchDescriptor<ImageRecord>(predicate: #Predicate { $0.jobItemId == jobItemId })
        query.fetchLimit = 1
        return try? context.fetch(query).first
    }

    func allImages() -> [ImageRecord] {
        let desc = FetchDescriptor<ImageRecord>(sortBy: [SortDescriptor(\.importedAt, order: .reverse)])
        return (try? context.fetch(desc)) ?? []
    }

    // MARK: — Pass-17: Duplicate detection

    /// Returns all duplicate groups: groups of 2+ ImageRecords sharing the same fileHash.
    /// Images with fileHash == nil are excluded (not yet hashed).
    func duplicateGroups() -> [[ImageRecord]] {
        let all = allImages()
        var byHash: [String: [ImageRecord]] = [:]
        for img in all {
            guard let hash = img.fileHash else { continue }
            byHash[hash, default: []].append(img)
        }
        return byHash.values
            .filter { $0.count >= 2 }
            .sorted { ($0.first?.fileName ?? "") < ($1.first?.fileName ?? "") }
    }

    /// Returns all images that have no fileHash (need back-filling).
    func imagesNeedingHash() -> [ImageRecord] {
        let desc = FetchDescriptor<ImageRecord>(
            predicate: #Predicate { $0.fileHash == nil },
            sortBy: [SortDescriptor(\.importedAt, order: .reverse)])
        return (try? context.fetch(desc)) ?? []
    }

    // MARK: — Import duplicate lookup

    /// For each of `hashes` found in the library, the image that `allImages()`
    /// lists first with that `fileHash` (newest import first). Uses the
    /// `fileHash` index, a chunk of hashes per query, instead of loading
    /// every image.
    func firstImagesByFileHash(_ hashes: Set<String>, chunkSize: Int = 500) -> [String: ImageRecord] {
        let all = Array(hashes)
        let size = max(1, chunkSize)
        var result: [String: ImageRecord] = [:]
        for start in stride(from: 0, to: all.count, by: size) {
            let chunk: [String?] = all[start..<min(start + size, all.count)].map { Optional($0) }
            let desc = FetchDescriptor<ImageRecord>(
                predicate: #Predicate { chunk.contains($0.fileHash) },
                sortBy: [SortDescriptor(\.importedAt, order: .reverse)])
            for image in (try? context.fetch(desc)) ?? [] {
                guard let hash = image.fileHash, result[hash] == nil else { continue }
                result[hash] = image
            }
        }
        return result
    }

    /// Deletes one image without making the caller wait for filesystem cleanup.
    func deleteImage(_ image: ImageRecord) throws {
        try deleteImages([image])
    }

    /// Removes a selection in one database transaction. Potentially large
    /// source files are unlinked on a utility worker after their URLs have
    /// been snapshotted, keeping bulk Library deletion responsive.
    func deleteImages(_ images: [ImageRecord]) throws {
        try deleteImages(images, deletingBatch: nil)
    }

    /// One transaction for the whole selection: `deleteBatch` callers (archive
    /// in particular) rely on all-or-nothing, so this is deliberately not split.
    private func deleteImages(_ images: [ImageRecord], deletingBatch batchToDelete: BatchRecord?) throws {
        // Preserve unrelated pending work before a deletion that may roll back.
        try context.save()
        var seen = Set<UUID>()
        let targets = images.filter {
            !$0.isDeleted && $0.modelContext != nil && seen.insert($0.id).inserted
        }
        var fileURLs = Set<URL>()
        for image in targets where !image.fileName.isEmpty {
            fileURLs.insert(image.storedURL)
            fileURLs.insert(image.displayURL)
            fileURLs.insert(image.thumbURL)
        }
        do {
            try deleteImageAuxiliaryRecords(forImageIds: targets.map(\.id))
            if batchToDelete == nil { subtractFromBatchSummaries(targets) }
            for image in targets { context.delete(image) }
            if let batchToDelete { context.delete(batchToDelete) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        // A failed database save must never leave persisted owners with their
        // source files removed. Only unlink files after the deletion commits.
        removeDeletedImageFiles(fileURLs)
    }

    /// Takes the images out of their batches' stored totals. A detection's
    /// cell count is read only when its batch total is known, from the stored
    /// summary; only a legacy detection without one is decoded, as before.
    /// The images' detections are loaded in one query rather than one each.
    private func subtractFromBatchSummaries(_ images: [ImageRecord]) {
        let counted = images.filter { ($0.batch?.cellCountSummary ?? -1) >= 0 }
        let detectionIDs = counted.compactMap { $0.detection?.persistentModelID }
        for start in stride(from: 0, to: detectionIDs.count, by: Self.idQueryChunk) {
            let chunk = Array(detectionIDs[start..<min(start + Self.idQueryChunk, detectionIDs.count)])
            // Only a prefetch: on failure each detection is read on first use.
            _ = try? context.fetch(FetchDescriptor<DetectionRecord>(
                predicate: #Predicate { chunk.contains($0.persistentModelID) }))
        }
        for image in images {
            guard let batch = image.batch else { continue }
            if batch.imageCountSummary >= 0 {
                batch.imageCountSummary = max(0, batch.imageCountSummary - 1)
            }
            if batch.cellCountSummary >= 0 {
                let removedCells = image.detection?.summaryCellCount ?? 0
                batch.cellCountSummary = max(0, batch.cellCountSummary - removedCells)
            }
            batch.contentRevision &+= 1
        }
    }

    func attach(image: ImageRecord, to batch: BatchRecord, save: Bool = true) {
        image.batch = batch
        batch.images.append(image)
        if batch.imageCountSummary >= 0 { batch.imageCountSummary += 1 }
        batch.contentRevision &+= 1
        if save { try? context.save() }
    }

    /// Encodes and compresses `cells` on the calling actor; fine for tests and
    /// single small saves. Bulk paths use `saveDetection(snapshot:cells:…)`.
    func saveDetection(_ cells: [DetectedCell], detectorId: String, for image: ImageRecord,
                       imageStats: [String: Double]? = nil,
                       runSettings: AnalysisRunSettings? = nil,
                       save: Bool = true) {
        saveDetection(snapshot: DetectionRecord.makeStorageSnapshot(cells), cells: cells,
                      detectorId: detectorId, for: image, imageStats: imageStats,
                      runSettings: runSettings, save: save)
    }

    /// Same as `saveDetection(_:…)` with the cell blob already prepared by
    /// `DetectionRecord.makeStorageSnapshot(cells)` on a detached task: the
    /// main actor only links rows and indexes the review candidates.
    func saveDetection(snapshot: DetectionRecord.CellsStorageSnapshot, cells: [DetectedCell],
                       detectorId: String, for image: ImageRecord,
                       imageStats: [String: Double]? = nil,
                       runSettings: AnalysisRunSettings? = nil,
                       save: Bool = true) {
        // Reassigning the to-one relationship only nulls the old record's inverse;
        // it does not delete the orphan. Explicitly delete the superseded detection
        // so re-runs don't leave stale DetectionRecords in the store (which would
        // inflate uncorrectedCellCount(below:) / the Review badge).
        let previousCount = image.detection?.summaryCellCount ?? 0
        if let old = image.detection {
            // The previous mask's stored bytes are kept as they are, compressed
            // or not; its stored content hash lets them be de-duplicated as is.
            saveSegmentationVariant(image: image,
                                    detectorId: old.detectorId,
                                    label: "Before \(detectorId)",
                                    stored: old.cellsData,
                                    contentHash: old.cellsContentHash,
                                    cellCount: old.summaryCellCount,
                                    meanConfidence: Self.knownMeanConfidence(of: old),
                                    save: false)
            deleteReviewCandidates(forDetectionId: old.id)
            context.delete(old)
        }
        let det = DetectionRecord(detectorId: detectorId, storage: snapshot, cells: cells,
                                  imageStats: imageStats ?? [:])
        det.runSettings = runSettings
        det.image = image
        image.detection = det
        context.insert(det)
        noteUpkeepWork(for: det)
        indexReviewCandidates(cells: cells, detection: det, image: image)
        if let batch = image.batch {
            if batch.cellCountSummary >= 0 {
                batch.cellCountSummary += cells.count - previousCount
            }
            batch.contentRevision &+= 1
        }
        if save { try? context.save() }
    }

    // MARK: — Segmentation variants / mask curation

    /// Every listed field except the stored masks, so listing versions never
    /// loads cell blobs. `cellsData` is read on first access (Compare / Use).
    private static let variantListProperties: [PartialKeyPath<SegmentationVariantRecord>] = [
        \.id, \.imageId, \.detectorId, \.label, \.createdAt, \.cellCount, \.meanConfidence,
        \.measurementPxPerUm, \.detectionRanAt, \.contentHash, \.storageFormat,
    ]

    /// Newest first, without their cell blobs.
    func segmentationVariants(for imageId: UUID) -> [SegmentationVariantRecord] {
        var desc = FetchDescriptor<SegmentationVariantRecord>(
            predicate: #Predicate { $0.imageId == imageId },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        desc.propertiesToFetch = Self.variantListProperties
        return (try? context.fetch(desc)) ?? []
    }

    func segmentationVariantSummaries(for imageId: UUID) -> [SegmentationVariantSummary] {
        segmentationVariants(for: imageId).map(SegmentationVariantSummary.init)
    }

    func segmentationVariant(id: UUID) -> SegmentationVariantRecord? {
        var desc = FetchDescriptor<SegmentationVariantRecord>(predicate: #Predicate { $0.id == id })
        desc.fetchLimit = 1
        return (try? context.fetch(desc))?.first(where: { !$0.isDeleted })
    }

    @discardableResult
    func saveSegmentationVariant(image: ImageRecord, detectorId: String,
                                 label: String, cells: [DetectedCell],
                                 save: Bool = true) -> SegmentationVariantRecord {
        let snapshot = DetectionRecord.makeStorageSnapshot(cells)
        return saveSegmentationVariant(image: image, detectorId: detectorId, label: label,
                                       stored: snapshot.data, contentHash: snapshot.contentHash,
                                       cellCount: snapshot.count,
                                       meanConfidence: SegmentationVariantRecord.meanConfidence(of: cells),
                                       save: save)
    }

    /// Saves already-encoded plain-JSON cell bytes as a mask version; see
    /// `saveSegmentationVariant(image:detectorId:label:stored:contentHash:…)`.
    @discardableResult
    func saveSegmentationVariant(image: ImageRecord, detectorId: String, label: String,
                                 plainJSON: Data, cellCount: Int, meanConfidence: Double?,
                                 save: Bool = true) -> SegmentationVariantRecord {
        saveSegmentationVariant(image: image, detectorId: detectorId, label: label,
                                stored: plainJSON, contentHash: nil, cellCount: cellCount,
                                meanConfidence: meanConfidence, save: save)
    }

    /// Saves already-encoded cell bytes (plain or compressed JSON) as a mask
    /// version, without decoding or re-encoding them. When the image already
    /// has a version with the same content, that version is moved to the top
    /// (its date becomes now, its label stays) instead of being stored twice.
    /// The image's oldest versions beyond `maskVersionsKept()` are then
    /// removed. A nil `meanConfidence` is stored as -1 ("not computed yet").
    @discardableResult
    func saveSegmentationVariant(image: ImageRecord, detectorId: String, label: String,
                                 stored: Data, contentHash: String?, cellCount: Int,
                                 meanConfidence: Double?, save: Bool = true) -> SegmentationVariantRecord {
        let variant = storeSegmentationVariant(image: image, detectorId: detectorId, label: label,
                                               stored: stored, contentHash: contentHash,
                                               cellCount: cellCount, meanConfidence: meanConfidence)
        enforceMaskVersionLimit(imageId: image.id, keeping: variant)
        if save { try? context.save() }
        scheduleVariantCompaction()
        return variant
    }

    /// Inserts a version, or refreshes the existing one with identical content.
    /// Content hashes are over plain JSON: `contentHash` when the caller knows
    /// it, else computed here for plain bytes. Compressed bytes with no known
    /// hash are not decompressed on the main actor; they are saved without a
    /// hash, which the background upkeep fills in, and are not matched.
    private func storeSegmentationVariant(image: ImageRecord, detectorId: String, label: String,
                                          stored: Data, contentHash: String?, cellCount: Int,
                                          meanConfidence: Double?) -> SegmentationVariantRecord {
        let hash = contentHash ?? (CellsBlobCodec.isCompressed(stored) ? nil : CellsBlobCodec.sha256Hex(stored))
        let imageId = image.id
        if let hash {
            var match = FetchDescriptor<SegmentationVariantRecord>(
                predicate: #Predicate { $0.imageId == imageId && $0.contentHash == hash })
            match.propertiesToFetch = [\.id, \.createdAt, \.meanConfidence]
            match.fetchLimit = 1
            if let existing = (try? context.fetch(match))?.first(where: { !$0.isDeleted }) {
                existing.createdAt = Date()
                if existing.meanConfidence < 0, let meanConfidence { existing.meanConfidence = meanConfidence }
                return existing
            }
        }
        let variant = SegmentationVariantRecord(image: image, detectorId: detectorId, label: label,
                                                plainJSON: stored, cellCount: cellCount,
                                                meanConfidence: meanConfidence ?? -1,
                                                contentHash: hash)
        // The scale the image's current measurements are at (`measuredScale`).
        variant.measurementPxPerUm = image.measuredScale?.pxPerUm ?? image.batch?.pxPerUm
        variant.runSettingsData = image.detection?.runSettingsData
        variant.imageStatsData = image.detection?.imageStatsData
        variant.detectionRanAt = image.detection?.ranAt
        context.insert(variant)
        noteUpkeepWork(for: variant)
        return variant
    }

    /// The mean confidence of a detection's cells if they are already decoded
    /// (shared decode cache); nil rather than decoding the blob on the main actor.
    private static func knownMeanConfidence(of detection: DetectionRecord) -> Double? {
        guard let cells = detection.cachedCells, cells.count == detection.cellCountSummary else { return nil }
        return SegmentationVariantRecord.meanConfidence(of: cells)
    }

    /// Makes a saved version the live mask, and keeps the mask it replaces as
    /// a saved version (reusing an identical one if present). The used version
    /// is then removed from the list, since its content is now the live mask:
    /// switching back and forth swaps the two instead of piling up copies.
    /// Returns nil, changing nothing, when the version cannot be read.
    func applySegmentationVariant(_ variant: SegmentationVariantRecord,
                                  to image: ImageRecord) -> CellEditCommitResult? {
        guard let detection = image.detection,
              !variant.isDeleted, variant.modelContext != nil else { return nil }
        // Read everything needed from the chosen version before any change.
        let variantStored = variant.cellsData
        guard let plain = try? CellsBlobCodec.plainJSON(variantStored),
              var cells = try? DetectionRecord.decodeCellsDataForReview(plain) else { return nil }
        let variantHash = variant.contentHash ?? CellsBlobCodec.sha256Hex(plain)
        let variantID = variant.id
        let variantLabel = variant.label
        let variantDetectorId = variant.detectorId
        let variantRunSettings = variant.runSettingsData
        let variantImageStats = variant.imageStatsData
        let variantRanAt = variant.detectionRanAt ?? variant.createdAt
        let variantScale = variant.measurementPxPerUm

        let oldPendingReviewCount = max(0, detection.reviewPendingCount)
        let current = storeSegmentationVariant(image: image,
                                               detectorId: detection.detectorId,
                                               label: "Before applying \(variantLabel)",
                                               stored: detection.cellsData,
                                               contentHash: detection.cellsContentHash,
                                               cellCount: detection.summaryCellCount,
                                               meanConfidence: Self.knownMeanConfidence(of: detection))

        let oldCount = detection.summaryCellCount
        var rescaled = false
        // A version measured at another scale is converted to the scale the
        // image's measurements use now; its outlines (pixels) are kept.
        if let oldScale = variantScale, let newScale = image.measuredScale?.pxPerUm ?? image.batch?.pxPerUm,
           oldScale > 0, newScale > 0, oldScale != newScale {
            let ratio = oldScale / newScale
            for index in cells.indices {
                cells[index].diameter = cells[index].diameterPx / newScale
                cells[index].centroidUmX = cells[index].cx / newScale
                cells[index].centroidUmY = cells[index].cy / newScale
                if let area = cells[index].areaMicrons2 { cells[index].areaMicrons2 = area * ratio * ratio }
                if let perimeter = cells[index].perimeterMicrons { cells[index].perimeterMicrons = perimeter * ratio }
            }
            rescaled = true
        }
        // Unscaled versions go live with their own stored bytes (compressed or
        // not), so using a version and switching back reproduces identical
        // content without encoding or compressing anything here.
        let storage = rescaled
            ? DetectionRecord.makeStorageSnapshot(cells)
            : DetectionRecord.CellsStorageSnapshot(data: variantStored,
                                                   minimumConfidence: cells.map(\.confidence).min() ?? 1.0,
                                                   count: cells.count, contentHash: variantHash,
                                                   cellMetrics: CellMetricsCodec.encode(cells))
        detection.applyStorageSnapshot(storage)
        noteUpkeepWork(for: detection)
        detection.cacheDecodedCells(cells, revision: detection.cellsRevision)
        detection.detectorId = variantDetectorId
        detection.runSettingsData = variantRunSettings
        detection.imageStatsData = variantImageStats
        detection.ranAt = variantRanAt
        deleteReviewCandidates(forDetectionId: detection.id)
        indexReviewCandidates(cells: cells, detection: detection, image: image)
        if let batch = image.batch {
            if batch.cellCountSummary >= 0 {
                batch.cellCountSummary += cells.count - oldCount
            }
            batch.contentRevision &+= 1
        }
        // The used version is now the live mask. (If the live mask already
        // had the same content, `current` is this same record.)
        context.delete(variant)
        if current.id != variantID {
            enforceMaskVersionLimit(imageId: image.id, keeping: current)
        }
        try? context.save()
        scheduleVariantCompaction()
        // A version saved before compression goes live as plain JSON.
        scheduleDetectionStorageMigration()
        return CellEditCommitResult(
            corrections: [],
            reviewCountDelta: detection.reviewPendingCount - oldPendingReviewCount)
    }

    func deleteSegmentationVariant(_ variant: SegmentationVariantRecord) {
        context.delete(variant)
        try? context.save()
    }

    // MARK: — Saved mask version limit

    /// Deletes the image's oldest saved versions beyond `maskVersionsKept()`,
    /// never `newest`. Reads only ids and dates. The live detection is a
    /// separate record and is never touched.
    private func enforceMaskVersionLimit(imageId: UUID, keeping newest: SegmentationVariantRecord) {
        let limit = maskVersionsKept()
        guard limit > 0 else { return }
        var desc = FetchDescriptor<SegmentationVariantRecord>(
            predicate: #Predicate { $0.imageId == imageId })
        desc.propertiesToFetch = [\.id, \.createdAt]
        guard var rows = try? context.fetch(desc) else { return }
        rows.removeAll { $0.isDeleted }
        // An unsaved insert may or may not be part of the fetch result.
        let newestID = newest.id
        if !rows.contains(where: { $0.id == newestID }) { rows.append(newest) }
        guard rows.count > limit else { return }
        // Sorted in memory so a date refreshed but not yet saved counts.
        rows.sort { $0.createdAt > $1.createdAt }
        for row in rows.dropFirst(limit) where row.id != newestID {
            context.delete(row)
        }
    }

    /// Ids of saved versions beyond `limit` per image (oldest first within an
    /// image), read with ids, image ids and dates only.
    func excessSegmentationVariantIDs(keeping limit: Int) throws -> [UUID] {
        guard limit > 0 else { return [] }
        var desc = FetchDescriptor<SegmentationVariantRecord>()
        desc.propertiesToFetch = [\.id, \.imageId, \.createdAt]
        let rows = try context.fetch(desc)
            .filter { !$0.isDeleted }
            .sorted { $0.createdAt > $1.createdAt }
        var kept: [UUID: Int] = [:]
        var excess: [UUID] = []
        for row in rows {
            let count = kept[row.imageId, default: 0]
            if count >= limit { excess.append(row.id) } else { kept[row.imageId] = count + 1 }
        }
        return excess
    }

    /// Settings → "Remove older versions now". Deletes in small chunks with a
    /// save and a short pause after each. A version saved or moved to the top
    /// after the count was taken is left alone. Returns how many were removed.
    @discardableResult
    func removeExcessSegmentationVariants(keeping limit: Int, chunkSize: Int = 200) async throws -> Int {
        let countedAt = Date()
        let ids = try excessSegmentationVariantIDs(keeping: limit)
        var removed = 0
        var start = 0
        while start < ids.count {
            try Task.checkCancellation()
            let chunk = Array(ids[start..<min(start + max(1, chunkSize), ids.count)])
            var desc = FetchDescriptor<SegmentationVariantRecord>(
                predicate: #Predicate { chunk.contains($0.id) })
            desc.propertiesToFetch = [\.id, \.createdAt]
            for row in try context.fetch(desc) where !row.isDeleted && row.createdAt <= countedAt {
                context.delete(row)
                removed += 1
            }
            try context.save()
            start += chunk.count
            await LibraryTransferPacing.breathe()
        }
        if removed > 0 {
            NotificationCenter.default.post(name: .ccMaskVersionsChanged, object: nil)
        }
        return removed
    }

    // MARK: — Background upkeep: reported work and passes

    /// Outcome of one upkeep pass: rows written, and whether it went through
    /// all of its work (false when cancelled or held by archive/restore).
    struct UpkeepPassResult {
        var count: Int
        var finished: Bool
    }

    /// Reports what a detection that was just written still leaves to
    /// background upkeep: cells inline, stored plain or without a content
    /// hash, or metrics not written by the current codec. Write paths call it
    /// right after the write, in the same main-actor step, so a pass that
    /// starts later finds the rows.
    func noteUpkeepWork(for detection: DetectionRecord) {
        guard !detection.isDeleted else { return }
        if let storage = detection.cellsStorage {
            if storage.storageFormat == CellsBlobCodec.plainJSONFormat || storage.contentHash == nil {
                upkeepNote.noteWork(.detectionCellStorage, ids: [storage.id])
                scheduleDetectionStorageMigration()
            }
        } else {
            upkeepNote.noteWork(.detectionCellStorage, ids: [detection.id])
            scheduleDetectionStorageMigration()
        }
        if detection.cellMetricsVersion != CellMetricsCodec.version {
            upkeepNote.noteWork(.cellMetrics, ids: [detection.id])
            onCellMetricsWork?()
        }
    }

    /// Reports a saved mask version that is still plain JSON, has no content
    /// hash or has no mean confidence yet.
    func noteUpkeepWork(for variant: SegmentationVariantRecord) {
        guard !variant.isDeleted, Self.variantNeedsUpkeep(variant) else { return }
        upkeepNote.noteWork(.maskVersions, ids: [variant.id])
        scheduleVariantCompaction()
    }

    /// Rows came in whose upkeep state is not known (a restored archive, which
    /// may come from an older version): every job reads its whole query once
    /// more. The jobs start once the restore releases its hold.
    func noteRestoredRows() {
        for job in BackgroundUpkeepNote.Job.allCases { upkeepNote.noteUnknownWork(job) }
        scheduleVariantCompaction()
        scheduleDetectionStorageMigration()
        onCellMetricsWork?()
    }

    /// Runs one pass of `job` over `work` and reports the outcome to the
    /// note: an unfinished or failed pass gives its work back, a finished one
    /// records the job as done unless new work was reported meanwhile.
    func runUpkeepPass(_ job: BackgroundUpkeepNote.Job, work: BackgroundUpkeepNote.Work,
                       _ body: (BackgroundUpkeepNote.Work) async throws -> UpkeepPassResult)
        async throws -> UpkeepPassResult {
        do {
            let result = try await body(work)
            upkeepNote.endPass(job, work, finished: result.finished)
            return result
        } catch {
            upkeepNote.endPass(job, work, finished: false)
            throw error
        }
    }

    /// Ids of the rows a pass visits, each once. A full pass reads the job's
    /// query once, ids only (it still reads each row up to the queried
    /// columns); chunks are then fetched by id through the unique `id`
    /// index, so the pass never re-reads rows it has already passed, however
    /// many rows stay unprocessed (unreadable ones). Reported rows are used as
    /// given; rows deleted since are simply not found.
    func upkeepCandidateIDs<T: PersistentModel>(_ work: BackgroundUpkeepNote.Work,
                                                query: Predicate<T>,
                                                id: KeyPath<T, UUID>) throws -> [UUID] {
        switch work {
        case .rows(let ids):
            return ids.sorted { $0.uuidString < $1.uuidString }
        case .all:
            var descriptor = FetchDescriptor<T>(predicate: query)
            descriptor.propertiesToFetch = [id]
            return try context.fetch(descriptor).filter { !$0.isDeleted }.map { $0[keyPath: id] }
        }
    }

    // MARK: — Saved mask version upkeep

    /// Plain JSON, mean confidence not computed, or no content hash yet.
    private static let variantUpkeepQuery: Predicate<SegmentationVariantRecord> = {
        let plainFormat: Int = CellsBlobCodec.plainJSONFormat
        let noMean: Double = 0
        return #Predicate<SegmentationVariantRecord> { (variant: SegmentationVariantRecord) -> Bool in
            variant.storageFormat == plainFormat || variant.meanConfidence < noMean || variant.contentHash == nil
        }
    }()

    /// `variantUpkeepQuery` for a row in hand.
    static func variantNeedsUpkeep(_ variant: SegmentationVariantRecord) -> Bool {
        variant.storageFormat == CellsBlobCodec.plainJSONFormat || variant.meanConfidence < 0
            || variant.contentHash == nil
    }

    /// Compresses saved versions still stored as plain JSON and fills in
    /// missing content hashes and mean confidences. Reads a few rows at a
    /// time on the main actor, decodes/hashes/compresses them on a detached
    /// task, and writes back only rows that still exist with unchanged bytes,
    /// saving after each chunk. Idempotent and cancellable at any point;
    /// rows that cannot be read are skipped and left as they are. Returns
    /// how many rows were updated. `pause` spaces chunks out further.
    ///
    /// Always a full pass over every matching row; the automatic background
    /// run (`scheduleVariantCompaction()`) instead does only what
    /// `upkeepNote` reports.
    @discardableResult
    func compactSegmentationVariants(chunkSize: Int = 4, pause: Duration? = nil) async throws -> Int {
        try await runUpkeepPass(.maskVersions, work: upkeepNote.beginFullPass(.maskVersions)) {
            try await compactSegmentationVariants($0, chunkSize: chunkSize, pause: pause)
        }.count
    }

    /// One pass over the mask-version work `upkeepNote` reports (nothing when
    /// it records the job as done). Returns whether it went through all of it.
    func compactReportedSegmentationVariants(chunkSize: Int = 4, pause: Duration? = nil) async throws -> Bool {
        try await runUpkeepPass(.maskVersions, work: upkeepNote.beginPass(.maskVersions)) {
            try await compactSegmentationVariants($0, chunkSize: chunkSize, pause: pause)
        }.finished
    }

    private func compactSegmentationVariants(_ work: BackgroundUpkeepNote.Work, chunkSize: Int,
                                             pause: Duration?) async throws -> UpkeepPassResult {
        guard !Task.isCancelled, variantCompactionHolds == 0 else { return UpkeepPassResult(count: 0, finished: false) }
        var queue = UpkeepIDQueue(try upkeepCandidateIDs(work, query: Self.variantUpkeepQuery,
                                                         id: \SegmentationVariantRecord.id))
        var updated = 0
        while let chunk = queue.nextChunk(size: chunkSize) {
            guard !Task.isCancelled, variantCompactionHolds == 0 else {
                return UpkeepPassResult(count: updated, finished: false)
            }
            let rows = try context.fetch(FetchDescriptor<SegmentationVariantRecord>(
                predicate: #Predicate { chunk.contains($0.id) }))
                .filter { !$0.isDeleted && Self.variantNeedsUpkeep($0) }
            upkeepVisitObserver?(.maskVersions, rows.map(\.id))
            guard !rows.isEmpty else { continue }
            let inputs = rows.map {
                MaskVersionCompaction.Input(id: $0.id, stored: $0.cellsData,
                                            needsMeanConfidence: $0.meanConfidence < 0)
            }
            let outputs = await Task.detached(priority: .utility) {
                inputs.compactMap(MaskVersionCompaction.process)
            }.value
            guard !Task.isCancelled, variantCompactionHolds == 0 else {
                return UpkeepPassResult(count: updated, finished: false)
            }

            var results: [UUID: MaskVersionCompaction.Output] = [:]
            for output in outputs { results[output.id] = output }
            var written = 0
            var meanFilled = false
            for (row, input) in zip(rows, inputs) {
                // A row may have been deleted (check before reading it) or
                // changed while the chunk was being processed.
                guard !row.isDeleted, row.modelContext === context else { continue }
                guard row.cellsData == input.stored else {
                    // Changed while the chunk was processed: try once more.
                    if Self.variantNeedsUpkeep(row) { queue.requeue(row.id) }
                    continue
                }
                // Unreadable rows (no output) are left exactly as they are.
                if let output = results[input.id] {
                    if row.cellsData != output.stored { row.cellsData = output.stored }
                    if row.storageFormat != output.storageFormat { row.storageFormat = output.storageFormat }
                    if row.contentHash != output.contentHash { row.contentHash = output.contentHash }
                    if row.meanConfidence < 0, let mean = output.meanConfidence {
                        row.meanConfidence = mean
                        meanFilled = true
                    }
                    written += 1
                }
            }
            if written > 0 {
                try context.save()
                updated += written
            }
            if meanFilled {
                NotificationCenter.default.post(name: .ccMaskVersionsChanged, object: nil)
            }
            await Self.pauseUpkeep(pause)
        }
        return UpkeepPassResult(count: updated, finished: !Task.isCancelled && variantCompactionHolds == 0)
    }

    /// Debounced start of the automatic mask-version upkeep; does nothing
    /// unless `automaticVariantCompaction` is on, and starts no pass while
    /// `upkeepNote` records the job as done.
    func scheduleVariantCompaction(after delay: Duration = .seconds(2)) {
        guard automaticVariantCompaction else { return }
        variantCompactionDebounce?.cancel()
        variantCompactionDebounce = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.variantCompactionDebounce = nil
            self.startVariantCompactionIfIdle()
        }
    }

    private func startVariantCompactionIfIdle() {
        // A running task takes work reported meanwhile in its next pass.
        guard variantCompactionTask == nil, variantCompactionHolds == 0,
              upkeepNote.needsRun(.maskVersions) else { return }
        variantCompactionGeneration &+= 1
        let generation = variantCompactionGeneration
        variantCompactionTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.upkeepNote.needsRun(.maskVersions) {
                let finished = try? await self.compactReportedSegmentationVariants(pause: .milliseconds(40))
                guard finished == true else { break }
            }
            if self.variantCompactionGeneration == generation { self.variantCompactionTask = nil }
        }
    }

    /// Stops both kinds of background upkeep; each resumes when next scheduled.
    func cancelVariantCompaction() {
        variantCompactionDebounce?.cancel()
        variantCompactionDebounce = nil
        variantCompactionTask?.cancel()
        variantCompactionTask = nil
        variantCompactionGeneration &+= 1
        detectionStorageDebounce?.cancel()
        detectionStorageDebounce = nil
        detectionStorageTask?.cancel()
        detectionStorageTask = nil
        detectionStorageGeneration &+= 1
    }

    /// Archive and restore compare every stored field of the rows they copy;
    /// the upkeep of mask versions and of detection cell storage pauses while
    /// one of them runs and resumes afterwards.
    func holdVariantCompaction() {
        variantCompactionHolds += 1
        variantCompactionDebounce?.cancel()
        variantCompactionDebounce = nil
        detectionStorageDebounce?.cancel()
        detectionStorageDebounce = nil
    }

    /// Resumes upkeep paused by `holdVariantCompaction()`. Only jobs with work
    /// start: a restore reports its rows (`noteRestoredRows()`), and work
    /// reported or interrupted while held is still pending.
    func releaseVariantCompaction() {
        variantCompactionHolds = max(0, variantCompactionHolds - 1)
        if variantCompactionHolds == 0 {
            scheduleVariantCompaction()
            scheduleDetectionStorageMigration()
        }
    }

    /// True while archive or restore holds background upkeep. The cell-metrics
    /// backfill (`CellMetricsBackfill.swift`) waits on it too.
    var isBackgroundUpkeepHeld: Bool { variantCompactionHolds > 0 }

    // MARK: — Detection cell storage upkeep

    /// Cells still inline in the detection row.
    private static let detectionCellsInline: Predicate<DetectionRecord> = #Predicate { $0.cellsStorage == nil }

    /// Separate rows still plain JSON or without a content hash.
    private static let storedCellsNeedUpkeep: Predicate<StoredCellsRecord> = {
        let plainFormat: Int = CellsBlobCodec.plainJSONFormat
        return #Predicate<StoredCellsRecord> { $0.storageFormat == plainFormat || $0.contentHash == nil }
    }()

    /// Moves cell bytes still stored inline in `DetectionRecord` rows (written
    /// before `StoredCellsRecord` existed) into their own row, compressed and
    /// with their content hash; then compresses and hashes separate rows
    /// still stored as plain JSON or without a hash (restored from older
    /// archives, versions used before they were compacted). Reads a few rows
    /// at a time on the main actor and compresses them on a detached task.
    /// A row is written back only if it still exists with the same
    /// `cellsRevision` and bytes; moving it and emptying the inline column
    /// happen in the same save. Idempotent and resumable: the getter prefers
    /// the separate row and otherwise reads the inline bytes, so stopping at
    /// any point (cancel, hold, crash) leaves every detection readable.
    /// Decoded cells are unchanged: every compressed blob must decompress to
    /// the original bytes, and a blob that cannot be read is moved as is.
    /// Returns how many rows were written.
    ///
    /// Always a full pass over every matching row; the automatic background
    /// run (`scheduleDetectionStorageMigration()`) instead does only what
    /// `upkeepNote` reports.
    @discardableResult
    func migrateDetectionCellStorage(chunkSize: Int = 4, pause: Duration? = nil) async throws -> Int {
        try await runUpkeepPass(.detectionCellStorage, work: upkeepNote.beginFullPass(.detectionCellStorage)) {
            try await migrateDetectionCellStorage($0, chunkSize: chunkSize, pause: pause)
        }.count
    }

    /// One pass over the cell-storage work `upkeepNote` reports (nothing when
    /// it records the job as done). Returns whether it went through all of it.
    func migrateReportedDetectionCellStorage(chunkSize: Int = 4, pause: Duration? = nil) async throws -> Bool {
        try await runUpkeepPass(.detectionCellStorage, work: upkeepNote.beginPass(.detectionCellStorage)) {
            try await migrateDetectionCellStorage($0, chunkSize: chunkSize, pause: pause)
        }.finished
    }

    /// Reported rows may be detections (cells inline) or their separate
    /// cell rows; each phase finds the ids of its own table.
    private func migrateDetectionCellStorage(_ work: BackgroundUpkeepNote.Work, chunkSize: Int,
                                             pause: Duration?) async throws -> UpkeepPassResult {
        var updated = 0
        // 1. Cells still inline in the detection row.
        guard !Task.isCancelled, variantCompactionHolds == 0 else { return UpkeepPassResult(count: 0, finished: false) }
        var inline = UpkeepIDQueue(try upkeepCandidateIDs(work, query: Self.detectionCellsInline,
                                                          id: \DetectionRecord.id))
        while let chunk = inline.nextChunk(size: chunkSize) {
            guard !Task.isCancelled, variantCompactionHolds == 0 else {
                return UpkeepPassResult(count: updated, finished: false)
            }
            let rows = try context.fetch(FetchDescriptor<DetectionRecord>(
                predicate: #Predicate { chunk.contains($0.id) }))
                .filter { !$0.isDeleted && $0.cellsStorage == nil }
            upkeepVisitObserver?(.detectionCellStorage, rows.map(\.id))
            guard !rows.isEmpty else { continue }
            let revisions = rows.map(\.cellsRevision)
            let inputs = rows.map {
                MaskVersionCompaction.Input(id: $0.id, stored: $0.legacyCellsData, needsMeanConfidence: false)
            }
            let outputs = await Self.compactCells(inputs)
            guard !Task.isCancelled, variantCompactionHolds == 0 else {
                return UpkeepPassResult(count: updated, finished: false)
            }
            var written = 0
            for (index, row) in rows.enumerated() {
                let input = inputs[index]
                if !row.isDeleted, row.modelContext === context, row.cellsStorage == nil,
                   row.cellsRevision == revisions[index], row.legacyCellsData == input.stored {
                    // Unreadable bytes are moved exactly as they are.
                    let output = outputs[input.id]
                    row.storeCells(output?.stored ?? input.stored, contentHash: output?.contentHash)
                    written += 1
                } else if !row.isDeleted, row.modelContext === context, row.cellsStorage == nil {
                    // Changed while the chunk was processed: try once more.
                    inline.requeue(row.id)
                }
            }
            if written > 0 {
                try context.save()
                updated += written
            }
            await Self.pauseUpkeep(pause)
        }

        // 2. Separate rows still plain JSON or without a content hash. Read
        // after phase 1, which can add such rows.
        guard !Task.isCancelled, variantCompactionHolds == 0 else {
            return UpkeepPassResult(count: updated, finished: false)
        }
        let plainFormat: Int = CellsBlobCodec.plainJSONFormat
        var stored = UpkeepIDQueue(try upkeepCandidateIDs(work, query: Self.storedCellsNeedUpkeep,
                                                          id: \StoredCellsRecord.id))
        while let chunk = stored.nextChunk(size: chunkSize) {
            guard !Task.isCancelled, variantCompactionHolds == 0 else {
                return UpkeepPassResult(count: updated, finished: false)
            }
            let rows = try context.fetch(FetchDescriptor<StoredCellsRecord>(
                predicate: #Predicate { chunk.contains($0.id) }))
                .filter { !$0.isDeleted && ($0.storageFormat == plainFormat || $0.contentHash == nil) }
            upkeepVisitObserver?(.detectionCellStorage, rows.map(\.id))
            guard !rows.isEmpty else { continue }
            let revisions = rows.map { $0.detection?.cellsRevision }
            let inputs = rows.map {
                MaskVersionCompaction.Input(id: $0.id, stored: $0.data, needsMeanConfidence: false)
            }
            let outputs = await Self.compactCells(inputs)
            guard !Task.isCancelled, variantCompactionHolds == 0 else {
                return UpkeepPassResult(count: updated, finished: false)
            }
            var written = 0
            for (index, row) in rows.enumerated() {
                let input = inputs[index]
                guard !row.isDeleted, row.modelContext === context else { continue }
                guard let output = outputs[input.id], let detection = row.detection,
                      !detection.isDeleted else { continue }
                if detection.cellsRevision == revisions[index], row.data == input.stored {
                    if output.stored != row.data || output.contentHash != row.contentHash {
                        detection.storeCells(output.stored, contentHash: output.contentHash)
                        written += 1
                    }
                } else if row.storageFormat == plainFormat || row.contentHash == nil {
                    // Changed while the chunk was processed: try once more.
                    stored.requeue(row.id)
                }
            }
            if written > 0 {
                try context.save()
                updated += written
            }
            await Self.pauseUpkeep(pause)
        }
        return UpkeepPassResult(count: updated, finished: !Task.isCancelled && variantCompactionHolds == 0)
    }

    /// Off-main compression and hashing of a chunk; unreadable blobs are absent.
    private static func compactCells(_ inputs: [MaskVersionCompaction.Input]) async
        -> [UUID: MaskVersionCompaction.Output] {
        await Task.detached(priority: .utility) {
            var results: [UUID: MaskVersionCompaction.Output] = [:]
            for input in inputs {
                if let output = MaskVersionCompaction.process(input) { results[input.id] = output }
            }
            return results
        }.value
    }

    static func pauseUpkeep(_ pause: Duration?) async {
        if let pause {
            try? await Task.sleep(for: pause)
        } else {
            await LibraryTransferPacing.breathe()
        }
    }

    /// Debounced start of the automatic detection cell storage upkeep; does
    /// nothing unless `automaticVariantCompaction` is on, and starts no pass
    /// while `upkeepNote` records the job as done.
    func scheduleDetectionStorageMigration(after delay: Duration = .seconds(2)) {
        guard automaticVariantCompaction else { return }
        detectionStorageDebounce?.cancel()
        detectionStorageDebounce = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.detectionStorageDebounce = nil
            self.startDetectionStorageMigrationIfIdle()
        }
    }

    private func startDetectionStorageMigrationIfIdle() {
        // A running task takes work reported meanwhile in its next pass.
        guard detectionStorageTask == nil, variantCompactionHolds == 0,
              upkeepNote.needsRun(.detectionCellStorage) else { return }
        detectionStorageGeneration &+= 1
        let generation = detectionStorageGeneration
        detectionStorageTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.upkeepNote.needsRun(.detectionCellStorage) {
                let finished = try? await self.migrateReportedDetectionCellStorage(pause: .milliseconds(40))
                guard finished == true else { break }
            }
            if self.detectionStorageGeneration == generation { self.detectionStorageTask = nil }
        }
    }

    /// Image ids per `contains` query, well below SQLite's bound-variable limit.
    static let idQueryChunk = 500

    /// Review rows, saved mask versions and annotations of the given images:
    /// one `contains` query per table (per `idQueryChunk` images), served by
    /// the `imageId` indexes. ROIs, detections and corrections go with the
    /// image through its cascade rules.
    private func deleteImageAuxiliaryRecords(forImageIds imageIds: [UUID]) throws {
        for start in stride(from: 0, to: imageIds.count, by: Self.idQueryChunk) {
            let ids = Array(imageIds[start..<min(start + Self.idQueryChunk, imageIds.count)])
            let reviewRows = try context.fetch(FetchDescriptor<ReviewCandidateRecord>(
                predicate: #Predicate { ids.contains($0.imageId) }))
            let variants = try context.fetch(FetchDescriptor<SegmentationVariantRecord>(
                predicate: #Predicate { ids.contains($0.imageId) }))
            let annotations = try context.fetch(FetchDescriptor<GroundTruthAnnotation>(
                predicate: #Predicate { ids.contains($0.imageId) }))
            for row in reviewRows { context.delete(row) }
            for variant in variants { context.delete(variant) }
            for annotation in annotations { context.delete(annotation) }
        }
    }

    // MARK: — Review index / scalable summaries

    /// Keep the queue's scalar measurements in the same units as its source.
    /// Recalibration changes neither cell identity nor previous review decisions.
    func recalibrateReviewCandidates(for detection: DetectionRecord, pxPerUm: Double) throws {
        guard pxPerUm.isFinite, pxPerUm > 0 else { return }
        let detectionID = detection.id
        let rows = try context.fetch(FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { $0.detectionId == detectionID }))
        for row in rows { row.diameter = row.diameterPx / pxPerUm }
    }

    private func indexReviewCandidates(cells: [DetectedCell],
                                       detection: DetectionRecord,
                                       image: ImageRecord) {
        let corrected = Set(detection.corrections.map(\.cellId))
        var pending = 0
        for cell in cells where cell.confidence < 0.65 {
            let row = ReviewCandidateRecord(cell: cell, detection: detection, image: image)
            row.triaged = corrected.contains(cell.id)
            if !row.triaged { pending += 1 }
            context.insert(row)
        }
        detection.reviewPendingCount = pending
        detection.reviewIndexVersion = 1
        detection.cellCountSummary = cells.count
    }

    private func deleteReviewCandidates(forDetectionId detectionId: UUID) {
        let desc = FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { $0.detectionId == detectionId })
        for row in (try? context.fetch(desc)) ?? [] { context.delete(row) }
    }

    private func triageReviewCandidates(detectionId: UUID, cellIds: Set<UUID>) -> Int {
        guard !cellIds.isEmpty else { return 0 }
        if cellIds.count == 1, let cellId = cellIds.first {
            var desc = FetchDescriptor<ReviewCandidateRecord>(
                predicate: #Predicate {
                    $0.detectionId == detectionId && $0.cellId == cellId && !$0.triaged
                })
            desc.fetchLimit = 1
            guard let rows = try? context.fetch(desc), let row = rows.first else { return 0 }
            row.triaged = true
            return 1
        }
        let desc = FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { $0.detectionId == detectionId && !$0.triaged })
        var changed = 0
        for row in (try? context.fetch(desc)) ?? [] where cellIds.contains(row.cellId) {
            row.triaged = true
            changed += 1
        }
        return changed
    }

    func pendingReviewCandidates(limit: Int = 96,
                                 after position: ReviewQueuePosition? = nil,
                                 includingBoundary: Bool = false) throws -> [ReviewCandidateRecord] {
        guard limit > 0 else { return [] }
        // `triaged == false` rather than `!triaged`: SQLite can then serve the
        // filter and this order from the (triaged, confidence, sortKey) index
        // and stop after one page. `!triaged` becomes `NOT (triaged = ?)`,
        // which no index serves, so every page scanned and sorted the table.
        var desc = FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { $0.triaged == false },
            // Foundation defaults String sorting to localized/numeric order,
            // while the cursor predicate uses lexical comparison. They must
            // agree, otherwise tied scores can repeat or disappear at a page.
            sortBy: [SortDescriptor(\.confidence), SortDescriptor(\.sortKey, comparator: .lexical)])
        if let position {
            let confidence = position.confidence
            let key = position.sortKey
            desc.predicate = #Predicate {
                $0.triaged == false && ($0.confidence > confidence ||
                    ($0.confidence == confidence && ($0.sortKey > key ||
                        (includingBoundary && $0.sortKey == key))))
            }
        }
        desc.fetchLimit = min(96, limit)
        return try context.fetch(desc)
    }

    func pendingReviewCandidateCount() -> Int {
        // Equality form so the count is a range of the queue index.
        let desc = FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { $0.triaged == false })
        return (try? context.fetchCount(desc)) ?? 0
    }

    /// Never traverse a candidate's potentially dangling owner relationships.
    /// Fetch live owners in batches, retaining at most one queue page.
    /// Rows that cannot be shown are stale; meeting one in a library recorded
    /// as clean re-arms the stale-row check (`onStaleReviewRows`).
    func reviewItems(for candidates: [ReviewCandidateRecord]) throws -> [ReviewItem] {
        let (items, liveCandidates) = try resolveReviewItems(for: candidates)
        if items.count < liveCandidates { noteStaleReviewRows() }
        return items
    }

    /// Owner resolution shared by the queue and the stale-row check. Returns
    /// the showable items and how many candidates were still live rows.
    private func resolveReviewItems(for candidates: [ReviewCandidateRecord]) throws -> (items: [ReviewItem], liveCandidates: Int) {
        // Callers can retain a page through reset/reanalysis animations. A
        // saved deletion detaches its model; reading scalar fields from that
        // invalidated backing row can trap before owner resolution begins.
        let candidates = candidates.filter { !$0.isDeleted && $0.modelContext === context }
        guard !candidates.isEmpty else { return ([], 0) }
        let imageIDs = Array(Set(candidates.map(\.imageId)))
        let detectionIDs = Array(Set(candidates.map(\.detectionId)))
        let images = try context.fetch(FetchDescriptor<ImageRecord>(
            predicate: #Predicate { imageIDs.contains($0.id) }))
        var detectionFetch = FetchDescriptor<DetectionRecord>(
            predicate: #Predicate { detectionIDs.contains($0.id) })
        // A page may span 96 images. Do not pull all 96 contour JSON blobs
        // into memory merely to verify ownership; only visible cards load them.
        detectionFetch.propertiesToFetch = [\.id, \.cellsRevision]
        let detections = try context.fetch(detectionFetch)
        var imagesByID: [UUID: ImageRecord] = [:]
        var detectionsByID: [UUID: DetectionRecord] = [:]
        for image in images { imagesByID[image.id] = image }
        for detection in detections { detectionsByID[detection.id] = detection }
        let items = candidates.compactMap { candidate -> ReviewItem? in
            guard let image = imagesByID[candidate.imageId],
                  let detection = detectionsByID[candidate.detectionId] else { return nil }
            return ReviewItem(candidate, image: image, detection: detection)
        }
        return (items, candidates.count)
    }

    /// Stale rows found while the library is recorded as clean: record that it
    /// needs the check again and let AppState start it. When the check is
    /// already pending (running, or due at the next launch) nothing changes.
    private func noteStaleReviewRows() {
        guard !reviewIndexCheck.needsCheck else { return }
        reviewIndexCheck.markNeedsCheck()
        onStaleReviewRows?()
    }

    /// Visits every review row that exists for the whole pass exactly once, in
    /// `sortKey` order, one page at a time. Each page starts at the last key
    /// already visited (never at an
    /// offset), so rows that `body` deletes cannot shift later pages, and each
    /// query is a range of the `sortKey` index. Rows sharing the key that
    /// ended the previous page are remembered by id, so equal keys (such as
    /// legacy empty keys) are neither skipped nor repeated. `body` may delete
    /// the rows it receives and save; their keys and ids are read beforehand.
    /// `pageSize` defaults to the queue's page size. Returns false if the
    /// task was cancelled before every row was visited.
    @discardableResult
    func forEachReviewCandidatePage(pageSize: Int? = nil,
                                    _ body: ([ReviewCandidateRecord]) throws -> Void) async throws -> Bool {
        let size = max(1, pageSize ?? ReviewQueueSession.pageSize)
        var boundary: String?
        var visitedAtBoundary = Set<UUID>()
        while true {
            if Task.isCancelled { return false }
            let limit = size + visitedAtBoundary.count
            let step: (endKey: String, endIDs: [UUID], fetchedAll: Bool)? = try autoreleasepool {
                var desc = FetchDescriptor<ReviewCandidateRecord>(
                    sortBy: [SortDescriptor(\.sortKey, comparator: .lexical)])
                if let boundary {
                    desc.predicate = #Predicate { $0.sortKey >= boundary }
                }
                desc.fetchLimit = limit
                let fetched = try context.fetch(desc)
                let rows = fetched.filter { !$0.isDeleted && !visitedAtBoundary.contains($0.id) }
                guard let endKey = rows.last?.sortKey else { return nil }
                let endIDs = rows.filter { $0.sortKey == endKey }.map(\.id)
                let fetchedAll = fetched.count < limit
                try body(rows)
                return (endKey, endIDs, fetchedAll)
            }
            guard let step else { return true }
            if step.endKey == boundary {
                visitedAtBoundary.formUnion(step.endIDs)
            } else {
                visitedAtBoundary = Set(step.endIDs)
            }
            boundary = step.endKey
            if step.fetchedAll { return true }
            await LibraryTransferPacing.breathe()
        }
    }

    /// Removes review rows the queue can never show: their image or detection
    /// is gone, the image left its batch, or the detection is no longer the
    /// image's live one (exactly the rows `reviewItems(for:)` drops). Read
    /// failures must not be interpreted as proof that owners are missing.
    /// Only index rows are removed; detections and corrections are preserved.
    /// A complete pass records the library as checked (`reviewIndexCheck`).
    /// Returns how many rows were removed.
    @discardableResult
    func removeOrphanedReviewCandidates() async throws -> Int {
        let startGeneration = reviewIndexCheck.generation
        var removed = 0
        let finished = try await forEachReviewCandidatePage { rows in
            let liveIDs = Set(try resolveReviewItems(for: rows).items.map(\.id))
            var stale = 0
            for row in rows where !liveIDs.contains(row.id) {
                context.delete(row)
                stale += 1
            }
            if stale > 0 {
                try context.save()
                removed += stale
            }
        }
        if finished { reviewIndexCheck.markVerified(sinceGeneration: startGeneration) }
        return removed
    }

    /// Index work the Review queue depends on, so the queue waits for it:
    /// legacy detections get their review rows and summaries, and legacy rows
    /// get a stable sort key. With nothing to upgrade this is two indexed
    /// queries. Returns whether anything changed.
    @discardableResult
    func prepareReviewQueueIndex() async throws -> Bool {
        let indexed = try await indexLegacyDetections()
        let keyed = try await backfillReviewSortKeys()
        return indexed || keyed
    }

    /// Upkeep the queue does not wait for: the stale-row check, only while
    /// `reviewIndexCheck` says it is needed (the queue already hides stale
    /// rows), and stored totals of legacy batches. Returns whether anything changed.
    @discardableResult
    func performDeferredIndexMaintenance() async throws -> Bool {
        var changed = false
        if reviewIndexCheck.needsCheck {
            changed = try await removeOrphanedReviewCandidates() > 0
        }
        if Task.isCancelled { return changed }
        let summarized = try await backfillBatchSummaries()
        return changed || summarized
    }

    /// Everything above in one call (restores and tools). `onChunk` runs once,
    /// at the end.
    func rebuildPerformanceIndexes(onChunk: (() -> Void)? = nil) async throws {
        try await prepareReviewQueueIndex()
        try await performDeferredIndexMaintenance()
        if !Task.isCancelled { onChunk?() }
    }

    /// Upgrade legacy rows without monopolizing the main run loop. Each old
    /// detection is decoded once, then all future Home badges and Review opens
    /// use queryable integer/index rows. A save/yield every eight images keeps
    /// launch and navigation responsive even for 700-image stores.
    private func indexLegacyDetections() async throws -> Bool {
        var desc = FetchDescriptor<DetectionRecord>(
            predicate: #Predicate { $0.reviewIndexVersion < 1 })
        desc.fetchLimit = 8
        var changed = false
        while !Task.isCancelled {
            let detections = try context.fetch(desc)
            guard !detections.isEmpty else { break }
            for detection in detections {
                // Earlier iterations suspend while decoding. A reset can
                // delete the rest of this already-fetched batch meanwhile.
                guard !detection.isDeleted, detection.modelContext != nil else { continue }
                guard let image = detection.image, image.batch != nil,
                      image.detection?.id == detection.id else {
                    detection.reviewIndexVersion = 1
                    continue
                }
                let revision = detection.cellsRevision
                let data = detection.cellsData
                let cells = try await CellDecodeWorker.shared.decode(
                    id: detection.id, revision: revision, data: data)
                guard !Task.isCancelled else { return changed }
                guard !detection.isDeleted, detection.modelContext != nil,
                      !image.isDeleted, image.modelContext != nil else { continue }
                guard detection.cellsRevision == revision,
                      image.detection?.id == detection.id else { continue }
                let detectionID = detection.id
                let previousRows = try context.fetch(FetchDescriptor<ReviewCandidateRecord>(
                    predicate: #Predicate { $0.detectionId == detectionID }))
                for row in previousRows { context.delete(row) }
                indexReviewCandidates(cells: cells, detection: detection, image: image)
            }
            try context.save()
            changed = true
            await Task.yield()
        }
        return changed
    }

    /// Older normalized rows need only a small string backfill, preserving
    /// their triage state and avoiding a second whole-library JSON decode.
    private func backfillReviewSortKeys() async throws -> Bool {
        var legacy = FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { $0.sortKey == "" })
        legacy.fetchLimit = 96
        var changed = false
        while !Task.isCancelled {
            let rows = try context.fetch(legacy)
            guard !rows.isEmpty else { break }
            for row in rows { row.sortKey = row.id.uuidString }
            try context.save()
            changed = true
            await Task.yield()
        }
        return changed
    }

    /// Batches saved before stored totals existed (or restored without them).
    /// Runs after detection summaries exist, so it only adds integers and does
    /// not re-decode cell blobs. Only those batches are read.
    private func backfillBatchSummaries() async throws -> Bool {
        let missing = FetchDescriptor<BatchRecord>(
            predicate: #Predicate { $0.imageCountSummary < 0 || $0.cellCountSummary < 0 })
        let batches = try context.fetch(missing)
        guard !batches.isEmpty else { return false }
        var changed = false
        for (offset, batch) in batches.enumerated() {
            guard !batch.isDeleted, batch.modelContext != nil else { continue }
            if batch.imageCountSummary < 0 || batch.cellCountSummary < 0 {
                batch.imageCountSummary = batch.images.count
                batch.cellCountSummary = batch.images.reduce(0) {
                    $0 + ($1.detection?.summaryCellCount ?? 0)
                }
                changed = true
            }
            if offset % 32 == 31 {
                try context.save()
                await Task.yield()
            }
        }
        try context.save()
        return changed
    }

    /// Persist one logical overlay operation in a single SwiftData save.
    /// `storage` may be prepared by `DetectionRecord.makeStorageSnapshot` on a
    /// detached task, keeping the potentially large JSON encode off the UI
    /// thread. All correction rows and review-index updates are committed with
    /// the cell blob so observers never see a half-applied edit.
    func commitCellEdit(storage: DetectionRecord.CellsStorageSnapshot?,
                        corrections specs: [CorrectionSpec],
                        detection: DetectionRecord,
                        image: ImageRecord) -> CellEditCommitResult {
        let result = stageCellEdit(storage: storage, corrections: specs, detection: detection, image: image)
        try? context.save()
        return result
    }

    /// Review must not advance or clear undo until the database confirms a save.
    func commitReviewCellEdit(storage: DetectionRecord.CellsStorageSnapshot?,
                             corrections specs: [CorrectionSpec],
                             detection: DetectionRecord,
                             image: ImageRecord) throws -> CellEditCommitResult {
        try validateReviewStorage(storage)
        let detectionID = detection.id
        let cellIDs = specs.map(\.cellId)
        let rows = try context.fetch(FetchDescriptor<ReviewCandidateRecord>(predicate: #Predicate {
            $0.detectionId == detectionID && cellIDs.contains($0.cellId) && !$0.triaged
        }))
        return try saveReviewChange(detection: detection) {
            stageCellEdit(storage: storage, corrections: specs, detection: detection, image: image,
                          reviewRows: rows)
        }
    }

    private func validateReviewStorage(_ storage: DetectionRecord.CellsStorageSnapshot?) throws {
        if let storage, storage.data.isEmpty {
            throw NSError(domain: "CellCounter.Review", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The cell measurements could not be encoded. No review changes were saved."
            ])
        }
    }

    private func saveReviewChange<T>(detection: DetectionRecord, _ change: () -> T) throws -> T {
        try LocalTiming.measure(.reviewSave) { try saveReviewChangeImpl(detection: detection, change) }
    }
    private func saveReviewChangeImpl<T>(detection: DetectionRecord, _ change: () -> T) throws -> T {
        guard container.configurations.allSatisfy(\.allowsSave) else {
            throw NSError(domain: "CellCounter.Review", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "This library is read-only. No review changes were applied."
            ])
        }
        // Flush unrelated pending changes before the synchronous transaction.
        // There is no suspension point between this checkpoint and rollback.
        try context.save()
        let detectionID = detection.id
        do {
            let result = change()
            try context.save()
            return result
        } catch {
            context.rollback()
            DecodedCellCache.shared.remove(detectionID)
            throw error
        }
    }

    private func stageCellEdit(storage: DetectionRecord.CellsStorageSnapshot?,
                               corrections specs: [CorrectionSpec],
                               detection: DetectionRecord,
                               image: ImageRecord,
                               reviewRows: [ReviewCandidateRecord]? = nil) -> CellEditCommitResult {
        let oldCount = detection.summaryCellCount
        if let storage {
            detection.applyStorageSnapshot(storage)
            noteUpkeepWork(for: detection)
            if let batch = image.batch {
                if batch.cellCountSummary >= 0 {
                    batch.cellCountSummary += storage.count - oldCount
                }
                batch.contentRevision &+= 1
            }
        }

        var records: [CorrectionRecord] = []
        records.reserveCapacity(specs.count)
        for spec in specs {
            let record = CorrectionRecord(kind: spec.kind, cellId: spec.cellId,
                                          cx: spec.cx, cy: spec.cy,
                                          diameter: spec.diameter)
            record.detection = detection
            context.insert(record)
            records.append(record)
        }

        let ids = Set(specs.map(\.cellId))
        let triaged: Int
        if let reviewRows {
            triaged = reviewRows.count
            for row in reviewRows { row.triaged = true }
        } else {
            triaged = triageReviewCandidates(detectionId: detection.id, cellIds: ids)
        }
        if detection.reviewPendingCount >= 0 {
            detection.reviewPendingCount = max(0, detection.reviewPendingCount - triaged)
        }
        return CellEditCommitResult(corrections: records, reviewCountDelta: -triaged)
    }

    func commitCellEdit(cells: [DetectedCell]?,
                        corrections: [CorrectionSpec],
                        detection: DetectionRecord,
                        image: ImageRecord) -> CellEditCommitResult {
        let storage = cells.map(DetectionRecord.makeStorageSnapshot)
        return commitCellEdit(storage: storage, corrections: corrections,
                              detection: detection, image: image)
    }

    /// Reverse a Review action without creating a second audit row.
    @discardableResult
    func undoReviewCorrection(_ correction: CorrectionRecord,
                              candidate: ReviewCandidateRecord,
                              restoredStorage: DetectionRecord.CellsStorageSnapshot?,
                              detection: DetectionRecord,
                              image: ImageRecord) throws -> Int {
        try validateReviewStorage(restoredStorage)
        return try saveReviewChange(detection: detection) {
            let oldCount = detection.summaryCellCount
            if let storage = restoredStorage {
                detection.applyStorageSnapshot(storage)
                noteUpkeepWork(for: detection)
                if let batch = image.batch {
                    if batch.cellCountSummary >= 0 {
                        batch.cellCountSummary += storage.count - oldCount
                    }
                    batch.contentRevision &+= 1
                }
            }
            context.delete(correction)
            var delta = 0
            if candidate.triaged {
                candidate.triaged = false
                delta = 1
                if detection.reviewPendingCount >= 0 { detection.reviewPendingCount += 1 }
            }
            return delta
        }
    }

    // MARK: — Presets

    func calibrationPresets() -> [CalibrationPresetRecord] {
        let desc = FetchDescriptor<CalibrationPresetRecord>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(desc)) ?? []
    }

    func binPresets() -> [BinPresetRecord] {
        let desc = FetchDescriptor<BinPresetRecord>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(desc)) ?? []
    }

    func upsertCalibrationPreset(_ preset: CalibrationPresetRecord) {
        context.insert(preset)
        try? context.save()
    }

    func deleteCalibrationPreset(_ preset: CalibrationPresetRecord) {
        context.delete(preset)
        try? context.save()
    }

    // MARK: — Model versions

    func modelVersions(for modelId: String) -> [ModelVersionRecord] {
        let desc = FetchDescriptor<ModelVersionRecord>(
            predicate: #Predicate { $0.modelId == modelId },
            sortBy: [SortDescriptor(\.version, order: .reverse)])
        return (try? context.fetch(desc)) ?? []
    }

    func recordModelVersion(_ version: ModelVersionRecord) {
        context.insert(version)
        try? context.save()
    }

    // MARK: — Total cell count across all batches (for sidebar count)

    func totalImageCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<ImageRecord>())) ?? 0
    }
    func totalBatchCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<BatchRecord>())) ?? 0
    }
    // MARK: — Conditions (pass 6)

    /// Returns all conditions sorted by `order` ascending — the canonical UI ordering.
    func conditions() -> [ConditionRecord] {
        let desc = FetchDescriptor<ConditionRecord>(sortBy: [SortDescriptor(\.order)])
        return (try? context.fetch(desc)) ?? []
    }

    @discardableResult
    func createCondition(name: String, color: String) -> ConditionRecord {
        // Place at end of the list by default.
        let existing = conditions()
        let nextOrder = (existing.map(\.order).max() ?? -1) + 1
        let c = ConditionRecord(name: name, color: color, order: nextOrder)
        context.insert(c)
        try? context.save()
        return c
    }

    func deleteCondition(_ condition: ConditionRecord) {
        context.delete(condition)
        try? context.save()
    }

    func renameCondition(_ condition: ConditionRecord, to newName: String) {
        condition.name = newName
        try? context.save()
    }

    /// Persist a new ordering. The input is the desired sequence of conditions;
    /// `order` is rewritten to match the array's index.
    func reorderConditions(_ ordered: [ConditionRecord]) {
        for (i, c) in ordered.enumerated() { c.order = i }
        try? context.save()
    }

    // MARK: — ROIs

    func rois(for imageId: UUID) -> [ROIRecord] {
        let desc = FetchDescriptor<ROIRecord>(
            predicate: #Predicate { $0.imageId == imageId },
            sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(desc)) ?? []
    }

    func save(_ roi: ROIRecord, on image: ImageRecord) {
        roi.image = image
        image.rois.append(roi)
        context.insert(roi)
        try? context.save()
    }

    func deleteROI(_ roi: ROIRecord) {
        context.delete(roi)
        try? context.save()
    }

    // MARK: — Destructive wipe (pass 11)

    /// Database portion of Reset. Kept separate from filesystem deletion so
    /// persistent-store regressions can use an isolated database safely.
    func deleteAllLibraryRecords() throws {
        // Preserve unrelated pending work before the reset starts.
        try context.save()
        // Delete run output explicitly, including detached images/detections
        // left by earlier deletes. A batch cascade cannot reach those rows,
        // or the scalar-ID variant/annotation tables. Workflow configuration
        // (conditions, model versions, presets) survives.
        //
        // Core Data reads every deleted row (cell blobs included) when it
        // saves, so one transaction for the whole library held all of them in
        // memory at once. Each table is emptied in bounded chunks instead,
        // every chunk its own save. A failed chunk is rolled back, so the
        // context is never left full of staged deletions; chunks already saved
        // stay deleted and running Reset again finishes the job. Detections go
        // before corrections (their cascade takes their corrections along),
        // and images before batches.
        try deleteAllRows(of: ReviewCandidateRecord.self, chunkSize: 512)
        try deleteAllRows(of: GroundTruthAnnotation.self, chunkSize: 512)
        try deleteAllRows(of: SegmentationVariantRecord.self, chunkSize: 16)
        try deleteAllRows(of: DetectionRecord.self, chunkSize: 16)
        try deleteAllRows(of: CorrectionRecord.self, chunkSize: 512)
        try deleteAllRows(of: ROIRecord.self, chunkSize: 512)
        try deleteAllRows(of: ImageRecord.self, chunkSize: 256)
        try deleteAllRows(of: BatchRecord.self, chunkSize: 256)
        // No review rows remain, so there is nothing stale to look for.
        reviewIndexCheck.markVerified(sinceGeneration: reviewIndexCheck.generation)
    }

    /// Deletes every row of `type`, `chunkSize` rows per save.
    private func deleteAllRows<T: PersistentModel>(of type: T.Type, chunkSize: Int) throws {
        let limit = max(1, chunkSize)
        var desc = FetchDescriptor<T>()
        desc.fetchLimit = limit
        var finished = false
        while !finished {
            finished = try autoreleasepool {
                let rows = try context.fetch(desc)
                guard !rows.isEmpty else { return true }
                do {
                    for row in rows { context.delete(row) }
                    try context.save()
                } catch {
                    context.rollback()
                    throw error
                }
                return rows.count < limit
            }
        }
    }

    /// Deletes the library and its image/thumbnail files, preserving presets,
    /// model environments and exports. Used by Settings → Reset all data.
    func wipeAllUserData() throws {
        try deleteAllLibraryRecords()
        // The library is already empty even if directory recreation fails.
        // Release retained rows before filesystem cleanup can throw.
        NotificationCenter.default.post(name: .ccLibraryChanged, object: nil)

        // Files
        let fm = FileManager.default
        try? fm.removeItem(at: FileStore.shared.imagesDir)
        try? fm.removeItem(at: FileStore.shared.displayImagesDir)
        try? fm.removeItem(at: FileStore.shared.thumbsDir)
        try fm.createDirectory(at: FileStore.shared.imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: FileStore.shared.displayImagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: FileStore.shared.thumbsDir, withIntermediateDirectories: true)

        // Pass-12 K1: even though this routine intentionally preserves the
        // Python venv, post the venv-changed signal so subscribers always
        // re-probe after a "Reset all data" — defensive in case future edits
        // start wiping the venv here.
        NotificationCenter.default.post(name: .ccVenvChanged, object: nil)
    }

    // MARK: — Ground-truth annotations (pass 17, Lane B)

    /// All annotations placed on a given image, oldest first.
    func annotations(for imageId: UUID) -> [GroundTruthAnnotation] {
        let desc = FetchDescriptor<GroundTruthAnnotation>(
            predicate: #Predicate { $0.imageId == imageId },
            sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(desc)) ?? []
    }

    func addAnnotation(_ ann: GroundTruthAnnotation) {
        context.insert(ann)
        try? context.save()
    }

    func deleteAnnotation(_ ann: GroundTruthAnnotation) {
        context.delete(ann)
        try? context.save()
    }

    func deleteAllAnnotations(for imageId: UUID) {
        for a in annotations(for: imageId) {
            context.delete(a)
        }
        try? context.save()
    }

    /// Counts individual low-confidence CELLS (not detections) across every
    /// detection reachable from the library, subtracting any cells the user
    /// has already triaged. A cell is "triaged" when a CorrectionRecord exists
    /// for its `cellId` — any kind ("remove", "accept", "resize", "move",
    /// "add", "manual") — recorded against that SAME detection.
    ///
    /// Badge/queue mismatch fix: this used to run a `FetchDescriptor<DetectionRecord>`
    /// predicate against the denormalised `minConfidence` field, fetching
    /// stored `DetectionRecord`s directly. `ReviewQueueView.rebuild()` (the
    /// source of truth for what cards actually appear) has never worked that
    /// way — it walks `allBatches() → batch.images → image.detection →
    /// detection.cells`, so it only ever sees detections reachable from a
    /// live batch/image. The two were only "the same set" by convention
    /// (and by every mutation path happening to keep `minConfidence` and the
    /// object graph in lockstep) — nothing enforced it, which is exactly the
    /// kind of drift the "Fix (researcher #3)" note atop `rebuild()` warns
    /// about and flags as still open ("must also change
    /// Repositories.uncorrectedCellCount; see the audit's recommendations").
    ///
    /// Now this walks the identical path with the identical predicates
    /// (`cell.confidence < confidence`, same per-detection `correctedIds`
    /// exclusion, no fileName dedupe — the queue doesn't dedupe either) so
    /// the badge and the queue's card count are derived from one rule, not
    /// two hand-synced copies of it. If the membership rule ever changes,
    /// change it in both places — see the matching note atop
    /// `ReviewQueueView.rebuild()`.
    func uncorrectedCellCount(below confidence: Double) -> Int {
        // The canonical queue cutoff is 0.65. Keep the legacy signature for
        // callers, but never fall back to a whole-library JSON scan.
        if abs(confidence - 0.65) < 0.000_001 {
            return pendingReviewCandidateCount()
        }
        // Non-canonical cutoffs are not currently used by the UI; querying the
        // normalized rows still scales with candidate rows rather than every
        // cell/contour in every detection.
        let desc = FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { !$0.triaged })
        return ((try? context.fetch(desc)) ?? []).lazy.filter { $0.confidence < confidence }.count
    }
}
