import Foundation

// MARK: — Shared sidecar wire types (all four detection families)

/// Output envelope written by every Python detection sidecar.
/// Snake-case keys match the JSON from the Python scripts verbatim.
struct SidecarPayload: Decodable {
    let width: Int
    let height: Int
    let cells: [SidecarCell]
    /// Per-image stats blob (C2 colony + C3 QC). Optional for backward compat.
    let image_stats: [String: Double]?
}

/// Per-cell JSON produced by every detection script.
struct SidecarCell: Decodable {
    let id: String
    let cx: Double
    let cy: Double
    let diameter_um: Double
    let diameter_px: Double
    let confidence: Double
    // Per-cell measurements (optional; absent from legacy sidecars).
    let area_um2: Double?
    let perimeter_um: Double?
    let circularity: Double?
    let eccentricity: Double?
    let mean_intensity: Double?
    let integrated_density: Double?
    // Quality flags (optional; absent from older sidecars → defaults applied at decode).
    let centroid_um_x: Double?
    let centroid_um_y: Double?
    let aspect_ratio: Double?
    let solidity: Double?
    let edge_touching: Bool?
    let likely_clump: Bool?
    let likely_debris: Bool?
    let size_class: String?
    let is_manual: Bool?
    /// Pass-14: per-cell polygon contour in image-pixel coords, as [[x, y], …].
    /// Optional — legacy sidecars and non-cellpose detectors don't emit it.
    let contour_px: [[Double]]?
}

/// Structured error emitted by a sidecar when a known failure occurs
/// (e.g. model not found, import error). The Swift host checks for this
/// before attempting to decode a full SidecarPayload.
struct SidecarError: Decodable {
    let error: String
    let hint: String?
}
