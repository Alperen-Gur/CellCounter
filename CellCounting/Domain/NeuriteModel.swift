import Foundation

// MARK: — Neurite outgrowth domain model
//
// Mirrors the JSON emitted by `python/neurite_outgrowth.py` (built on
// `python/_neurite.py`'s `analyze()` — read that file's module docstring
// for the full algorithm description: skeletonize, punch out the soma
// footprint, attribute the remaining skeleton's connected components to the
// nearest soma by majority vote).
//
// Same snake-case-verbatim decoding idiom as `TrackingModel.swift` /
// `Detection/SidecarSchema.swift` — see that file's header comment for why.
// Wiring a live `NeuritePayload` into the app is out of scope for these
// owned files — see the splice-point doc comment at the top of
// NeuritePanel.swift.

/// Per-cell neurite measurements — one entry in `NeuritePayload.cells`.
struct NeuriteCellStat: Decodable, Hashable, Identifiable {
    /// The soma's id: either its integer label (from a label-mask soma
    /// input, stringified) or the caller-supplied "id" (from a centroid-list
    /// soma input). Always a String on the wire so decoding doesn't depend
    /// on which soma input shape produced a given result.
    let soma_id: String
    let total_length_um: Double
    let n_primary_processes: Int
    let n_branch_points: Int
    /// Raw attributed skeleton pixel count. Mostly a QC/debugging number —
    /// `total_length_um` (an edge-length sum, not a pixel count) is the
    /// geometrically-correct measurement to show/report.
    let skeleton_px_count: Int

    var id: String { soma_id }
}

/// Echoes the resolved calibration/tuning values the Python side actually used.
struct NeuriteParams: Decodable, Hashable {
    let px_per_um: Double
    /// Only meaningful when the soma input was a centroid list rather than
    /// a label mask (no real soma footprint to measure in that case) — see
    /// `_neurite.py`'s module docstring.
    let soma_radius_um: Double
}

/// Top-level payload decoded directly from `neurite_outgrowth.py`'s stdout.
struct NeuritePayload: Decodable, Hashable {
    let n_cells: Int
    let cells: [NeuriteCellStat]
    /// Mean of `cells[*].total_length_um` — 0 when `cells` is empty.
    let mean_neurite_length_um: Double
    /// Whole-image skeleton length, regardless of attribution — a sanity
    /// total that should roughly equal the sum of every cell's length plus
    /// `unattributed_length_um`.
    let total_skeleton_length_um: Double
    /// Skeleton length that couldn't be attributed to any soma (e.g. no
    /// soma was provided at all, or an orphan fragment with no nearby soma).
    let unattributed_length_um: Double
    /// ALWAYS non-empty. Overlapping neurites from different cells cannot
    /// be reliably separated by this algorithm (nearest-soma attribution is
    /// a Voronoi partition, not a true segmentation) — this field states
    /// that in every single result, not just ones where it was detected,
    /// and `NeuritePanel` surfaces it unconditionally next to the per-cell
    /// table. See `_neurite.py`'s module docstring for the full explanation.
    let caveat: String
    /// Non-nil when there was nothing to measure, or no soma was given so
    /// only whole-image totals could be reported (`cells` is `[]` in that
    /// latter case, but `total_skeleton_length_um` is still populated).
    let message: String?
    let params: NeuriteParams
}
