import Foundation

// MARK: — Puncta / foci assay domain model
//
// Mirrors the JSON payload `puncta_detect.py` prints to stdout (which is
// `_assays_puncta.compute()`'s result dict, plus `width`/`height`). See
// `CellCounting/python/_assays_puncta.py` for the producing side — this
// file only reads that shape by convention; it does not (and cannot, being
// Swift) import it.
//
// Not persisted anywhere yet — there is no `DetectionRecord`-style store for
// puncta results in this pass (adding one would mean editing
// `Persistence/Records.swift`, which this pass does not own). These types
// exist so `Views/Results/PunctaPanel.swift` has something concrete to
// render; a future pass can decode a live sidecar's stdout straight into
// `PunctaResult` with zero changes here.

/// A single detected sub-cellular spot (puncta/focus) — e.g. a γH2AX
/// DNA-damage focus, a FISH probe, or a stress granule. One entry per
/// `_assays_puncta.compute()` `spots[]` row.
struct PunctaSpot: Identifiable, Codable, Hashable {
    let id: String
    /// Center in source-image pixel coordinates.
    let xPx: Double
    let yPx: Double
    /// Center in micrometers (xPx / pxPerUm, yPx / pxPerUm).
    let xUm: Double
    let yUm: Double
    /// Gaussian sigma of the fitted blob, in pixels.
    let sigmaPx: Double
    let radiusUm: Double
    let diameterUm: Double
    /// Intensity at the spot's center pixel, in the source channel's own
    /// (unnormalized) units — see `_assays_puncta._normalize_channel`.
    let peakIntensity: Double
    /// Mean intensity over the spot's disk, same units as `peakIntensity`.
    let meanIntensity: Double
    /// The id of the cell this spot falls inside, or nil when it couldn't be
    /// assigned (outside every known cell, or no cell source was supplied
    /// to the detector at all).
    let cellLabel: String?

    enum CodingKeys: String, CodingKey {
        case id
        case xPx = "x_px", yPx = "y_px"
        case xUm = "x_um", yUm = "y_um"
        case sigmaPx = "sigma_px"
        case radiusUm = "radius_um"
        case diameterUm = "diameter_um"
        case peakIntensity = "peak_intensity"
        case meanIntensity = "mean_intensity"
        case cellLabel = "cell_label"
    }
}

/// Per-cell spot count + mean intensity — one entry per KNOWN cell,
/// including cells with zero spots. One entry per
/// `_assays_puncta.compute()` `cells[]` row.
struct PunctaCellCount: Identifiable, Codable, Hashable {
    var id: String { cellLabel }
    let cellLabel: String
    let spotCount: Int
    /// Mean of `PunctaSpot.meanIntensity` across this cell's spots. Nil for
    /// zero-spot cells.
    let meanSpotIntensity: Double?

    enum CodingKeys: String, CodingKey {
        case cellLabel = "cell_label"
        case spotCount = "spot_count"
        case meanSpotIntensity = "mean_spot_intensity"
    }
}

/// Image-level puncta summary. Mirrors `_assays_puncta.compute()`'s
/// `summary` dict verbatim.
struct PunctaSummary: Codable, Hashable {
    let totalSpots: Int
    let nCells: Int
    let nAssignedSpots: Int
    let nUnassignedSpots: Int
    /// Nil only when `nCells == 0` (no cells to average over).
    let meanSpotsPerCell: Double?
    let medianSpotsPerCell: Double?
    /// Echoes the per-cell spot count threshold used for `pctCellsAboveThreshold`.
    let focusCountThreshold: Double
    let nCellsAboveThreshold: Int
    let pctCellsAboveThreshold: Double?

    enum CodingKeys: String, CodingKey {
        case totalSpots = "total_spots"
        case nCells = "n_cells"
        case nAssignedSpots = "n_assigned_spots"
        case nUnassignedSpots = "n_unassigned_spots"
        case meanSpotsPerCell = "mean_spots_per_cell"
        case medianSpotsPerCell = "median_spots_per_cell"
        case focusCountThreshold = "focus_count_threshold"
        case nCellsAboveThreshold = "n_cells_above_threshold"
        case pctCellsAboveThreshold = "pct_cells_above_threshold"
    }
}

/// Full puncta-assay result for one image. Mirrors the `puncta_detect.py`
/// stdout payload. `params_used` (present on the wire, for debugging/logs)
/// is intentionally not modeled here — unknown JSON keys decode as a no-op,
/// matching the rest of this codebase's Codable conventions (see
/// `Persistence/Records.swift`'s `CellPayload`).
struct PunctaResult: Codable, Hashable {
    let spots: [PunctaSpot]
    let cells: [PunctaCellCount]
    let summary: PunctaSummary?
    /// Set whenever the result is degraded — no cell source, zero cells,
    /// zero spots detected, or an unexpected failure. Non-nil doesn't
    /// necessarily mean "no data" (e.g. spots may still be populated even
    /// when cells/summary reflect "no cell source").
    let message: String?
    let width: Int
    let height: Int

    enum CodingKeys: String, CodingKey {
        case spots, cells, summary, message, width, height
    }
}

/// User-settable puncta-detection parameters — mirrors
/// `_assays_puncta.DEFAULT_PARAMS`. Purely local UI state in this pass (see
/// `PunctaPanel`'s splice-instructions comment for the persistence seam).
struct PunctaParams: Codable, Hashable {
    enum Method: String, Codable, CaseIterable, Identifiable {
        case log, dog
        var id: String { rawValue }
        var label: String {
            switch self {
            case .log: return "Laplacian of Gaussian"
            case .dog: return "Difference of Gaussian"
            }
        }
    }

    var method: Method = .log
    var minDiameterUm: Double = 0.3
    var maxDiameterUm: Double = 3.0
    /// Applied to the blob detector's normalized-to-[0,1] copy of the channel.
    var threshold: Double = 0.10
    var overlap: Double = 0.5
    /// Per-cell spot count at/above which a cell counts toward the
    /// "% positive / high-foci" summary metric.
    var focusCountThreshold: Int = 5
    /// Index into the current image's channel stack to detect spots in.
    var channelIndex: Int = 0
}
