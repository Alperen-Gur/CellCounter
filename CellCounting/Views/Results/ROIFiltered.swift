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
