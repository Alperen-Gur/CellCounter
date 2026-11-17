import Foundation
import SwiftData

@Model
final class BatchRecord {
    #Index<BatchRecord>([\.createdAt], [\.condition])
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    /// Free-form description ("Plate B12 — keratinocyte enrichment").
    var displayName: String
    /// The detection model id used for this batch ("cp-cyto3", "yo-s", custom uuid…).
    var modelId: String
    /// pxPerUm at the time of analysis (calibration is per-batch since microscopes don't change mid-batch).
    var pxPerUm: Double
    /// Saved thresholds JSON (e.g. [20, 30]).
    var thresholdsData: Data
    /// Pass-6: optional inhibitor/experimental condition tag (e.g. "Control", "F+X").
    /// nil = batch was imported without a condition tag (legacy or skipped).
    var condition: String? = nil
    /// Pass-18 (Lane R): provenance — where the batch's `pxPerUm` came from.
    /// One of: "exif-omeXML", "exif-tiff", "exif-imagej", "exif-olympus",
    /// "preset-<name>", "manual", "default". Optional with a default so
    /// existing SwiftData rows decode unchanged (auto-migration friendly).
    var pxPerUmSource: String? = nil
    /// Denormalized summaries used by Home/Batch rows. Reading `totalCells`
    /// used to decode every image's JSON detection blob during each SwiftUI
    /// render, which made a 700-image library noticeably stall the Home view.
    /// Existing rows start at -1 and are backfilled incrementally.
    var imageCountSummary: Int = -1
    var cellCountSummary: Int = -1
    /// Monotonic invalidation token for cached batch analytics. Detection,
    /// mask-edit, and calibration commits increment it; opening Results does
    /// not recompute expensive plots unless this value changed.
    var contentRevision: Int = 0
    /// Persisted heuristic/plot snapshot. Optional for migration safety.
    var insightsData: Data? = nil
    var insightsRevision: Int = -1
    /// True from the start of a recalibration (`AppState.recalibrateBatch`)
    /// until every analysed image has been rewritten at `pxPerUm`. It is set
    /// together with the new `pxPerUm`, so any save that stores part of a
    /// pass stores it too, and a pass stopped partway (error, quit, crash) is
    /// completed by the next recalibration even at the same scale. Defaulted,
    /// so existing rows and older archives read false.
    var recalibrationPending: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \ImageRecord.batch)
    var images: [ImageRecord] = []

    init(id: UUID = UUID(), name: String, displayName: String,
         modelId: String, pxPerUm: Double, thresholds: [Double],
         condition: String? = nil) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.createdAt = Date()
        self.modelId = modelId
        self.pxPerUm = pxPerUm
        self.thresholdsData = (try? JSONEncoder().encode(thresholds)) ?? Data()
        self.condition = condition
        self.imageCountSummary = 0
        self.cellCountSummary = 0
        self.contentRevision = 0
    }

    var thresholds: [Double] {
        get { (try? JSONDecoder().decode([Double].self, from: thresholdsData)) ?? [20, 30] }
        set { thresholdsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var totalCells: Int {
        if cellCountSummary >= 0 { return cellCountSummary }
        return images.reduce(0) { $0 + ($1.detection?.summaryCellCount ?? 0) }
    }

    var imageCount: Int { imageCountSummary >= 0 ? imageCountSummary : images.count }
}

@Model
final class ImageRecord {
    #Index<ImageRecord>([\.jobItemId], [\.fileHash])
    var sourcePxPerUm: Double? = nil
    var sourceCalibrationSource: String? = nil
    var jobItemId: UUID? = nil
    var sourceOrder: Int? = nil
    @Attribute(.unique) var id: UUID
    var fileName: String
    /// Original file path the user dropped (for the UI; we keep our own copy at FileStore.imageURL).
    var originalPath: String
    var widthPx: Int
    var heightPx: Int
    var importedAt: Date
    /// Pass-15: per-image confidence cutoff. When non-nil, this overrides
    /// `AppState.confidence` for any filtering/counting/export decisions on
    /// this specific image. The user sets this by moving the slider in
    /// ResultsView. Nil = inherit the global `AppState.confidence`.
    /// Optional with a default so existing SwiftData rows decode unchanged.
    var confidenceOverride: Double? = nil
    /// One-to-one detection for this image (we re-run to replace).
    @Relationship(deleteRule: .cascade, inverse: \DetectionRecord.image)
    var detection: DetectionRecord?
    @Relationship(deleteRule: .cascade, inverse: \ROIRecord.image)
    var rois: [ROIRecord] = []
    var batch: BatchRecord?
    /// Pass-17: SHA-256 hash of the file contents (hex string), computed at import time
    /// off the main actor. Nil for images imported before Pass-17 — back-filled lazily
    /// when the user runs "Find Duplicates" or on next import. SwiftData auto-migrates
    /// optional new properties; existing rows load fine with fileHash == nil.
    var fileHash: String? = nil
    /// Pass-18 (Lane N): freeform notes attached to this image — donor / passage /
    /// observations that filenames can't carry. Edited from the Results sidebar's
    /// NotesPanel, surfaced as a small badge + tooltip in the Library grid, and
    /// matched by the Library search. Optional with a default so existing
    /// SwiftData rows decode unchanged (auto-migration friendly).
    var notes: String? = nil

    init(id: UUID = UUID(), fileName: String, originalPath: String,
         widthPx: Int, heightPx: Int) {
        self.id = id
        self.fileName = fileName
        self.originalPath = originalPath
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.importedAt = Date()
        self.fileHash = nil
    }

    /// Where our own copy lives. Extension is lowercased so we match the
    /// on-disk filename written at import time regardless of the user's casing.
    var storedURL: URL {
        let raw = (fileName as NSString).pathExtension
        let ext = raw.isEmpty ? "tif" : raw.lowercased()
        return FileStore.shared.imageURL(for: id, extension: ext)
    }
    /// ImageIO/AppKit-readable bitmap used by viewers and annotated exports.
    /// Native formats point at the source itself; vendor containers point at
    /// the lossless projected PNG created during import.
    var displayURL: URL {
        ImageLoader.isVendorExtension((fileName as NSString).pathExtension)
            ? FileStore.shared.displayImageURL(for: id)
            : storedURL
    }
    var thumbURL: URL { FileStore.shared.thumbURL(for: id) }
}

@Model
final class DetectionRecord {
    #Index<DetectionRecord>([\.reviewIndexVersion])
    var runSettingsData: Data? = nil
    var runSettings: AnalysisRunSettings? {
        get { runSettingsData.flatMap { try? JSONDecoder().decode(AnalysisRunSettings.self, from: $0) } }
        set { runSettingsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    @Attribute(.unique) var id: UUID
    var detectorId: String           // "cellpose-cp-cyto3", "yolo-yo-s", custom uuid — "mock" only in legacy records (pass-8 removed mock detection)
    var ranAt: Date
    /// Cell bytes of rows written before `StoredCellsRecord` existed (the
    /// store column is still `cellsData`). Empty once the row has been moved;
    /// read and write the cells through `cellsData`.
    @Attribute(originalName: "cellsData") var legacyCellsData: Data = Data()
    /// The stored cell array, in its own row: firing this record's fault
    /// loads every column of its row, so a blob kept here would come along
    /// with every read of a small field such as `cellCountSummary`.
    @Relationship(deleteRule: .cascade, inverse: \StoredCellsRecord.detection)
    var cellsStorage: StoredCellsRecord? = nil
    /// Minimum confidence across all detected cells — denormalised so the review-queue
    /// badge can run a SwiftData predicate instead of decoding every row's JSON.
    /// Defaults to 1.0 for empty detections (i.e. "no uncertain cells").
    var minConfidence: Double
    /// Cheap summaries/index migration marker. Existing rows receive the
    /// declaration defaults and are indexed in small, yielding chunks after
    /// launch; new detections are indexed at save time.
    var cellCountSummary: Int = -1
    /// Monotonic token for the encoded cell payload. Views and AppState use it
    /// to share a decoded cell snapshot without comparing or decoding the full
    /// JSON blob during every render.
    var cellsRevision: Int = 0
    var reviewPendingCount: Int = -1
    var reviewIndexVersion: Int = 0
    /// Per-image statistics as a JSON blob (C2/C3 pass-6).
    /// Keys: "focus_score" (Double, 0–1), "illumination_residual" (Double, ≥ 0),
    /// plus any C2 colony keys. Nil for legacy detections.
    var imageStatsData: Data?
    // MARK: Compact per-cell metrics (see CellMetrics.swift)
    /// `CellMetricsCodec` bytes for the cells in `cellsData` (diameters,
    /// confidence, centroid; no outlines), read by list and compare screens
    /// instead of the full payload. Every cell write below keeps them in sync;
    /// rows saved before they existed are filled in by
    /// `Repositories.backfillCellMetrics()`.
    var cellMetricsData: Data? = nil
    /// `CellMetricsCodec.version` of `cellMetricsData`; 0 = not written yet.
    var cellMetricsVersion: Int = 0
    @Relationship(deleteRule: .cascade, inverse: \CorrectionRecord.detection)
    var corrections: [CorrectionRecord] = []
    var image: ImageRecord?

    convenience init(detectorId: String, cells: [DetectedCell], imageStats: [String: Double] = [:]) {
        self.init(detectorId: detectorId, storage: Self.makeStorageSnapshot(cells), cells: cells,
                  imageStats: imageStats)
    }

    /// `storage` must be `makeStorageSnapshot(cells)`, normally made on a
    /// detached task, so creating the record encodes and compresses nothing.
    init(detectorId: String, storage: CellsStorageSnapshot, cells: [DetectedCell],
         imageStats: [String: Double] = [:]) {
        self.id = UUID()
        self.detectorId = detectorId
        self.ranAt = Date()
        self.minConfidence = storage.minimumConfidence
        self.cellCountSummary = storage.count
        self.cellsRevision = 0
        self.reviewPendingCount = cells.filter { $0.confidence < 0.65 }.count
        self.reviewIndexVersion = 0
        self.imageStatsData = imageStats.isEmpty ? nil : (try? JSONEncoder().encode(imageStats))
        storeCells(storage.data, contentHash: storage.contentHash)
        // No metrics for a payload that failed to encode: readers then see
        // the same (empty) cells as the payload.
        self.cellMetricsData = storage.data.isEmpty ? nil : (storage.cellMetrics ?? CellMetricsCodec.encode(cells))
        self.cellMetricsVersion = storage.data.isEmpty ? 0 : CellMetricsCodec.version
        DecodedCellCache.shared.insert(cells, for: id, revision: 0)
    }

    /// Stored `[CellPayload]`: compressed (`CellsBlobCodec`) or plain JSON;
    /// every decoder accepts both. Reads the separate row, or the inline
    /// bytes of a row the background upkeep has not moved yet. Setting it
    /// stores the bytes as given, with no content hash.
    var cellsData: Data {
        get { cellsStorage?.data ?? legacyCellsData }
        set { storeCells(newValue, contentHash: nil) }
    }

    /// SHA-256 of the plain JSON of `cellsData`, when known.
    var cellsContentHash: String? { cellsStorage?.contentHash }

    /// Writes the stored bytes into the separate row and empties the inline
    /// column, in the same change. Callers keep the summaries in step.
    func storeCells(_ stored: Data, contentHash: String?) {
        if let storage = cellsStorage {
            storage.data = stored
            storage.storageFormat = CellsBlobCodec.storageFormat(of: stored)
            storage.contentHash = contentHash
        } else {
            let storage = StoredCellsRecord(data: stored, contentHash: contentHash)
            // An uninserted record is inserted together with this one.
            modelContext?.insert(storage)
            cellsStorage = storage
        }
        if !legacyCellsData.isEmpty { legacyCellsData = Data() }
    }

    /// Decoded view of `imageStatsData`. Returns an empty dict when the blob is
    /// missing or unparseable (i.e. legacy detections), so callers never need
    /// to handle either failure mode. C2 and C3 write into the same namespace.
    var imageStats: [String: Double] {
        guard let d = imageStatsData else { return [:] }
        return (try? JSONDecoder().decode([String: Double].self, from: d)) ?? [:]
    }

    var cells: [DetectedCell] {
        get {
            if let cached = cachedCells { return cached }
            let decoded = Self.decodeCellsData(cellsData)
            cacheDecodedCells(decoded, revision: cellsRevision)
            return decoded
        }
        set {
            // Stores the payload, summaries and compact metrics together.
            applyStorageSnapshot(Self.makeStorageSnapshot(newValue))
            cacheDecodedCells(newValue, revision: cellsRevision)
        }
    }

    var summaryCellCount: Int {
        cellCountSummary >= 0 ? cellCountSummary : cells.count
    }

    struct CellsStorageSnapshot: Sendable {
        let data: Data
        let minimumConfidence: Double
        let count: Int
        /// SHA-256 of the plain JSON behind `data`; nil when unknown.
        var contentHash: String? = nil
        /// `CellMetricsCodec` bytes for the same cells. A snapshot built
        /// without them stores none; readers then use the payload until the
        /// backfill fills them in.
        var cellMetrics: Data? = nil
    }

    /// Encode, hash and compress the large cell array away from the
    /// MainActor. Manual edits only mutate the small in-memory overlay
    /// immediately; serialization no longer blocks pointer interaction or
    /// image navigation. `data` is empty when the cells cannot be encoded.
    nonisolated static func makeStorageSnapshot(_ cells: [DetectedCell]) -> CellsStorageSnapshot {
        let json = encodePlainCellsJSON(cells)
        let compressed = CellsBlobCodec.compress(json)
        // Kept only if it decompresses to the same bytes; plain JSON otherwise.
        let stored = (try? CellsBlobCodec.plainJSON(compressed)) == json ? compressed : json
        return CellsStorageSnapshot(
            data: stored,
            minimumConfidence: cells.map(\.confidence).min() ?? 1.0,
            count: cells.count,
            contentHash: json.isEmpty ? nil : CellsBlobCodec.sha256Hex(json),
            cellMetrics: CellMetricsCodec.encode(cells)
        )
    }

    /// Plain `[CellPayload]` JSON, the form content hashes are computed over.
    /// Empty when the cells cannot be encoded.
    nonisolated static func encodePlainCellsJSON(_ cells: [DetectedCell]) -> Data {
        (try? JSONEncoder().encode(cells.map(CellPayload.init))) ?? Data()
    }

    nonisolated static func decodeCellsData(_ data: Data) -> [DetectedCell] {
        (try? decodeCellsDataForReview(data)) ?? []
    }

    /// Repair and undo must distinguish an empty detection from unreadable
    /// measurements; otherwise they can silently replace data with an empty set.
    /// Accepts plain JSON and `CellsBlobCodec`-compressed blobs alike.
    nonisolated static func decodeCellsDataForReview(_ data: Data) throws -> [DetectedCell] {
        try JSONDecoder().decode([CellPayload].self, from: CellsBlobCodec.plainJSON(data)).map(\.cell)
    }

    /// Share an off-main decode with direct model consumers when it still
    /// represents the current payload. This avoids a second JSON decode after
    /// Results has already populated AppState's bounded cache.
    func cacheDecodedCells(_ cells: [DetectedCell], revision: Int) {
        guard revision == cellsRevision else { return }
        DecodedCellCache.shared.insert(cells, for: id, revision: revision)
    }

    var cachedCells: [DetectedCell]? {
        DecodedCellCache.shared.cells(for: id, revision: cellsRevision)
    }

    func applyStorageSnapshot(_ snapshot: CellsStorageSnapshot) {
        storeCells(snapshot.data, contentHash: snapshot.contentHash)
        minConfidence = snapshot.minimumConfidence
        cellCountSummary = snapshot.count
        storeCellMetrics(snapshot.data.isEmpty ? nil : snapshot.cellMetrics)
        cellsRevision &+= 1
        DecodedCellCache.shared.remove(id)
    }
}

/// One detection's stored cell array, split from `DetectionRecord` so that
/// reading a detection's small fields never loads it. Read and written only
/// through `DetectionRecord.cellsData` / `storeCells`.
///
/// The class name is the store's entity name and is chosen to sort after
/// every older entity: entity numbers follow name order, and a new entity
/// sorting earlier renumbers, and so rewrites, every row of the tables
/// after it when an existing library is upgraded.
@Model
final class StoredCellsRecord {
    @Attribute(.unique) var id: UUID
    var data: Data
    /// `CellsBlobCodec` format of `data`, so rows still stored as plain JSON
    /// can be found without reading them.
    var storageFormat: Int = 0
    /// SHA-256 (hex) of the plain JSON; nil until known. Lets a re-run save
    /// the previous mask as a version, de-duplicated, without decompressing.
    var contentHash: String? = nil
    var detection: DetectionRecord?

    init(data: Data, contentHash: String?) {
        self.id = UUID()
        self.data = data
        self.storageFormat = CellsBlobCodec.storageFormat(of: data)
        self.contentHash = contentHash
    }
}

/// A saved alternative segmentation for Mask Curator-style comparison.
///
/// Re-running a detector no longer destroys the previous mask. Variants are
/// materialized only when the user compares or uses one, so large libraries
/// pay no render-time cost. A version is saved from the detection's existing
/// JSON bytes as they are (no decode, no re-encode); background upkeep in
/// `Repositories.compactSegmentationVariants()` later compresses it with
/// `CellsBlobCodec` and fills in what was not known at save time.
@Model
final class SegmentationVariantRecord {
    #Index<SegmentationVariantRecord>([\.imageId])
    var measurementPxPerUm: Double? = nil
    var runSettingsData: Data? = nil
    var imageStatsData: Data? = nil
    var detectionRanAt: Date? = nil
    /// SHA-256 (hex) of the plain JSON cell array, used to avoid saving the
    /// same mask twice for an image. Nil on versions saved before this field
    /// existed until the background upkeep fills it in.
    var contentHash: String? = nil
    /// How `cellsData` is stored: 0 = plain JSON, 1 = compressed
    /// (`CellsBlobCodec`). Existing rows are plain JSON and start at 0.
    var storageFormat: Int = 0
    var runSettings: AnalysisRunSettings? {
        get { runSettingsData.flatMap { try? JSONDecoder().decode(AnalysisRunSettings.self, from: $0) } }
        set { runSettingsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    @Attribute(.unique) var id: UUID
    var imageId: UUID
    var detectorId: String
    var label: String
    var createdAt: Date
    /// Plain or compressed `[CellPayload]` JSON; see `storageFormat`.
    var cellsData: Data
    var cellCount: Int
    /// Mean cell confidence, or -1 while it has not been computed yet.
    var meanConfidence: Double
    var image: ImageRecord?

    init(image: ImageRecord, detectorId: String, label: String,
         cells: [DetectedCell]) {
        self.id = UUID()
        self.imageId = image.id
        self.detectorId = detectorId
        self.label = label
        self.createdAt = Date()
        let json = DetectionRecord.encodePlainCellsJSON(cells)
        self.cellsData = json
        self.cellCount = cells.count
        self.meanConfidence = Self.meanConfidence(of: cells)
        self.contentHash = CellsBlobCodec.sha256Hex(json)
        self.storageFormat = CellsBlobCodec.plainJSONFormat
        self.image = image
    }

    /// Keeps already-encoded bytes (plain or compressed JSON) exactly as
    /// given, so saving a version never decodes or re-encodes a cell array.
    /// Pass -1 for `meanConfidence` when it is not known yet.
    init(image: ImageRecord, detectorId: String, label: String,
         plainJSON: Data, cellCount: Int, meanConfidence: Double, contentHash: String?) {
        self.id = UUID()
        self.imageId = image.id
        self.detectorId = detectorId
        self.label = label
        self.createdAt = Date()
        self.cellsData = plainJSON
        self.cellCount = cellCount
        self.meanConfidence = meanConfidence
        self.contentHash = contentHash
        self.storageFormat = CellsBlobCodec.storageFormat(of: plainJSON)
        self.image = image
    }

    var cells: [DetectedCell] { DetectionRecord.decodeCellsData(cellsData) }

    nonisolated static func meanConfidence(of cells: [DetectedCell]) -> Double {
        cells.isEmpty ? 0 : cells.reduce(0) { $0 + $1.confidence } / Double(cells.count)
    }
}

/// Normalized, queryable row for one low-confidence cell.
///
/// Detections keep their complete cells as a compact JSON blob for fast image
/// loading. The Review screen previously had to decode every blob in the
/// library before it could show its first card. These lightweight rows make
/// badge counts a `fetchCount` and let the queue fetch one small page at a time.
@Model
final class ReviewCandidateRecord {
    #Index<ReviewCandidateRecord>([\.imageId], [\.detectionId], [\.sortKey], [\.triaged, \.confidence, \.sortKey])
    @Attribute(.unique) var id: UUID
    var cellId: UUID
    /// Stable tie-breaker for keyset paging when confidence scores are equal.
    /// Empty only for pre-upgrade rows; backfilled without decoding cells.
    var sortKey: String = ""
    var detectionId: UUID
    var imageId: UUID
    var confidence: Double
    var cx: Double
    var cy: Double
    var diameter: Double
    var diameterPx: Double
    var triaged: Bool
    var createdAt: Date
    var detection: DetectionRecord?
    var image: ImageRecord?

    init(cell: DetectedCell, detection: DetectionRecord, image: ImageRecord) {
        self.id = UUID()
        self.cellId = cell.id
        self.sortKey = ""
        self.detectionId = detection.id
        self.imageId = image.id
        self.confidence = cell.confidence
        self.cx = cell.cx
        self.cy = cell.cy
        self.diameter = cell.diameter
        self.diameterPx = cell.diameterPx
        self.triaged = false
        self.createdAt = detection.ranAt
        self.detection = detection
        self.image = image
        self.sortKey = self.id.uuidString
    }

    var fallbackCell: DetectedCell {
        DetectedCell(id: cellId, cx: cx, cy: cy, diameter: diameter,
                     diameterPx: diameterPx, confidence: confidence)
    }
}

/// User edits over a detection — accept/reject/add/move boxes.
@Model
final class CorrectionRecord {
    @Attribute(.unique) var id: UUID
    var kind: String        // "add" | "remove" | "move" | "resize" | "accept" | "manual"
    var cellId: UUID        // target cell (or new UUID for "add")
    var cx: Double
    var cy: Double
    var diameter: Double
    var createdAt: Date
    var detection: DetectionRecord?

    init(kind: String, cellId: UUID, cx: Double, cy: Double, diameter: Double) {
        self.id = UUID()
        self.kind = kind
        self.cellId = cellId
        self.cx = cx
        self.cy = cy
        self.diameter = diameter
        self.createdAt = Date()
    }
}

@Model
final class CalibrationPresetRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var pxPerUm: Double
    var isDefault: Bool

    init(name: String, pxPerUm: Double, isDefault: Bool = false) {
        self.id = UUID()
        self.name = name
        self.pxPerUm = pxPerUm
        self.isDefault = isDefault
    }
}

@Model
final class BinPresetRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var thresholdsData: Data

    init(name: String, thresholds: [Double]) {
        self.id = UUID()
        self.name = name
        self.thresholdsData = (try? JSONEncoder().encode(thresholds)) ?? Data()
    }

    var thresholds: [Double] {
        get { (try? JSONDecoder().decode([Double].self, from: thresholdsData)) ?? [] }
        set { thresholdsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

@Model
final class ModelVersionRecord {
    @Attribute(.unique) var id: UUID
    var modelId: String          // "cp-cyto3" or a user custom id
    var version: Int             // 1, 2, 3…
    var createdAt: Date
    var trainedOnImages: Int
    var trainedOnCorrections: Int
    var checkpointPath: String   // file inside FileStore.modelsDir
    /// Honest test-set metrics from the last training run (JSON).
    var metricsData: Data

    init(modelId: String, version: Int, trainedOnImages: Int,
         trainedOnCorrections: Int, checkpointPath: String, metrics: [String: Double]) {
        self.id = UUID()
        self.modelId = modelId
        self.version = version
        self.createdAt = Date()
        self.trainedOnImages = trainedOnImages
        self.trainedOnCorrections = trainedOnCorrections
        self.checkpointPath = checkpointPath
        self.metricsData = (try? JSONEncoder().encode(metrics)) ?? Data()
    }

    var metrics: [String: Double] {
        (try? JSONDecoder().decode([String: Double].self, from: metricsData)) ?? [:]
    }
}

/// JSON payload for a DetectedCell — keeps storage simple.
private struct CellPayload: Codable, Sendable {
    let id: UUID
    let cx: Double
    let cy: Double
    let diameter: Double
    let diameterPx: Double
    let confidence: Double
    // Per-cell measurements (optional so existing stored data decodes without them).
    let areaMicrons2: Double?
    let perimeterMicrons: Double?
    let circularity: Double?
    let eccentricity: Double?
    let meanIntensity: Double?
    let integratedDensity: Double?
    // Pass-6 quality flags (all optional/defaulted for backward-compatible decoding).
    let centroidUmX: Double?
    let centroidUmY: Double?
    let aspectRatio: Double?
    let solidity: Double?
    let edgeTouching: Bool?
    let likelyClump: Bool?
    let likelyDebris: Bool?
    let sizeClass: String?
    let isManual: Bool?
    /// Pass-14: per-cell polygon contour as flattened [x0, y0, x1, y1, …] for
    /// JSON efficiency. Optional — payloads written before this change decode
    /// with `contourFlat == nil`, rendering via the existing bbox/circle path.
    let contourFlat: [Double]?
    /// Per-channel intensities for multi-channel sources. Optional and stored
    /// as-is (ChannelIntensity is Codable), exactly like the other optional
    /// per-cell measurements above: rows written before this change decode
    /// with `channelIntensities == nil` and behave as single-channel.
    let channelIntensities: [ChannelIntensity]?
    // isMock is intentionally NOT stored here; legacy payloads containing "isMock"
    // are silently ignored by Codable (unknown keys on struct → no-op).

    nonisolated init(_ c: DetectedCell) {
        self.id = c.id
        self.cx = c.cx
        self.cy = c.cy
        self.diameter = c.diameter
        self.diameterPx = c.diameterPx
        self.confidence = c.confidence
        self.areaMicrons2 = c.areaMicrons2
        self.perimeterMicrons = c.perimeterMicrons
        self.circularity = c.circularity
        self.eccentricity = c.eccentricity
        self.meanIntensity = c.meanIntensity
        self.integratedDensity = c.integratedDensity
        self.centroidUmX = c.centroidUmX
        self.centroidUmY = c.centroidUmY
        self.aspectRatio = c.aspectRatio
        self.solidity = c.solidity
        self.edgeTouching = c.edgeTouching
        self.likelyClump = c.likelyClump
        self.likelyDebris = c.likelyDebris
        self.sizeClass = c.sizeClass
        self.isManual = c.isManual
        // Normalise empty → nil so a multi-channel-less payload never stores an
        // empty array that would read back as "has channels, but none".
        self.channelIntensities = (c.channelIntensities?.isEmpty == false)
            ? c.channelIntensities : nil
        if let contour = c.contourPx, !contour.isEmpty {
            var flat: [Double] = []
            flat.reserveCapacity(contour.count * 2)
            for pt in contour {
                flat.append(Double(pt.x))
                flat.append(Double(pt.y))
            }
            self.contourFlat = flat
        } else {
            self.contourFlat = nil
        }
    }

    nonisolated var cell: DetectedCell {
        var contour: [CGPoint]? = nil
        if let flat = contourFlat, flat.count >= 4, flat.count % 2 == 0 {
            var pts: [CGPoint] = []
            pts.reserveCapacity(flat.count / 2)
            for i in stride(from: 0, to: flat.count, by: 2) {
                pts.append(CGPoint(x: flat[i], y: flat[i + 1]))
            }
            contour = pts
        }
        return DetectedCell(id: id, cx: cx, cy: cy, diameter: diameter,
                            diameterPx: diameterPx, confidence: confidence,
                            areaMicrons2: areaMicrons2, perimeterMicrons: perimeterMicrons,
                            circularity: circularity, eccentricity: eccentricity,
                            meanIntensity: meanIntensity, integratedDensity: integratedDensity,
                            centroidUmX: centroidUmX, centroidUmY: centroidUmY,
                            aspectRatio: aspectRatio, solidity: solidity,
                            edgeTouching: edgeTouching ?? false,
                            likelyClump: likelyClump ?? false,
                            likelyDebris: likelyDebris ?? false,
                            sizeClass: sizeClass ?? "",
                            isManual: isManual ?? false,
                            contourPx: contour,
                            channelIntensities: (channelIntensities?.isEmpty == false)
                                ? channelIntensities : nil)
    }
}

/// Region-of-interest drawn on top of an image. Used to include or exclude cells
/// from counts/stats. Stored in source-image pixel space.
@Model
final class ROIRecord {
    #Index<ROIRecord>([\.imageId])
    @Attribute(.unique) var id: UUID
    /// FK to the owning ImageRecord (denormalised; relationship lives on `image`).
    var imageId: UUID
    /// "include" | "exclude"
    var kind: String
    /// "rect" | "ellipse"
    var shape: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var createdAt: Date
    var name: String?
    var image: ImageRecord?

    init(id: UUID = UUID(), imageId: UUID, kind: String, shape: String,
         x: Double, y: Double, width: Double, height: Double,
         name: String? = nil) {
        self.id = id
        self.imageId = imageId
        self.kind = kind
        self.shape = shape
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.createdAt = Date()
        self.name = name
    }
}

// MARK: — Inhibitor / experimental condition tag (pass 6)

/// A reusable label applied to whole batches — e.g. "Control", "F+X", "Y-27632".
/// Used for the Compare view to pool batches per-condition and contrast
/// distributions across treatments.
@Model
final class ConditionRecord {
    @Attribute(.unique) var id: UUID
    var name: String       // "Control", "F+X", "Y-27632"
    var color: String      // hex like "#4db3a8" — drives plot color in Compare
    var createdAt: Date
    var order: Int         // for stable ordering in dropdowns / chip-rows

    init(id: UUID = UUID(), name: String, color: String, order: Int) {
        self.id = id
        self.name = name
        self.color = color
        self.createdAt = Date()
        self.order = order
    }
}

// MARK: — Ground-truth annotations (pass 17, Lane B)

/// A user-placed point on an image that records "I think there is a cell here."
/// Used as ground truth for F1 / precision / recall scoring against a
/// `DetectionRecord` over the same image.
///
/// Stored in SOURCE-IMAGE PIXEL space, matching `DetectedCell.cx, cy` and
/// `ROIRecord.x, y` — so the matcher in `AnnotationMatcher` can compare
/// distances directly without coordinate conversion.
///
/// We deliberately store `imageId` instead of a SwiftData relationship so this
/// model doesn't pile a third inverse-relationship onto `ImageRecord`
/// alongside Lane A's `fileHash` work (which lives there now). Repos do the
/// imageId → ImageRecord lookup in code.
@Model
final class GroundTruthAnnotation {
    #Index<GroundTruthAnnotation>([\.imageId])
    @Attribute(.unique) var id: UUID
    /// Back-reference to the `ImageRecord` this annotation belongs to.
    var imageId: UUID
    /// Pixel coords in source image space.
    var cx: Double
    var cy: Double
    /// Optional cell diameter in µm — most users will just click centers and
    /// leave this nil. When populated, downstream tools may use it as a hint.
    var diameter: Double?
    var createdAt: Date
    /// Optional free-form label, e.g. "obvious cell", "in doubt".
    var note: String?

    init(id: UUID = UUID(),
         imageId: UUID,
         cx: Double,
         cy: Double,
         diameter: Double? = nil,
         note: String? = nil) {
        self.id = id
        self.imageId = imageId
        self.cx = cx
        self.cy = cy
        self.diameter = diameter
        self.note = note
        self.createdAt = Date()
    }
}
