import Foundation
import SwiftData

@MainActor
final class Repositories {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() {
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
        ])
        let config = ModelConfiguration("CellCounter",
                                         schema: schema,
                                         url: FileStore.shared.root.appendingPathComponent("store.sqlite"))
        do {
            self.container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Last-ditch fall back to in-memory if disk store is unwritable.
            self.container = try! ModelContainer(for: schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
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
            try? FileManager.default.removeItem(at: img.thumbURL)
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

    /// Removes the image file + thumbnail from disk, then deletes the SwiftData record.
    func deleteImage(_ image: ImageRecord) {
        guard !image.fileName.isEmpty else { return }
        try? FileManager.default.removeItem(at: image.storedURL)
        try? FileManager.default.removeItem(at: image.thumbURL)
        context.delete(image)
        try? context.save()
    }

    func attach(image: ImageRecord, to batch: BatchRecord) {
        image.batch = batch
        batch.images.append(image)
        try? context.save()
    }

    func saveDetection(_ cells: [DetectedCell], detectorId: String, for image: ImageRecord,
                       imageStats: [String: Double]? = nil) {
        let det = DetectionRecord(detectorId: detectorId, cells: cells,
                                  imageStats: imageStats ?? [:])
        det.image = image
        image.detection = det
        context.insert(det)
        try? context.save()
    }

    func recordCorrection(_ correction: CorrectionRecord, on detection: DetectionRecord) {
        correction.detection = detection
        detection.corrections.append(correction)
        context.insert(correction)
        try? context.save()
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

    /// Counts individual low-confidence CELLS (not detections) across all stored
    /// detections, subtracting any cells the user has already triaged.
    /// A cell is "triaged" when a CorrectionRecord exists for its `cellId` with
    /// any kind — "remove", "accept", "resize", "move", or "add". This keeps the
    /// sidebar badge consistent with the ReviewQueueView's `correctedIds` filter.
    func uncorrectedCellCount(below confidence: Double) -> Int {
        let desc = FetchDescriptor<DetectionRecord>(
            predicate: #Predicate { $0.minConfidence < confidence })
        let detections = (try? context.fetch(desc)) ?? []
        return detections.reduce(0) { sum, det in
            let correctedIds = Set(det.corrections.map { $0.cellId })
            return sum + det.cells.filter {
                $0.confidence < confidence && !correctedIds.contains($0.id)
            }.count
        }
    }
}
