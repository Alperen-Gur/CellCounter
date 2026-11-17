import Foundation
import SwiftData

/// Reads what the Batches, Images, Compare and tracking screens show without
/// decoding cell outlines, in short-lived `ModelContext`s on the library's
/// container and away from the main actor. Only plain values come back, so
/// no screen keeps model objects (or the payloads loaded with them) alive.
///
/// SwiftData loads every stored attribute of a fetched row, even when
/// `propertiesToFetch` is set, so a fetched detection always brings its whole
/// row. Detections are therefore read a small chunk at a time, each chunk in
/// its own context, and only their compact metrics are decoded; the full
/// payload is decoded only for rows the backfill has not reached yet.
nonisolated enum LibraryMetricsReader {
    /// Detections per context; bounds how many rows are in memory at once.
    static let chunkSize = 16

    nonisolated struct DetectionKey: Hashable, Sendable {
        let id: UUID
        let revision: Int
    }

    /// Which detections' metrics to return. Callers that cache per
    /// `DetectionKey` ask only for the ones they do not have.
    nonisolated enum MetricsNeed: Sendable {
        case none
        case all
        case allExcept(Set<DetectionKey>)

        func wants(_ key: DetectionKey) -> Bool {
            switch self {
            case .none: return false
            case .all: return true
            case .allExcept(let known): return !known.contains(key)
            }
        }
    }

    nonisolated struct DetectionEntry: Sendable {
        let id: UUID
        let cellsRevision: Int
        /// `DetectionRecord.summaryCellCount`.
        let cellCount: Int
        /// Nil unless requested through `MetricsNeed`.
        let metrics: CellMetrics?

        var key: DetectionKey { DetectionKey(id: id, revision: cellsRevision) }
    }

    nonisolated struct ImageEntry: Sendable {
        let id: UUID
        let batchId: UUID?
        let fileName: String
        let originalPath: String
        let widthPx: Int
        let heightPx: Int
        let importedAt: Date
        let sourceOrder: Int?
        let notes: String?
        let hasDetection: Bool
        /// The image's own cut-off: its override, else the one its analysis
        /// ran with. Nil means the app-wide confidence applies, exactly as in
        /// `AppState.effectiveConfidence(for:)`.
        let savedCutoff: Double?
        /// Nil when the image has no detection or details were not requested.
        let detection: DetectionEntry?

        func cutoff(global: Double) -> Double { savedCutoff ?? global }

        /// The same entry without its metrics, for callers that keep entries
        /// after computing what they show.
        var withoutMetrics: ImageEntry {
            guard let detection, detection.metrics != nil else { return self }
            return ImageEntry(id: id, batchId: batchId, fileName: fileName, originalPath: originalPath,
                              widthPx: widthPx, heightPx: heightPx, importedAt: importedAt,
                              sourceOrder: sourceOrder, notes: notes, hasDetection: hasDetection,
                              savedCutoff: savedCutoff,
                              detection: DetectionEntry(id: detection.id, cellsRevision: detection.cellsRevision,
                                                        cellCount: detection.cellCount, metrics: nil))
        }
    }

    // MARK: Batches

    /// Every image of a batch, ordered by import date then id, with detection
    /// details and the requested metrics.
    static func batchImages(batchId: UUID, container: ModelContainer,
                            metrics need: MetricsNeed) throws -> [ImageEntry] {
        let images: [ImageEntry] = try autoreleasepool {
            let context = readContext(container)
            let rows = try context.fetch(FetchDescriptor<ImageRecord>(
                predicate: #Predicate { $0.batch?.id == batchId }))
            return rows.map { imageEntry($0, batchId: batchId, detection: nil) }
                .sorted(by: importOrder)
        }
        return try attachDetections(to: images, container: container, metrics: need)
    }

    /// One image with its detection details and metrics; nil if it is gone.
    /// `resolvingBatch: false` leaves `batchId` nil and skips loading the
    /// batch row, for callers that already know the batch.
    static func image(id: UUID, container: ModelContainer, metrics need: MetricsNeed,
                      resolvingBatch: Bool = true) throws -> ImageEntry? {
        try autoreleasepool {
            let context = readContext(container)
            var query = FetchDescriptor<ImageRecord>(predicate: #Predicate { $0.id == id })
            query.fetchLimit = 1
            guard let image = try context.fetch(query).first else { return nil }
            let batchId = resolvingBatch ? image.batch?.id : nil
            guard let detection = image.detection else {
                return imageEntry(image, batchId: batchId, detection: nil)
            }
            return imageEntry(image, batchId: batchId,
                              detection: detectionEntry(detection, metrics: need),
                              runCutoff: runCutoff(detection.runSettingsData))
        }
    }

    /// Batch ids per condition, newest first (as `Repositories.batches(matching:)`).
    static func batchIds(condition: String, container: ModelContainer) throws -> [UUID] {
        try autoreleasepool {
            let context = readContext(container)
            return try context.fetch(FetchDescriptor<BatchRecord>(
                predicate: #Predicate { $0.condition == condition },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)])).map(\.id)
        }
    }

    /// Image count and folder label per batch, from image rows only.
    static func folderInfo(batchIds: [UUID], container: ModelContainer) throws -> [UUID: BatchFolderInfo] {
        var result: [UUID: BatchFolderInfo] = [:]
        for batchId in batchIds {
            try Task.checkCancellation()
            result[batchId] = try autoreleasepool {
                let context = readContext(container)
                let paths = try context.fetch(FetchDescriptor<ImageRecord>(
                    predicate: #Predicate { $0.batch?.id == batchId })).map(\.originalPath)
                return BatchFolderInfo(imageCount: paths.count,
                                       label: BatchFolderInfo.label(originalPaths: paths))
            }
        }
        return result
    }

    // MARK: Library

    /// All images, newest import first, without detection details; plus each
    /// batch's size thresholds.
    static func library(container: ModelContainer) throws -> (images: [ImageEntry], thresholds: [UUID: [Double]]) {
        try autoreleasepool {
            let context = readContext(container)
            let batches = try context.fetch(FetchDescriptor<BatchRecord>())
            var thresholds: [UUID: [Double]] = [:]
            for batch in batches { thresholds[batch.id] = decodeThresholds(batch.thresholdsData) }
            let images = try context.fetch(FetchDescriptor<ImageRecord>(
                sortBy: [SortDescriptor(\.importedAt, order: .reverse)]))
            return (images.map { imageEntry($0, batchId: $0.batch?.id, detection: nil) }, thresholds)
        }
    }

    /// Runs a read on a detached task, cancelling it with the caller. Nil
    /// when the read failed or was cancelled.
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> T? {
        let task = Task.detached(priority: .userInitiated) { () -> T? in try? work() }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    // MARK: Helpers

    /// `BatchRecord.thresholds`.
    static func decodeThresholds(_ data: Data) -> [Double] {
        (try? JSONDecoder().decode([Double].self, from: data)) ?? [20, 30]
    }

    private static func readContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private static func importOrder(_ lhs: ImageEntry, _ rhs: ImageEntry) -> Bool {
        lhs.importedAt != rhs.importedAt ? lhs.importedAt < rhs.importedAt
            : lhs.id.uuidString < rhs.id.uuidString
    }

    /// `runCutoff` is the detection's run-settings cut-off when its row was
    /// read; without it only the image's override is known.
    private static func imageEntry(_ image: ImageRecord, batchId: UUID?,
                                   detection: DetectionEntry?, runCutoff: Double? = nil) -> ImageEntry {
        // Checking the relationship for nil does not load the detection row.
        let hasDetection = image.detection != nil
        return ImageEntry(id: image.id, batchId: batchId, fileName: image.fileName,
                          originalPath: image.originalPath, widthPx: image.widthPx,
                          heightPx: image.heightPx, importedAt: image.importedAt,
                          sourceOrder: image.sourceOrder, notes: image.notes,
                          hasDetection: hasDetection,
                          savedCutoff: image.confidenceOverride ?? runCutoff,
                          detection: detection)
    }

    /// `DetectionRecord.runSettings?.confidence`.
    private static func runCutoff(_ data: Data?) -> Double? {
        data.flatMap { try? JSONDecoder().decode(AnalysisRunSettings.self, from: $0) }?.confidence
    }

    private static func detectionEntry(_ detection: DetectionRecord, metrics need: MetricsNeed) -> DetectionEntry {
        let key = DetectionKey(id: detection.id, revision: detection.cellsRevision)
        let summary = detection.cellCountSummary
        // Legacy rows without a stored count take it from their cells, as
        // `summaryCellCount` does.
        let metrics: CellMetrics? = (need.wants(key) || summary < 0)
            ? DetectionRecord.metrics(storedData: detection.cellMetricsData,
                                      version: detection.cellMetricsVersion,
                                      cellCountSummary: summary,
                                      payload: { detection.cellsData })
            : nil
        return DetectionEntry(id: key.id, cellsRevision: key.revision,
                              cellCount: summary >= 0 ? summary : (metrics?.count ?? 0),
                              metrics: need.wants(key) ? metrics : nil)
    }

    /// Reads the detections of `images` in chunks, each in its own context,
    /// and returns the entries (same order) with detection details and the
    /// full saved cut-off. An image whose detection was removed meanwhile
    /// comes back without one; the change notification refreshes again.
    private static func attachDetections(to images: [ImageEntry], container: ModelContainer,
                                         metrics need: MetricsNeed) throws -> [ImageEntry] {
        var details: [UUID: (DetectionEntry, Double?)] = [:]
        let withDetection = images.filter(\.hasDetection).map(\.id)
        var start = 0
        while start < withDetection.count {
            try Task.checkCancellation()
            let ids = Array(withDetection[start..<min(start + chunkSize, withDetection.count)])
            try autoreleasepool {
                let context = readContext(container)
                let rows = try context.fetch(FetchDescriptor<ImageRecord>(
                    predicate: #Predicate { ids.contains($0.id) }))
                // Registers the chunk's detections, so `image.detection` below
                // resolves without one query per image.
                _ = try context.fetch(FetchDescriptor<DetectionRecord>(
                    predicate: #Predicate { detection in
                        detection.image.flatMap { ids.contains($0.id) } ?? false
                    }))
                for image in rows {
                    guard let detection = image.detection else { continue }
                    let saved = image.confidenceOverride ?? runCutoff(detection.runSettingsData)
                    details[image.id] = (detectionEntry(detection, metrics: need), saved)
                }
            }
            start += ids.count
        }
        return images.map { entry in
            let found = details[entry.id]
            guard entry.hasDetection else { return entry }
            return ImageEntry(id: entry.id, batchId: entry.batchId, fileName: entry.fileName,
                              originalPath: entry.originalPath, widthPx: entry.widthPx,
                              heightPx: entry.heightPx, importedAt: entry.importedAt,
                              sourceOrder: entry.sourceOrder, notes: entry.notes,
                              hasDetection: found != nil, savedCutoff: found?.1 ?? entry.savedCutoff,
                              detection: found?.0)
        }
    }
}

/// What the batch list shows about a batch's images.
nonisolated struct BatchFolderInfo: Sendable, Equatable {
    let imageCount: Int
    let label: String?

    /// Best-effort "uploaded folder" name for a batch, derived from its
    /// images' original (pre-import) paths, NOT `batch.displayName`. For
    /// multi-file imports `displayName` is a generic "Batch · N images ·
    /// <date>" string (see `AppState.proceedWithImport`), which is exactly
    /// the "labels each batch 'Batch'" complaint from researcher feedback #7a.
    /// Returns the shared parent directory's last path component when every
    /// image was imported from the same folder; nil when that can't be
    /// determined (single image, mixed-origin batch, or blank original paths),
    /// and callers fall back to `displayName`.
    static func label(originalPaths: [String]) -> String? {
        guard originalPaths.count > 1 else { return nil }
        let parents = Set(originalPaths.compactMap { path -> String? in
            guard !path.isEmpty else { return nil }
            let parent = (path as NSString).deletingLastPathComponent
            return parent.isEmpty ? nil : parent
        })
        guard parents.count == 1, let common = parents.first else { return nil }
        let name = (common as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
