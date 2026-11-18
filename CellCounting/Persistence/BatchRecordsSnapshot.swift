import Foundation
import SwiftData

/// Plain, Sendable copies of every stored row that belongs to one batch.
///
/// SwiftData models are bound to the context (and actor) that fetched them.
/// Archive and restore read rows on the main actor in small chunks, copy them
/// into these value types, and write fresh rows into a different store, so no
/// model object ever crosses a store or an actor boundary. Every stored field
/// of the records in `Records.swift` is mirrored here; add new fields to both.
nonisolated struct BatchRecordsSnapshot: Sendable, Equatable {
    nonisolated struct Batch: Sendable, Equatable {
        var id: UUID
        var name: String
        var createdAt: Date
        var displayName: String
        var modelId: String
        var pxPerUm: Double
        var thresholdsData: Data
        var condition: String?
        var pxPerUmSource: String?
        var imageCountSummary: Int
        var cellCountSummary: Int
        var contentRevision: Int
        var insightsData: Data?
        var insightsRevision: Int
        /// Optional/defaulted on the record, so an archive written before
        /// this field existed opens with false.
        var recalibrationPending: Bool
    }

    nonisolated struct Image: Sendable, Equatable {
        var id: UUID
        var fileName: String
        var originalPath: String
        var widthPx: Int
        var heightPx: Int
        var importedAt: Date
        var sourcePxPerUm: Double?
        var sourceCalibrationSource: String?
        var jobItemId: UUID?
        var sourceOrder: Int?
        var confidenceOverride: Double?
        var fileHash: String?
        var notes: String?
        var detection: Detection?
        var rois: [ROI]
        var reviewCandidates: [ReviewCandidate]
        var variants: [Variant]
        var annotations: [Annotation]
        /// Per-image scale fields. Optional on the record, so an archive
        /// written before they existed opens with nil (the batch's scale).
        var scalePxPerUm: Double? = nil
        var scaleSource: String? = nil
        var measuredPxPerUm: Double? = nil
        var measuredScaleSource: String? = nil

        /// Extension of the library's own copy, matching `ImageRecord.storedURL`.
        var storedExtension: String {
            let raw = (fileName as NSString).pathExtension
            return raw.isEmpty ? "tif" : raw.lowercased()
        }
    }

    nonisolated struct Detection: Sendable, Equatable {
        var id: UUID
        var detectorId: String
        var ranAt: Date
        /// Stored form (compressed or plain JSON), from `StoredCellsRecord`
        /// or, for rows not moved yet, the detection row itself.
        var cellsData: Data
        /// Nil for rows not moved yet and in archives written before it existed.
        var cellsContentHash: String?
        var minConfidence: Double
        var cellCountSummary: Int
        var cellsRevision: Int
        var reviewPendingCount: Int
        var reviewIndexVersion: Int
        var imageStatsData: Data?
        var runSettingsData: Data?
        /// Optional/defaulted on the record, so an archive written before
        /// these fields existed opens with nil and 0 (metrics not written).
        var cellMetricsData: Data?
        var cellMetricsVersion: Int
        var corrections: [Correction]
    }

    nonisolated struct Correction: Sendable, Equatable {
        var id: UUID
        var kind: String
        var cellId: UUID
        var cx: Double
        var cy: Double
        var diameter: Double
        var createdAt: Date
    }

    nonisolated struct ROI: Sendable, Equatable {
        var id: UUID
        var imageId: UUID
        var kind: String
        var shape: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var createdAt: Date
        var name: String?
        var linkedToImage: Bool
    }

    nonisolated struct ReviewCandidate: Sendable, Equatable {
        var id: UUID
        var cellId: UUID
        var sortKey: String
        var detectionId: UUID
        var imageId: UUID
        var confidence: Double
        var cx: Double
        var cy: Double
        var diameter: Double
        var diameterPx: Double
        var triaged: Bool
        var createdAt: Date
        var linkedToDetection: Bool
        var linkedToImage: Bool
    }

    nonisolated struct Variant: Sendable, Equatable {
        var id: UUID
        var imageId: UUID
        var detectorId: String
        var label: String
        var createdAt: Date
        var cellsData: Data
        var cellCount: Int
        var meanConfidence: Double
        var measurementPxPerUm: Double?
        var runSettingsData: Data?
        var imageStatsData: Data?
        var detectionRanAt: Date?
        /// Optional/defaulted on the record, so an archive written before
        /// these fields existed opens with nil and 0 (plain JSON).
        var contentHash: String?
        var storageFormat: Int
        var linkedToImage: Bool
    }

    nonisolated struct Annotation: Sendable, Equatable {
        var id: UUID
        var imageId: UUID
        var cx: Double
        var cy: Double
        var diameter: Double?
        var createdAt: Date
        var note: String?
    }

    nonisolated struct Condition: Sendable, Equatable {
        var id: UUID
        var name: String
        var color: String
        var createdAt: Date
        var order: Int
    }

    var batch: Batch
    /// Sorted by import date, then id, so chunked reads are deterministic.
    var images: [Image]
    /// The `ConditionRecord`(s) named by `batch.condition`.
    var conditions: [Condition]
    /// Review index rows that pointed at a superseded detection. They are not
    /// copied (the app deletes such rows itself on launch) but are counted so
    /// verification can account for every row it read.
    var skippedStaleReviewRows: Int = 0

    var detectionCount: Int { images.reduce(0) { $0 + ($1.detection == nil ? 0 : 1) } }
    var correctionCount: Int { images.reduce(0) { $0 + ($1.detection?.corrections.count ?? 0) } }
    var roiCount: Int { images.reduce(0) { $0 + $1.rois.count } }
    var reviewCandidateCount: Int { images.reduce(0) { $0 + $1.reviewCandidates.count } }
    var variantCount: Int { images.reduce(0) { $0 + $1.variants.count } }
    var annotationCount: Int { images.reduce(0) { $0 + $1.annotations.count } }
    /// True when every detection already carries its denormalised cell count.
    var hasCompleteCellSummaries: Bool {
        images.allSatisfy { ($0.detection?.cellCountSummary ?? 0) >= 0 }
    }
}

