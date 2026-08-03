import Foundation
import CoreGraphics

/// Filters a cell list through a set of include/exclude ROIs.
///
/// Rules:
/// - If there are NO `include` ROIs, all cells pass the include step.
/// - If there are includes, a cell must be inside at least one include ROI.
/// - Then, if the cell is inside any `exclude` ROI, it's removed.
///
/// Cell-in-shape test uses cell.cx/cy plus rect-contains or the ellipse equation
/// (((cx - rx) / rw)^2 + ((cy - ry) / rh)^2 <= 1) where (rx, ry) is the ellipse
/// center and (rw, rh) are its semi-axes.
enum ROIFilter {
    static func apply(cells: [DetectedCell], rois: [ROIRecord]) -> [DetectedCell] {
        guard !rois.isEmpty else { return cells }
        let includes = rois.filter { $0.kind == "include" }
        let excludes = rois.filter { $0.kind == "exclude" }
        return cells.filter { cell in
            if !includes.isEmpty {
                let inSomeInclude = includes.contains { contains(roi: $0, x: cell.cx, y: cell.cy) }
                if !inSomeInclude { return false }
            }
            if excludes.contains(where: { contains(roi: $0, x: cell.cx, y: cell.cy) }) {
                return false
            }
            return true
        }
    }

    /// True if the point (px, py) — in source-image pixel space — lies inside the ROI's shape.
    static func contains(roi: ROIRecord, x px: Double, y py: Double) -> Bool {
        switch roi.shape {
        case "ellipse":
            let rw = roi.width / 2
            let rh = roi.height / 2
            guard rw > 0, rh > 0 else { return false }
            let cx = roi.x + rw
            let cy = roi.y + rh
            let nx = (px - cx) / rw
            let ny = (py - cy) / rh
            return nx * nx + ny * ny <= 1
        default: // "rect"
            return px >= roi.x && px <= roi.x + roi.width
                && py >= roi.y && py <= roi.y + roi.height
        }
    }
}

// MARK: — Assay result staleness

/// Fingerprint of everything an assay result was derived from.
///
/// WHY THIS IS NOT JUST AN IMAGE ID. The per-image assay panels (Puncta,
/// Spatial stats, Neurite) used to tag their result with `ImageRecord.id` and
/// clear it when that id changed. That correctly clears on paging between
/// images and NOTHING ELSE — because the id is stable across every other way
/// the cell set can change underneath a result:
///
///   • ⌘R re-detection replaces the `DetectionRecord` on the SAME `ImageRecord`;
///   • `AppState.removeCells` mutates `detection.cells` in place;
///   • split / merge do the same;
///   • dragging the confidence slider changes the effective cutoff;
///   • drawing or deleting an ROI changes which cells survive filtering.
///
/// Every one of those left a panel showing numbers computed against a cell set
/// that no longer exists, side by side with a `TotalBlock` showing the new
/// count — e.g. "212 cells · 41% with 5+ foci" next to a total of 148, with the
/// percentage's denominator silently being the discarded set.
///
/// Comparing this whole key instead of the bare id closes that: `cellCount`
/// moves on any add/remove/split/merge/re-detect, `cutoff` moves the instant
/// the slider does (even where the count happens not to change), and `roiCount`
/// moves on ROI add/delete. The panels ALSO clear on `.ccCorrectionsChanged`,
/// which is posted by exactly the mutation paths above — belt and braces, so a
/// re-run that coincidentally returns the same number of cells still drops the
/// stale result.
struct AssayResultKey: Equatable {
    let imageId: UUID?
    let cellCount: Int
    let cutoff: Double
    let roiCount: Int
}

/// Series-level equivalent for `TrackingPanel`, whose input is a whole batch
/// rather than one image. The batch id alone has the same blind spot as an
/// image id — re-detecting or editing any frame leaves it untouched — so the
/// per-frame cell counts ride along, plus each frame's effective cutoff so a
/// slider drag that doesn't change a count still invalidates.
struct SeriesResultKey: Equatable {
    let batchId: UUID?
    let frameCellCounts: [Int]
    let frameCutoffs: [Double]
}
