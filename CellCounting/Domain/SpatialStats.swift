import Foundation

// MARK: — Spatial-statistics domain model
//
// Mirrors the JSON payload `spatial_stats.py` prints to stdout (which is
// `_spatial.compute()`'s result dict, plus `width`/`height`). See
// `CellCounting/python/_spatial.py` for the producing side — this file only
// reads that shape by convention; it does not (and cannot, being Swift)
// import it.
//
// Not persisted anywhere yet — see the equivalent note at the top of
// `Domain/PunctaAssay.swift`; the same reasoning applies here.

/// Per-cell nearest-neighbour distance + local density. One entry per
/// `_spatial.compute()` `per_cell[]` row.
struct SpatialCellStat: Identifiable, Codable, Hashable {
    var id: Int { index }
    let index: Int
    /// The cell's own id when the caller supplied one, else its 0-based index.
    let label: String?
    let cxPx: Double
    let cyPx: Double
    /// Distance to this cell's nearest neighbour, in µm. Nil only when the
    /// image has exactly 1 cell (see `SpatialStatsResult.message`).
    let nnDistanceUm: Double?
    let nnIndex: Int?
    let nnLabel: String?
    /// Count of OTHER cells within `SpatialStatsResult.densityRadiusUm`.
    let localDensity: Int

    enum CodingKeys: String, CodingKey {
        case index, label
        case cxPx = "cx_px", cyPx = "cy_px"
        case nnDistanceUm = "nn_distance_um"
        case nnIndex = "nn_index"
        case nnLabel = "nn_label"
        case localDensity = "local_density"
    }
}

/// Optional density-heatmap grid — a coarse 2-D histogram of cell centroids
/// over the image extent. Mirrors `_spatial.compute()`'s `heatmap` dict.
struct SpatialHeatmap: Codable, Hashable {
    /// `grid[row][col]`; row = y (top-to-bottom), col = x (left-to-right).
    /// See `_spatial._density_heatmap`'s `orientation` note.
    let grid: [[Double]]
    let nx: Int
    let ny: Int
    let cellWidthUm: Double
    let cellHeightUm: Double
    let x0Um: Double
    let y0Um: Double

    enum CodingKeys: String, CodingKey {
        case grid, nx, ny
        case cellWidthUm = "cell_width_um"
        case cellHeightUm = "cell_height_um"
        case x0Um = "x0_um"
        case y0Um = "y0_um"
    }

    /// Highest count in `grid` — for normalizing a color ramp. 0 when empty.
    var maxCount: Double {
        grid.flatMap { $0 }.max() ?? 0
    }
}

/// Plain-language Clark-Evans classification, derived client-side from the
/// same R/z the sidecar already interpreted server-side. Kept as an enum
/// (rather than string-matching the sidecar's sentence) so the UI can pick
/// colors/icons directly.
enum ClarkEvansClass {
    case clustered, random, dispersed

    /// Mirrors `_spatial._interpret_clark_evans()`'s significance rule
    /// exactly (|z| < 1.96 -> "random", the standard p<0.05 two-sided
    /// cutoff) — keep the two in sync if that threshold ever changes.
    init(r: Double, z: Double) {
        if abs(z) < 1.96 {
            self = .random
        } else if r < 1.0 {
            self = .clustered
        } else {
            self = .dispersed
        }
    }

    var label: String {
        switch self {
        case .clustered: return "Clustered"
        case .random: return "Random"
        case .dispersed: return "Dispersed"
        }
    }

    /// Index into `Tokens.binRamp` used for this class's swatch — chosen to
    /// avoid the app's success/warning/danger traffic-light colors, since
    /// "clustered" vs "dispersed" is descriptive, not a quality judgement.
    var tokenBinIndex: Int {
        switch self {
        case .clustered:  return 0   // cool end of the ramp
        case .random:      return 2   // midpoint
        case .dispersed:  return 4   // warm end of the ramp
        }
    }
}

/// User-settable spatial-statistics parameters — mirrors
/// `_spatial.DEFAULT_PARAMS`. Purely local UI state in this pass (see
/// `SpatialStatsPanel`'s splice-instructions comment for the persistence seam).
struct SpatialStatsParams: Codable, Hashable {
    /// Local-density neighbour search radius, in µm.
    var radiusUm: Double = 50.0
    var heatmap: Bool = false
    var heatmapBinUm: Double = 25.0
    var heatmapMaxBins: Int = 64
}

/// Full spatial-statistics result for one image. Mirrors the
/// `spatial_stats.py` stdout payload (`_spatial.compute()` + width/height).
struct SpatialStatsResult: Codable, Hashable {
    let nCells: Int
    let perCell: [SpatialCellStat]
    let meanNndUm: Double?
    let medianNndUm: Double?
    let minNndUm: Double?
    let maxNndUm: Double?
    /// Echoes the radius parameter that produced `perCell[].localDensity`.
    let densityRadiusUm: Double
    let meanLocalDensity: Double?
    let clarkEvansR: Double?
    let clarkEvansZ: Double?
    /// Server-rendered plain-language sentence — shown verbatim in the UI;
    /// `clarkEvansClass` below is for coloring/iconography only.
    let clarkEvansInterpretation: String?
    let heatmap: SpatialHeatmap?
    /// Set whenever the result is degraded (e.g. <2 cells).
    let message: String?

    enum CodingKeys: String, CodingKey {
        case nCells = "n_cells"
        case perCell = "per_cell"
        case meanNndUm = "mean_nnd_um"
        case medianNndUm = "median_nnd_um"
        case minNndUm = "min_nnd_um"
        case maxNndUm = "max_nnd_um"
        case densityRadiusUm = "density_radius_um"
        case meanLocalDensity = "mean_local_density"
        case clarkEvansR = "clark_evans_R"
        case clarkEvansZ = "clark_evans_z"
        case clarkEvansInterpretation = "clark_evans_interpretation"
        case heatmap, message
    }

    /// Derived classification for UI coloring — see `ClarkEvansClass`.
    var clarkEvansClass: ClarkEvansClass? {
        guard let r = clarkEvansR, let z = clarkEvansZ else { return nil }
        return ClarkEvansClass(r: r, z: z)
    }
}
