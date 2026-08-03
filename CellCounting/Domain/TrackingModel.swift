import Foundation
import CoreGraphics

// MARK: — Cell tracking / migration domain model
//
// Mirrors the JSON emitted by `python/track_cells.py` (built on
// `python/_tracking.py`'s `track()` — read that file's module docstring for
// the full algorithm description: consecutive-frame nearest-neighbour
// linking via `scipy.optimize.linear_sum_assignment`, gated by a
// user-settable `max_displacement_um`).
//
// Field names are snake_case, matching the JSON verbatim — the same idiom
// `SidecarCell` / `SidecarPayload` use in `Detection/SidecarSchema.swift`
// (plain `JSONDecoder()`, no `.convertFromSnakeCase`, no explicit
// `CodingKeys`), so a future integration pass can decode a `track_cells.py`
// stdout blob exactly the way every other sidecar payload in this app is
// decoded today:
//
//     let payload = try JSONDecoder().decode(TrackingPayload.self, from: stdout)
//
// This file is a plain, dependency-free domain model — no SwiftData, no
// AppState — so `TrackingPanel` (Views/Results/TrackingPanel.swift) can be
// constructed and inspected in isolation. Wiring a live `TrackingPayload`
// into the app (running `track_cells.py` from a SidecarProcessRunner,
// persisting a result, and splicing `TrackingPanel` into
// `ResultsSidebar.body`) is out of scope for these owned files — see the
// splice-point doc comment at the top of TrackingPanel.swift.

/// One recorded position of a tracked cell, in both source-image pixel
/// space and calibrated micrometres.
struct TrackPoint: Decodable, Hashable {
    let frame: Int
    let x_px: Double
    let y_px: Double
    let x_um: Double
    let y_um: Double
    /// Echoes the "id" field from the input detection at this frame, if the
    /// caller supplied one (e.g. a `DetectedCell.id.uuidString`). Nil when
    /// the input point didn't carry an id.
    let source_id: String?

    /// Convenience for drawing: the pixel-space position as a CGPoint.
    var pointPx: CGPoint { CGPoint(x: x_px, y: y_px) }
}

/// A single linked cell trajectory across an ordered image series —
/// one entry in `TrackingPayload.tracks`.
struct CellTrack: Decodable, Hashable, Identifiable {
    let track_id: Int
    let start_frame: Int
    let end_frame: Int
    /// `end_frame - start_frame`. Zero for a track that was never linked
    /// across any frame gap (a single observation with no continuation).
    let duration_frames: Int
    let duration_min: Double
    let total_path_length_um: Double
    let net_displacement_um: Double
    let mean_speed_um_per_min: Double
    /// Net displacement / total path length, in [0, 1]. 1.0 = perfectly
    /// straight motion; near 0 = meandering with little net progress.
    let directionality_ratio: Double
    let points: [TrackPoint]

    var id: Int { track_id }

    /// The full path in source-image pixel space, in frame order — for
    /// drawing a polyline on the viewer canvas (see `TrackPathsPreview` in
    /// TrackingPanel.swift for a self-contained renderer of this).
    var pathPx: [CGPoint] { points.map(\.pointPx) }
}

/// Per-image-series aggregate.
///
/// `mean_speed_um_per_min` / `mean_directionality_ratio` /
/// `mean_track_duration_min` are averaged only over tracks with
/// `duration_frames >= 1` (`n_tracks_with_motion` of them) — a track that
/// was observed in exactly one frame and never linked has no defined
/// velocity, and folding its speed=0 into the mean would bias the
/// series-level average for reasons unrelated to how fast anything actually
/// moved. `n_tracks` still counts every track, including zero-duration
/// ones, so nothing is hidden from the total.
struct TrackingSeriesSummary: Decodable, Hashable {
    let n_tracks: Int
    let n_tracks_with_motion: Int
    let mean_speed_um_per_min: Double
    let mean_directionality_ratio: Double
    let mean_track_duration_min: Double
}

/// Echoes the resolved calibration/tuning values the Python side actually
/// used (after clamping any bad/missing input to a default) — lets the UI
/// show exactly what parameters produced a given result.
struct TrackingParams: Decodable, Hashable {
    let px_per_um: Double
    let frame_interval_min: Double
    let max_displacement_um: Double
}

/// Top-level payload decoded directly from `track_cells.py`'s stdout.
struct TrackingPayload: Decodable, Hashable {
    let n_frames: Int
    let tracks: [CellTrack]
    let summary: TrackingSeriesSummary
    let params: TrackingParams
    /// Non-nil when tracking couldn't run meaningfully (e.g. a single-frame
    /// series, or an internal failure) — `tracks` is always `[]` whenever
    /// this is non-nil. `TrackingPanel` always surfaces this to the user
    /// instead of silently rendering an empty panel.
    let message: String?
}
