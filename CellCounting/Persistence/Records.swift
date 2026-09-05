import Foundation
import SwiftData

@Model
final class BatchRecord {
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
    var runSettingsData: Data? = nil
    var runSettings: AnalysisRunSettings? {
        get { runSettingsData.flatMap { try? JSONDecoder().decode(AnalysisRunSettings.self, from: $0) } }
        set { runSettingsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    @Attribute(.unique) var id: UUID
    var detectorId: String           // "cellpose-cp-cyto3", "yolo-yo-s", custom uuid — "mock" only in legacy records (pass-8 removed mock detection)
    var ranAt: Date
    /// Encoded `[CellPayload]` (see below).
    var cellsData: Data
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
    /// Process-local decoded snapshot. SwiftData persists the compact JSON,
    /// while every consumer in the current process shares this copy until
    /// `cellsRevision` changes. This turns repeated sidebar/export/stat reads
    /// from O(payload bytes) JSON work into O(1) copy-on-write array access.
    @Transient private var decodedCellsCache: [DetectedCell]? = nil
    @Transient private var decodedCellsCacheRevision: Int = -1
    /// Per-image statistics as a JSON blob (C2/C3 pass-6).
    /// Keys: "focus_score" (Double, 0–1), "illumination_residual" (Double, ≥ 0),
    /// plus any C2 colony keys. Nil for legacy detections.
    var imageStatsData: Data?
    @Relationship(deleteRule: .cascade, inverse: \CorrectionRecord.detection)
    var corrections: [CorrectionRecord] = []
    var image: ImageRecord?

    init(detectorId: String, cells: [DetectedCell], imageStats: [String: Double] = [:]) {
        self.id = UUID()
        self.detectorId = detectorId
        self.ranAt = Date()
        let payload = cells.map(CellPayload.init)
        self.cellsData = (try? JSONEncoder().encode(payload)) ?? Data()
        self.minConfidence = cells.map { $0.confidence }.min() ?? 1.0
        self.cellCountSummary = cells.count
        self.cellsRevision = 0
        self.reviewPendingCount = cells.filter { $0.confidence < 0.65 }.count
        self.reviewIndexVersion = 0
        self.imageStatsData = imageStats.isEmpty ? nil : (try? JSONEncoder().encode(imageStats))
        self.decodedCellsCache = cells
        self.decodedCellsCacheRevision = 0
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
            if decodedCellsCacheRevision == cellsRevision,
               let decodedCellsCache {
                return decodedCellsCache
            }
            let decoded = Self.decodeCellsData(cellsData)
            decodedCellsCache = decoded
            decodedCellsCacheRevision = cellsRevision
            return decoded
        }
        set {
            let payload = newValue.map(CellPayload.init)
            cellsData = (try? JSONEncoder().encode(payload)) ?? Data()
            minConfidence = newValue.map { $0.confidence }.min() ?? 1.0
            cellCountSummary = newValue.count
            cellsRevision &+= 1
            decodedCellsCache = newValue
            decodedCellsCacheRevision = cellsRevision
        }
    }

    var summaryCellCount: Int {
        cellCountSummary >= 0 ? cellCountSummary : cells.count
    }

    struct CellsStorageSnapshot: Sendable {
        let data: Data
        let minimumConfidence: Double
        let count: Int
    }

    /// Encode the large cell array away from the MainActor. Manual edits only
    /// mutate the small in-memory overlay immediately; JSON serialization no
    /// longer blocks pointer interaction or image navigation.
    nonisolated static func makeStorageSnapshot(_ cells: [DetectedCell]) -> CellsStorageSnapshot {
        let payload = cells.map(CellPayload.init)
        return CellsStorageSnapshot(
            data: (try? JSONEncoder().encode(payload)) ?? Data(),
            minimumConfidence: cells.map(\.confidence).min() ?? 1.0,
            count: cells.count
        )
    }

    nonisolated static func decodeCellsData(_ data: Data) -> [DetectedCell] {
        ((try? JSONDecoder().decode([CellPayload].self, from: data)) ?? [])
            .map(\.cell)
    }

    /// Share an off-main decode with direct model consumers when it still
    /// represents the current payload. This avoids a second JSON decode after
    /// Results has already populated AppState's bounded cache.
    func cacheDecodedCells(_ cells: [DetectedCell], revision: Int) {
        guard revision == cellsRevision else { return }
        decodedCellsCache = cells
        decodedCellsCacheRevision = revision
    }

    func applyStorageSnapshot(_ snapshot: CellsStorageSnapshot) {
        cellsData = snapshot.data
        minConfidence = snapshot.minimumConfidence
        cellCountSummary = snapshot.count
        cellsRevision &+= 1
        decodedCellsCache = nil
        decodedCellsCacheRevision = -1
    }
}

/// A saved alternative segmentation for Mask Curator-style comparison.
///
/// Re-running a detector no longer destroys the previous mask. Variants are
/// compact JSON snapshots and are materialized only when the user opens the
/// curator or chooses one, so large libraries pay no render-time cost.
@Model
final class SegmentationVariantRecord {
    var measurementPxPerUm: Double? = nil
    var runSettingsData: Data? = nil
    var imageStatsData: Data? = nil
    var detectionRanAt: Date? = nil
    var runSettings: AnalysisRunSettings? {
        get { runSettingsData.flatMap { try? JSONDecoder().decode(AnalysisRunSettings.self, from: $0) } }
        set { runSettingsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    @Attribute(.unique) var id: UUID
    var imageId: UUID
    var detectorId: String
    var label: String
    var createdAt: Date
    var cellsData: Data
    var cellCount: Int
    var meanConfidence: Double
    var image: ImageRecord?

    init(image: ImageRecord, detectorId: String, label: String,
         cells: [DetectedCell]) {
        self.id = UUID()
        self.imageId = image.id
        self.detectorId = detectorId
        self.label = label
        self.createdAt = Date()
        let snapshot = DetectionRecord.makeStorageSnapshot(cells)
        self.cellsData = snapshot.data
        self.cellCount = snapshot.count
        self.meanConfidence = cells.isEmpty
            ? 0
            : cells.reduce(0) { $0 + $1.confidence } / Double(cells.count)
        self.image = image
    }

    var cells: [DetectedCell] { DetectionRecord.decodeCellsData(cellsData) }
}

/// Normalized, queryable row for one low-confidence cell.
///
/// Detections keep their complete cells as a compact JSON blob for fast image
/// loading. The Review screen previously had to decode every blob in the
/// library before it could show its first card. These lightweight rows make
/// badge counts a `fetchCount` and let the queue fetch one small page at a time.
@Model
final class ReviewCandidateRecord {
    @Attribute(.unique) var id: UUID
    var cellId: UUID
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
