import Foundation

// MARK: — Area / region assay domain model
//
// Mirrors the JSON shapes returned by `CellCounting/python/_assays_area.py`
// (via the `area_assays_detect.py` CLI wrapper — see
// `Services/AreaAssaysRunner.swift`) verbatim, key-for-key, the same way
// `Detection/SidecarSchema.swift`'s `SidecarCell` mirrors the cell-detection
// sidecars' JSON. Property names stay snake_case to match that established
// convention (grep `SidecarCell`) rather than mixing snake_case JSON keys
// with camelCase Swift names via `CodingKeys` — one fewer place for the two
// sides to drift apart.
//
// These three assays (confluence, scratch-wound, spheroid/organoid) measure
// AREA and REGIONS, not per-cell properties, and run independently of the
// per-cell detection/measurement pipeline (`DetectedCell` / `SidecarCell` /
// `ImageRecord.detection`) — a plain image or an existing mask in, a flat
// results dict out. Nothing here references `DetectedCell` or any
// detection-family type.

// MARK: - 1) Confluence / % area coverage

/// Result of `_assays_area.confluence()`. `mode` is `"mask"` (computed from
/// an existing segmentation mask) or `"threshold"` (computed directly from
/// a raw image, no segmentation involved).
struct ConfluenceResult: Decodable, Hashable {
    let ok: Bool
    let message: String
    let mode: String
    let width_px: Int
    let height_px: Int
    let coverage_pct: Double
    let covered_area_um2: Double
    let uncovered_area_um2: Double
    let total_area_um2: Double
    /// `""` in mask mode; `"otsu"` or `"fixed"` in threshold mode.
    let threshold_method: String
    /// `nil` in mask mode.
    let threshold_value: Double?
}

// MARK: - 2) Scratch / wound-healing assay

/// Result of `_assays_area.scratch_wound()` for ONE image.
struct ScratchWoundFrameResult: Decodable, Hashable {
    let ok: Bool
    let message: String
    let width_px: Int
    let height_px: Int
    let gap_area_um2: Double
    let gap_fraction_pct: Double
    let total_area_um2: Double
    /// `[x0, y0, x1, y1]` in source-image pixel coords, or `nil` when no
    /// wound was detected (fully closed / never opened).
    let wound_bbox_px: [Int]?
}

/// One row of a `_assays_area.scratch_wound_series()` result — one
/// timepoint's measurement plus its % closure relative to frame 0.
struct ScratchWoundTimepoint: Decodable, Hashable, Identifiable {
    let frame: Int
    /// `nil` when the caller didn't supply `timepoints_hours`.
    let time_hours: Double?
    let ok: Bool
    let message: String
    let gap_area_um2: Double
    let gap_fraction_pct: Double
    let pct_closure: Double

    var id: Int { frame }
}

/// Result of `_assays_area.scratch_wound_series()` — an ordered time
/// series' per-timepoint table plus the overall closure summary.
struct ScratchWoundSeriesResult: Decodable, Hashable {
    let ok: Bool
    let message: String
    let timepoints: [ScratchWoundTimepoint]
    let initial_gap_area_um2: Double
    let final_gap_area_um2: Double
    let total_pct_closure: Double
    /// µm² / hour, positive = gap shrinking. `nil` when the caller didn't
    /// supply `timepoints_hours` (needs a real time axis to rate against)
    /// or the series has fewer than 2 timepoints.
    let closure_rate_um2_per_hr: Double?
}

// MARK: - 3) Spheroid / organoid size

/// One detected object from `_assays_area.spheroids()`.
struct SpheroidObject: Decodable, Hashable, Identifiable {
    let label: Int
    let area_um2: Double
    let equivalent_diameter_um: Double
    let perimeter_um: Double
    /// 4·π·area / perimeter², clamped to [0, 1]. 1.0 = perfect circle.
    let circularity: Double
    let major_axis_um: Double
    let minor_axis_um: Double
    let centroid_x_px: Double
    let centroid_y_px: Double
    /// `[x0, y0, x1, y1]` in source-image pixel coords.
    let bbox_px: [Int]

    var id: Int { label }
}

/// Result of `_assays_area.spheroids()` — every qualifying object in the
/// image, sorted by area descending (largest first).
struct SpheroidResult: Decodable, Hashable {
    let ok: Bool
    let message: String
    let width_px: Int
    let height_px: Int
    let count: Int
    let objects: [SpheroidObject]
    let threshold_method: String
}
