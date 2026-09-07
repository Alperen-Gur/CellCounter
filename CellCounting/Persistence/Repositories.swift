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

    init(inMemory: Bool = false) {
        let schema = Schema([
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
        ])
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
        let config = ModelConfiguration("CellCounter",
                                         schema: schema,
                                         url: FileStore.shared.root.appendingPathComponent("store.sqlite"))
        do {
            self.container = try ModelContainer(for: schema, configurations: [config])
        } catch let diskError {
            // Last-ditch fall back to in-memory if the disk store is unwritable.
            // If even that throws it's almost certainly a schema/migration error
            // (not disk-related), so surface an actionable message instead of an
            // opaque try! trap.
            do {
                self.container = try ModelContainer(for: schema,
                                                    configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            } catch let memoryError {
                fatalError("""
                CellCounter could not open its data store.
                On-disk store failed: \(diskError)
                In-memory fallback also failed: \(memoryError)
                This usually indicates a schema/migration problem rather than a disk issue. \
                Please report this with the messages above.
                """)
            }
        }
        seedDefaultsIfNeeded()
    }

    // MARK: — Seeding

    private func seedDefaultsIfNeeded() {
        let calibCount = (try? context.fetchCount(FetchDescriptor<CalibrationPresetRecord>())) ?? 0
        if calibCount == 0 {
            for p in CalibrationPreset.builtIn {
                context.insert(CalibrationPresetRecord(name: p.name, pxPerUm: p.pxPerUm, isDefault: p.isDefault))
            }
        }
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
            let first = batch.images.min(by: { $0.importedAt < $1.importedAt })
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

    func deleteBatch(_ batch: BatchRecord) {
        // remove image + thumb files too
        for img in batch.images {
            // B1-3: guard against empty fileName to avoid removing wrong/root URLs
            guard !img.fileName.isEmpty else { continue }
            try? FileManager.default.removeItem(at: img.storedURL)
            if img.displayURL != img.storedURL {
                try? FileManager.default.removeItem(at: img.displayURL)
            }
            try? FileManager.default.removeItem(at: img.thumbURL)
            deleteReviewCandidates(forImageId: img.id)
            deleteSegmentationVariants(forImageId: img.id)
        }
        context.delete(batch)
        try? context.save()
    }

    /// Pass-12: Delete every `BatchRecord` whose `images` array is empty.
    /// Called at app launch (via `AppState.init` → migration extension) and at the
    /// end of `importAndAnalyze` when all imports failed — both paths can leave
    /// orphan empty batches behind that would otherwise litter the sidebar /
    /// Recents and trigger K4's duplicate-name disambiguator with "(1)" suffixes.
    /// No on-disk files to clean up because empty batches have no images.
    func cleanupEmptyBatches() {
        let toDelete = allBatches().filter { $0.images.isEmpty }
        for b in toDelete { context.delete(b) }
        try? context.save()
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

    /// Returns the first existing ImageRecord whose fileHash matches `hash`
    /// AND whose fileName matches `fileName`, excluding any record with `excludingId`.
    /// Used at import time to detect re-imports of the same file.
    func imageRecord(matchingHash hash: String, fileName: String, excludingId: UUID? = nil) -> ImageRecord? {
        // SwiftData predicates can't do optional comparisons easily, so fetch by fileName
        // and filter by hash in memory. The library is small (hundreds of images at most).
        let desc = FetchDescriptor<ImageRecord>(
            predicate: #Predicate { $0.fileName == fileName },
            sortBy: [SortDescriptor(\.importedAt, order: .reverse)])
        let candidates = (try? context.fetch(desc)) ?? []
        return candidates.first { img in
            guard img.fileHash == hash else { return false }
            if let excl = excludingId, img.id == excl { return false }
            return true
        }
    }

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

    /// Updates the fileHash on an ImageRecord and saves.
    func setFileHash(_ hash: String, on image: ImageRecord) {
        image.fileHash = hash
        try? context.save()
    }

    /// Deletes one image without making the caller wait for filesystem cleanup.
    func deleteImage(_ image: ImageRecord) {
        deleteImages([image])
    }

    /// Removes a selection in one database transaction. Potentially large
    /// source files are unlinked on a utility worker after their URLs have
    /// been snapshotted, keeping bulk Library deletion responsive.
    func deleteImages(_ images: [ImageRecord]) {
        var fileURLs = Set<URL>()
        for image in images where !image.fileName.isEmpty {
            fileURLs.insert(image.storedURL)
            fileURLs.insert(image.displayURL)
            fileURLs.insert(image.thumbURL)
            let removedCells = image.detection?.summaryCellCount ?? 0
            deleteReviewCandidates(forImageId: image.id)
            deleteSegmentationVariants(forImageId: image.id)
            if let batch = image.batch {
                if batch.imageCountSummary >= 0 {
                    batch.imageCountSummary = max(0, batch.imageCountSummary - 1)
                }
                if batch.cellCountSummary >= 0 {
                    batch.cellCountSummary = max(0, batch.cellCountSummary - removedCells)
                }
                batch.contentRevision &+= 1
            }
            context.delete(image)
        }
        try? context.save()
        Task.detached(priority: .utility) {
            for url in fileURLs { try? FileManager.default.removeItem(at: url) }
        }
    }

    func attach(image: ImageRecord, to batch: BatchRecord, save: Bool = true) {
        image.batch = batch
        batch.images.append(image)
        if batch.imageCountSummary >= 0 { batch.imageCountSummary += 1 }
        batch.contentRevision &+= 1
        if save { try? context.save() }
    }

    func saveDetection(_ cells: [DetectedCell], detectorId: String, for image: ImageRecord,
                       imageStats: [String: Double]? = nil,
                       runSettings: AnalysisRunSettings? = nil,
                       save: Bool = true) {
        // Reassigning the to-one relationship only nulls the old record's inverse;
        // it does not delete the orphan. Explicitly delete the superseded detection
        // so re-runs don't leave stale DetectionRecords in the store (which would
        // inflate uncorrectedCellCount(below:) / the Review badge).
        let previousCount = image.detection?.summaryCellCount ?? 0
        if let old = image.detection {
            saveSegmentationVariant(image: image,
                                    detectorId: old.detectorId,
                                    label: "Before \(detectorId)",
                                    cells: old.cells,
                                    save: false)
            deleteReviewCandidates(forDetectionId: old.id)
            context.delete(old)
        }
        let det = DetectionRecord(detectorId: detectorId, cells: cells,
                                  imageStats: imageStats ?? [:])
        det.runSettings = runSettings
        det.image = image
        image.detection = det
        context.insert(det)
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

    func segmentationVariants(for imageId: UUID) -> [SegmentationVariantRecord] {
        let desc = FetchDescriptor<SegmentationVariantRecord>(
            predicate: #Predicate { $0.imageId == imageId },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(desc)) ?? []
    }

    @discardableResult
    func saveSegmentationVariant(image: ImageRecord, detectorId: String,
                                 label: String, cells: [DetectedCell],
                                 save: Bool = true) -> SegmentationVariantRecord {
        let variant = SegmentationVariantRecord(image: image,
                                                detectorId: detectorId,
                                                label: label,
                                                cells: cells)
        variant.measurementPxPerUm = image.batch?.pxPerUm
        variant.runSettingsData = image.detection?.runSettingsData
        variant.imageStatsData = image.detection?.imageStatsData
        variant.detectionRanAt = image.detection?.ranAt
        context.insert(variant)
        if save { try? context.save() }
        return variant
    }

    /// Swap a saved alternative into the live detection while preserving the
    /// current mask as another alternative. This makes comparison reversible.
    func applySegmentationVariant(_ variant: SegmentationVariantRecord,
                                  to image: ImageRecord) -> CellEditCommitResult? {
        guard let detection = image.detection else { return nil }
        let oldPendingReviewCount = max(0, detection.reviewPendingCount)
        let currentCells = detection.cells
        saveSegmentationVariant(image: image,
                                detectorId: detection.detectorId,
                                label: "Before applying \(variant.label)",
                                cells: currentCells,
                                save: false)

        let oldCount = detection.summaryCellCount
        var cells = variant.cells
        if let oldScale = variant.measurementPxPerUm, let newScale = image.batch?.pxPerUm,
           oldScale > 0, newScale > 0, oldScale != newScale {
            let ratio = oldScale / newScale
            for index in cells.indices {
                cells[index].diameter = cells[index].diameterPx / newScale
                cells[index].centroidUmX = cells[index].cx / newScale
                cells[index].centroidUmY = cells[index].cy / newScale
                if let area = cells[index].areaMicrons2 { cells[index].areaMicrons2 = area * ratio * ratio }
                if let perimeter = cells[index].perimeterMicrons { cells[index].perimeterMicrons = perimeter * ratio }
            }
        }
        detection.applyStorageSnapshot(DetectionRecord.makeStorageSnapshot(cells))
        detection.detectorId = variant.detectorId
        detection.runSettingsData = variant.runSettingsData
        detection.imageStatsData = variant.imageStatsData
        detection.ranAt = variant.detectionRanAt ?? variant.createdAt
        deleteReviewCandidates(forDetectionId: detection.id)
        indexReviewCandidates(cells: cells, detection: detection, image: image)
        if let batch = image.batch {
            if batch.cellCountSummary >= 0 {
                batch.cellCountSummary += cells.count - oldCount
            }
            batch.contentRevision &+= 1
        }
        try? context.save()
        return CellEditCommitResult(
            corrections: [],
            reviewCountDelta: detection.reviewPendingCount - oldPendingReviewCount)
    }

    func deleteSegmentationVariant(_ variant: SegmentationVariantRecord) {
        context.delete(variant)
        try? context.save()
    }

    private func deleteSegmentationVariants(forImageId imageId: UUID) {
        let desc = FetchDescriptor<SegmentationVariantRecord>(
            predicate: #Predicate { $0.imageId == imageId })
        for variant in (try? context.fetch(desc)) ?? [] { context.delete(variant) }
    }

    func recordCorrection(_ correction: CorrectionRecord, on detection: DetectionRecord) {
        correction.detection = detection
        context.insert(correction)
        try? context.save()
    }

    // MARK: — Review index / scalable summaries

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

    private func deleteReviewCandidates(forImageId imageId: UUID) {
        let desc = FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { $0.imageId == imageId })
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
                                 includingBoundary: Bool = false) -> [ReviewCandidateRecord] {
        guard limit > 0 else { return [] }
        var desc = FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { !$0.triaged },
            // Foundation defaults String sorting to localized/numeric order,
            // while the cursor predicate uses lexical comparison. They must
            // agree, otherwise tied scores can repeat or disappear at a page.
            sortBy: [SortDescriptor(\.confidence), SortDescriptor(\.sortKey, comparator: .lexical)])
        if let position {
            let confidence = position.confidence
            let key = position.sortKey
            desc.predicate = #Predicate {
                !$0.triaged && ($0.confidence > confidence ||
                    ($0.confidence == confidence && ($0.sortKey > key ||
                        (includingBoundary && $0.sortKey == key))))
            }
        }
        desc.fetchLimit = min(96, limit)
        return (try? context.fetch(desc)) ?? []
    }

    func pendingReviewCandidateCount() -> Int {
        let desc = FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { !$0.triaged })
        return (try? context.fetchCount(desc)) ?? 0
    }

    /// Upgrade legacy rows without monopolizing the main run loop. Each old
    /// detection is decoded once, then all future Home badges and Review opens
    /// use queryable integer/index rows. A save/yield every eight images keeps
    /// launch and navigation responsive even for 700-image stores.
    func rebuildPerformanceIndexes(onChunk: (() -> Void)? = nil) async {
        var desc = FetchDescriptor<DetectionRecord>(
            predicate: #Predicate { $0.reviewIndexVersion < 1 })
        desc.fetchLimit = 8
        while !Task.isCancelled {
            let detections = (try? context.fetch(desc)) ?? []
            guard !detections.isEmpty else { break }
            for detection in detections {
                guard let image = detection.image else {
                    detection.reviewIndexVersion = 1
                    continue
                }
                deleteReviewCandidates(forDetectionId: detection.id)
                let revision = detection.cellsRevision
                let data = detection.cellsData
                let cells = await Task.detached(priority: .utility) {
                    DetectionRecord.decodeCellsData(data)
                }.value
                guard detection.cellsRevision == revision,
                      image.detection?.id == detection.id else { continue }
                indexReviewCandidates(cells: cells, detection: detection, image: image)
            }
            try? context.save()
            onChunk?()
            await Task.yield()
        }

        // Older normalized rows need only a small string backfill, preserving
        // their triage state and avoiding a second whole-library JSON decode.
        var legacy = FetchDescriptor<ReviewCandidateRecord>(
            predicate: #Predicate { $0.sortKey == "" })
        legacy.fetchLimit = 96
        while !Task.isCancelled {
            let rows = (try? context.fetch(legacy)) ?? []
            guard !rows.isEmpty else { break }
            for row in rows { row.sortKey = row.id.uuidString }
            try? context.save()
            onChunk?()
            await Task.yield()
        }

        // Batch summaries are rebuilt after detection summaries, so this pass
        // only adds integers and never re-decodes a cell blob.
        for (offset, batch) in allBatches().enumerated() {
            if batch.imageCountSummary < 0 || batch.cellCountSummary < 0 {
                batch.imageCountSummary = batch.images.count
                batch.cellCountSummary = batch.images.reduce(0) {
                    $0 + ($1.detection?.summaryCellCount ?? 0)
                }
            }
            if offset % 32 == 31 { await Task.yield() }
        }
        try? context.save()
        onChunk?()
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
        let oldCount = detection.summaryCellCount
        if let storage {
            detection.applyStorageSnapshot(storage)
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
        let triaged = triageReviewCandidates(detectionId: detection.id, cellIds: ids)
        if detection.reviewPendingCount >= 0 {
            detection.reviewPendingCount = max(0, detection.reviewPendingCount - triaged)
        }
        try? context.save()
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
                              restoredCells: [DetectedCell]?,
                              detection: DetectionRecord,
                              image: ImageRecord) -> Int {
        let oldCount = detection.summaryCellCount
        if let restoredCells {
            let storage = DetectionRecord.makeStorageSnapshot(restoredCells)
            detection.applyStorageSnapshot(storage)
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
        try? context.save()
        return delta
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

    /// Deletes every batch (cascades to images, detections, corrections, ROIs)
    /// and wipes the on-disk image + thumbnail directories. Preserves user
    /// workflow config — Conditions, CalibrationPresets, BinPresets, and
    /// ModelVersions are intentionally left intact, as is the Python venv and
    /// the Exports folder.
    ///
    /// Used by Settings → About → "Reset all data…". The one-time migration
    /// path in `FileStore.runMigrationsIfNeeded()` does the same on-disk work
    /// directly (it has to, because the store isn't open yet).
    func wipeAllUserData() throws {
        // Delete every BatchRecord (cascades to ImageRecord -> DetectionRecord
        // + CorrectionRecord, and to ROIRecord). NOTE: ConditionRecord and
        // ModelVersionRecord and the preset tables survive — those are user
        // workflow config, not run output.
        for batch in allBatches() {
            context.delete(batch)
        }
        try context.save()

        // Files
        let fm = FileManager.default
        try? fm.removeItem(at: FileStore.shared.imagesDir)
        try? fm.removeItem(at: FileStore.shared.thumbsDir)
        try fm.createDirectory(at: FileStore.shared.imagesDir, withIntermediateDirectories: true)
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
