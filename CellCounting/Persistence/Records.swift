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
    }

    var thresholds: [Double] {
        get { (try? JSONDecoder().decode([Double].self, from: thresholdsData)) ?? [20, 30] }
        set { thresholdsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var totalCells: Int { images.reduce(0) { $0 + ($1.detection?.cells.count ?? 0) } }
}

@Model
final class ImageRecord {
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
    var thumbURL: URL { FileStore.shared.thumbURL(for: id) }
}

@Model
final class DetectionRecord {
    @Attribute(.unique) var id: UUID
    var detectorId: String           // "cellpose-cp-cyto3", "yolo-yo-s", custom uuid — "mock" only in legacy records (pass-8 removed mock detection)
    var ranAt: Date
    /// Encoded `[CellPayload]` (see below).
    var cellsData: Data
    /// Minimum confidence across all detected cells — denormalised so the review-queue
    /// badge can run a SwiftData predicate instead of decoding every row's JSON.
    /// Defaults to 1.0 for empty detections (i.e. "no uncertain cells").
    var minConfidence: Double
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
        self.imageStatsData = imageStats.isEmpty ? nil : (try? JSONEncoder().encode(imageStats))
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
            ((try? JSONDecoder().decode([CellPayload].self, from: cellsData)) ?? [])
                .map { $0.cell }
        }
        set {
            let payload = newValue.map(CellPayload.init)
            cellsData = (try? JSONEncoder().encode(payload)) ?? Data()
            minConfidence = newValue.map { $0.confidence }.min() ?? 1.0
        }
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
private struct CellPayload: Codable {
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
    // isMock is intentionally NOT stored here; legacy payloads containing "isMock"
    // are silently ignored by Codable (unknown keys on struct → no-op).

    init(_ c: DetectedCell) {
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

    var cell: DetectedCell {
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
                            contourPx: contour)
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