/// Library-wide presets copied into an archive so its calibration choices
/// stay readable alongside the batch.
nonisolated struct LibraryPresetsSnapshot: Sendable, Equatable {
    nonisolated struct Calibration: Sendable, Equatable {
        var id: UUID
        var name: String
        var pxPerUm: Double
        var isDefault: Bool
    }

    nonisolated struct Bins: Sendable, Equatable {
        var id: UUID
        var name: String
        var thresholdsData: Data
    }

    var calibration: [Calibration]
    var bins: [Bins]
}

// MARK: - Reading rows (main actor, chunked)

@MainActor
enum BatchRecordsSnapshotter {
    /// Number of images whose rows are read or written between yields.
    static let chunkSize = 12

    /// Copies a batch and everything that belongs to it. Reads happen in small
    /// chunks with a short suspension between them so the window stays live.
    /// `perImage` runs once per image while its model is still in hand (used
    /// for export-only values such as provenance).
    static func snapshot(batch: BatchRecord,
                         in context: ModelContext,
                         perImage: ((ImageRecord) -> Void)? = nil,
                         onChunk: ((_ done: Int, _ total: Int) -> Void)? = nil) async throws -> BatchRecordsSnapshot {
        let batchRow = BatchRecordsSnapshot.Batch(batch)
        let images = batch.images.sorted {
            $0.importedAt != $1.importedAt ? $0.importedAt < $1.importedAt
                : $0.id.uuidString < $1.id.uuidString
        }
        var rows: [BatchRecordsSnapshot.Image] = []
        rows.reserveCapacity(images.count)
        var skippedReviewRows = 0
        var start = 0
        while start < images.count {
            try Task.checkCancellation()
            let chunk = Array(images[start..<min(start + chunkSize, images.count)])
            let ids = chunk.map(\.id)
            let reviewRows = try context.fetch(FetchDescriptor<ReviewCandidateRecord>(
                predicate: #Predicate { ids.contains($0.imageId) }))
            let variants = try context.fetch(FetchDescriptor<SegmentationVariantRecord>(
                predicate: #Predicate { ids.contains($0.imageId) }))
            let annotations = try context.fetch(FetchDescriptor<GroundTruthAnnotation>(
                predicate: #Predicate { ids.contains($0.imageId) }))
            let roisByImageId = try context.fetch(FetchDescriptor<ROIRecord>(
                predicate: #Predicate { ids.contains($0.imageId) }))
            for image in chunk {
                let detection = image.detection
                var roiRows: [UUID: BatchRecordsSnapshot.ROI] = [:]
                for roi in image.rois { roiRows[roi.id] = .init(roi) }
                for roi in roisByImageId where roi.imageId == image.id && roiRows[roi.id] == nil {
                    roiRows[roi.id] = .init(roi)
                }
                var review: [BatchRecordsSnapshot.ReviewCandidate] = []
                for row in reviewRows where row.imageId == image.id {
                    // Only index rows for the image's live detection are real
                    // data; rows for a replaced detection are stale leftovers.
                    if let detection, row.detectionId == detection.id {
                        review.append(.init(row))
                    } else {
                        skippedReviewRows += 1
                    }
                }
                rows.append(BatchRecordsSnapshot.Image(
                    image,
                    detection: detection.map(BatchRecordsSnapshot.Detection.init),
                    rois: roiRows.values.sorted { $0.id.uuidString < $1.id.uuidString },
                    reviewCandidates: review.sorted { $0.id.uuidString < $1.id.uuidString },
                    variants: variants.filter { $0.imageId == image.id }
                        .map(BatchRecordsSnapshot.Variant.init)
                        .sorted { $0.id.uuidString < $1.id.uuidString },
                    annotations: annotations.filter { $0.imageId == image.id }
                        .map(BatchRecordsSnapshot.Annotation.init)
                        .sorted { $0.id.uuidString < $1.id.uuidString }))
                perImage?(image)
            }
            start += chunk.count
            onChunk?(start, images.count)
            await LibraryTransferPacing.breathe()
        }
        var conditions: [BatchRecordsSnapshot.Condition] = []
        if let name = batch.condition {
            conditions = try context.fetch(FetchDescriptor<ConditionRecord>(
                predicate: #Predicate { $0.name == name }))
                .map(BatchRecordsSnapshot.Condition.init)
                .sorted { $0.id.uuidString < $1.id.uuidString }
        }
        return BatchRecordsSnapshot(batch: batchRow, images: rows, conditions: conditions,
                                    skippedStaleReviewRows: skippedReviewRows)
    }

    static func presets(in context: ModelContext) throws -> LibraryPresetsSnapshot {
        let calibration = try context.fetch(FetchDescriptor<CalibrationPresetRecord>())
            .map { LibraryPresetsSnapshot.Calibration(id: $0.id, name: $0.name, pxPerUm: $0.pxPerUm, isDefault: $0.isDefault) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let bins = try context.fetch(FetchDescriptor<BinPresetRecord>())
            .map { LibraryPresetsSnapshot.Bins(id: $0.id, name: $0.name, thresholdsData: $0.thresholdsData) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return LibraryPresetsSnapshot(calibration: calibration, bins: bins)
    }

    // MARK: - Writing rows

    /// Inserts a batch and all of its rows into `context`, preserving every id,
    /// date and stored value. When `saveEveryChunk` is false nothing is saved,
    /// so the caller can commit the whole batch in one transaction.
    @discardableResult
    static func insert(_ snapshot: BatchRecordsSnapshot,
                       into context: ModelContext,
                       saveEveryChunk: Bool,
                       onChunk: ((_ done: Int, _ total: Int) -> Void)? = nil) async throws -> BatchRecord {
        let batch = snapshot.batch.makeRecord()
        context.insert(batch)
        var start = 0
        while start < snapshot.images.count {
            try Task.checkCancellation()
            let end = min(start + chunkSize, snapshot.images.count)
            for row in snapshot.images[start..<end] {
                insert(row, batch: batch, into: context)
            }
            if saveEveryChunk { try context.save() }
            start = end
            onChunk?(start, snapshot.images.count)
            await LibraryTransferPacing.breathe()
        }
        return batch
    }

    private static func insert(_ row: BatchRecordsSnapshot.Image, batch: BatchRecord, into context: ModelContext) {
        let image = row.makeRecord()
        context.insert(image)
        image.batch = batch

        var detection: DetectionRecord?
        if let source = row.detection {
            let record = source.makeRecord()
            context.insert(record)
            record.image = image
            image.detection = record
            for correction in source.corrections {
                let copy = correction.makeRecord()
                context.insert(copy)
                copy.detection = record
            }
            detection = record
        }
        for roi in row.rois {
            let copy = roi.makeRecord()
            context.insert(copy)
            if roi.linkedToImage { copy.image = image }
        }
        if let detection {
            for candidate in row.reviewCandidates {
                let copy = candidate.makeRecord(detection: detection, image: image)
                context.insert(copy)
            }
        }
        for variant in row.variants {
            let copy = variant.makeRecord(image: image)
            context.insert(copy)
        }
        for annotation in row.annotations {
            context.insert(annotation.makeRecord())
        }
    }
}

/// Short main-actor suspension between chunks. `Task.yield()` alone can be
/// resumed before the run loop handles input; a 1 ms sleep always lets AppKit
/// draw and process events (including the Cancel button).
nonisolated enum LibraryTransferPacing {
    static func breathe() async {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

// MARK: - Model <-> value conversions

extension BatchRecordsSnapshot.Batch {
    @MainActor init(_ r: BatchRecord) {
        self.init(id: r.id, name: r.name, createdAt: r.createdAt, displayName: r.displayName,
                  modelId: r.modelId, pxPerUm: r.pxPerUm, thresholdsData: r.thresholdsData,
                  condition: r.condition, pxPerUmSource: r.pxPerUmSource,
                  imageCountSummary: r.imageCountSummary, cellCountSummary: r.cellCountSummary,
                  contentRevision: r.contentRevision, insightsData: r.insightsData,
                  insightsRevision: r.insightsRevision, recalibrationPending: r.recalibrationPending)
    }

    @MainActor func makeRecord() -> BatchRecord {
        let r = BatchRecord(id: id, name: name, displayName: displayName, modelId: modelId,
                            pxPerUm: pxPerUm, thresholds: [], condition: condition)
        r.createdAt = createdAt
        r.thresholdsData = thresholdsData
        r.pxPerUmSource = pxPerUmSource
        r.imageCountSummary = imageCountSummary
        r.cellCountSummary = cellCountSummary
        r.contentRevision = contentRevision
        r.insightsData = insightsData
        r.insightsRevision = insightsRevision
        r.recalibrationPending = recalibrationPending
        return r
    }
}

extension BatchRecordsSnapshot.Image {
    @MainActor init(_ r: ImageRecord,
                    detection: BatchRecordsSnapshot.Detection?,
                    rois: [BatchRecordsSnapshot.ROI],
                    reviewCandidates: [BatchRecordsSnapshot.ReviewCandidate],
                    variants: [BatchRecordsSnapshot.Variant],
                    annotations: [BatchRecordsSnapshot.Annotation]) {
        self.init(id: r.id, fileName: r.fileName, originalPath: r.originalPath,
                  widthPx: r.widthPx, heightPx: r.heightPx, importedAt: r.importedAt,
                  sourcePxPerUm: r.sourcePxPerUm, sourceCalibrationSource: r.sourceCalibrationSource,
                  jobItemId: r.jobItemId, sourceOrder: r.sourceOrder,
                  confidenceOverride: r.confidenceOverride, fileHash: r.fileHash, notes: r.notes,
                  detection: detection, rois: rois, reviewCandidates: reviewCandidates,
                  variants: variants, annotations: annotations,
                  scalePxPerUm: r.scalePxPerUm, scaleSource: r.scaleSource,
                  measuredPxPerUm: r.measuredPxPerUm, measuredScaleSource: r.measuredScaleSource)
    }

    @MainActor func makeRecord() -> ImageRecord {
        let r = ImageRecord(id: id, fileName: fileName, originalPath: originalPath,
                            widthPx: widthPx, heightPx: heightPx)
        r.importedAt = importedAt
        r.sourcePxPerUm = sourcePxPerUm
        r.sourceCalibrationSource = sourceCalibrationSource
        r.scalePxPerUm = scalePxPerUm
        r.scaleSource = scaleSource
        r.measuredPxPerUm = measuredPxPerUm
        r.measuredScaleSource = measuredScaleSource
        r.jobItemId = jobItemId
        r.sourceOrder = sourceOrder
        r.confidenceOverride = confidenceOverride
        r.fileHash = fileHash
        r.notes = notes
        return r
    }
}

extension BatchRecordsSnapshot.Detection {
    @MainActor init(_ r: DetectionRecord) {
        self.init(id: r.id, detectorId: r.detectorId, ranAt: r.ranAt, cellsData: r.cellsData,
                  cellsContentHash: r.cellsContentHash,
                  minConfidence: r.minConfidence, cellCountSummary: r.cellCountSummary,
                  cellsRevision: r.cellsRevision, reviewPendingCount: r.reviewPendingCount,
                  reviewIndexVersion: r.reviewIndexVersion, imageStatsData: r.imageStatsData,
                  runSettingsData: r.runSettingsData,
                  cellMetricsData: r.cellMetricsData, cellMetricsVersion: r.cellMetricsVersion,
                  corrections: r.corrections.map(BatchRecordsSnapshot.Correction.init)
                      .sorted { $0.id.uuidString < $1.id.uuidString })
    }

    @MainActor func makeRecord() -> DetectionRecord {
        let r = DetectionRecord(detectorId: detectorId, cells: [])
        // The initializer seeds the shared decode cache under a throwaway id.
        DecodedCellCache.shared.remove(r.id)
        r.id = id
        r.ranAt = ranAt
        // The exact stored bytes, never re-encoded; copies always use the
        // separate cells row, even from an archive whose rows were inline.
        r.storeCells(cellsData, contentHash: cellsContentHash)
        r.minConfidence = minConfidence
        r.cellCountSummary = cellCountSummary
        r.cellsRevision = cellsRevision
        r.reviewPendingCount = reviewPendingCount
        r.reviewIndexVersion = reviewIndexVersion
        r.imageStatsData = imageStatsData
        r.runSettingsData = runSettingsData
        r.cellMetricsData = cellMetricsData
        r.cellMetricsVersion = cellMetricsVersion
        return r
    }
}

extension BatchRecordsSnapshot.Correction {
    @MainActor init(_ r: CorrectionRecord) {
        self.init(id: r.id, kind: r.kind, cellId: r.cellId, cx: r.cx, cy: r.cy,
                  diameter: r.diameter, createdAt: r.createdAt)
    }

    @MainActor func makeRecord() -> CorrectionRecord {
        let r = CorrectionRecord(kind: kind, cellId: cellId, cx: cx, cy: cy, diameter: diameter)
        r.id = id
        r.createdAt = createdAt
        return r
    }
}

extension BatchRecordsSnapshot.ROI {
    @MainActor init(_ r: ROIRecord) {
        self.init(id: r.id, imageId: r.imageId, kind: r.kind, shape: r.shape, x: r.x, y: r.y,
                  width: r.width, height: r.height, createdAt: r.createdAt, name: r.name,
                  linkedToImage: r.image != nil)
    }

    @MainActor func makeRecord() -> ROIRecord {
        let r = ROIRecord(id: id, imageId: imageId, kind: kind, shape: shape, x: x, y: y,
                          width: width, height: height, name: name)
        r.createdAt = createdAt
        return r
    }
}

extension BatchRecordsSnapshot.ReviewCandidate {
    @MainActor init(_ r: ReviewCandidateRecord) {
        self.init(id: r.id, cellId: r.cellId, sortKey: r.sortKey, detectionId: r.detectionId,
                  imageId: r.imageId, confidence: r.confidence, cx: r.cx, cy: r.cy,
                  diameter: r.diameter, diameterPx: r.diameterPx, triaged: r.triaged,
                  createdAt: r.createdAt, linkedToDetection: r.detection != nil,
                  linkedToImage: r.image != nil)
    }

    @MainActor func makeRecord(detection: DetectionRecord, image: ImageRecord) -> ReviewCandidateRecord {
        let cell = DetectedCell(id: cellId, cx: cx, cy: cy, diameter: diameter,
                                diameterPx: diameterPx, confidence: confidence)
        let r = ReviewCandidateRecord(cell: cell, detection: detection, image: image)
        r.id = id
        r.sortKey = sortKey
        r.detectionId = detectionId
        r.imageId = imageId
        r.triaged = triaged
        r.createdAt = createdAt
        if !linkedToDetection { r.detection = nil }
        if !linkedToImage { r.image = nil }
        return r
    }
}

extension BatchRecordsSnapshot.Variant {
    @MainActor init(_ r: SegmentationVariantRecord) {
        self.init(id: r.id, imageId: r.imageId, detectorId: r.detectorId, label: r.label,
                  createdAt: r.createdAt, cellsData: r.cellsData, cellCount: r.cellCount,
                  meanConfidence: r.meanConfidence, measurementPxPerUm: r.measurementPxPerUm,
                  runSettingsData: r.runSettingsData, imageStatsData: r.imageStatsData,
                  detectionRanAt: r.detectionRanAt, contentHash: r.contentHash,
                  storageFormat: r.storageFormat, linkedToImage: r.image != nil)
    }

    @MainActor func makeRecord(image: ImageRecord) -> SegmentationVariantRecord {
        let r = SegmentationVariantRecord(image: image, detectorId: detectorId, label: label, cells: [])
        r.id = id
        r.imageId = imageId
        r.createdAt = createdAt
        r.cellsData = cellsData
        r.cellCount = cellCount
        r.meanConfidence = meanConfidence
        r.measurementPxPerUm = measurementPxPerUm
        r.runSettingsData = runSettingsData
        r.imageStatsData = imageStatsData
        r.detectionRanAt = detectionRanAt
        r.contentHash = contentHash
        r.storageFormat = storageFormat
        if !linkedToImage { r.image = nil }
        return r
    }
}

extension BatchRecordsSnapshot.Annotation {
    @MainActor init(_ r: GroundTruthAnnotation) {
        self.init(id: r.id, imageId: r.imageId, cx: r.cx, cy: r.cy, diameter: r.diameter,
                  createdAt: r.createdAt, note: r.note)
    }

    @MainActor func makeRecord() -> GroundTruthAnnotation {
        let r = GroundTruthAnnotation(id: id, imageId: imageId, cx: cx, cy: cy,
                                      diameter: diameter, note: note)
        r.createdAt = createdAt
        return r
    }
}

extension BatchRecordsSnapshot.Condition {
    @MainActor init(_ r: ConditionRecord) {
        self.init(id: r.id, name: r.name, color: r.color, createdAt: r.createdAt, order: r.order)
    }

    @MainActor func makeRecord() -> ConditionRecord {
        let r = ConditionRecord(id: id, name: name, color: color, order: order)
        r.createdAt = createdAt
        return r
    }
}

extension LibraryPresetsSnapshot.Calibration {
    @MainActor func makeRecord() -> CalibrationPresetRecord {
        let r = CalibrationPresetRecord(name: name, pxPerUm: pxPerUm, isDefault: isDefault)
        r.id = id
        return r
    }
}

extension LibraryPresetsSnapshot.Bins {
    @MainActor func makeRecord() -> BinPresetRecord {
        let r = BinPresetRecord(name: name, thresholds: [])
        r.id = id
        r.thresholdsData = thresholdsData
        return r
    }
}
