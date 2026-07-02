/**
 * pages/results/roiFilter.ts — include/exclude ROI filtering for the Results
 * sidebar counts.
 *
 * Direct port of `Views/Results/ROIFiltered.swift` (`ROIFilter`). Pure, operates
 * in SOURCE-PIXEL space (cells + ROIs share the coordinate system, so no
 * scaling). Owned by feat-results-viewer; the ROI *records* come from
 * PersistencePort (`rois(imageId)`), the geometry test lives here.
 *
 * Rules (identical to Swift):
 *   - No `include` ROIs  → every cell passes the include step.
 *   - With includes      → a cell must be inside at least one include ROI.
 *   - Then, if the cell is inside ANY `exclude` ROI, it is removed
 *     (exclude wins over include — "include → exclude").
 */

import type { CellDTO } from "../../kernel/types";
import type { RoiDTO } from "../../kernel/persistence";

/**
 * True if the point (px, py) — source-pixel space — lies inside the ROI's
 * shape. `"ellipse"` uses the normalized ellipse equation; anything else is
 * treated as an axis-aligned rect (matches the Swift `default:` branch).
 */
export function roiContains(roi: RoiDTO, px: number, py: number): boolean {
  if (roi.shape === "ellipse") {
    const rw = roi.width / 2;
    const rh = roi.height / 2;
    if (rw <= 0 || rh <= 0) return false;
    const cx = roi.x + rw;
    const cy = roi.y + rh;
    const nx = (px - cx) / rw;
    const ny = (py - cy) / rh;
    return nx * nx + ny * ny <= 1;
  }
  // "rect" (and any unknown shape).
  return (
    px >= roi.x &&
    px <= roi.x + roi.width &&
    py >= roi.y &&
    py <= roi.y + roi.height
  );
}

/**
 * Filter `cells` through the `rois` set. Returns the input unchanged when there
 * are no ROIs. Port of `ROIFilter.apply`.
 */
export function applyRoiFilter(cells: CellDTO[], rois: RoiDTO[]): CellDTO[] {
  if (rois.length === 0) return cells;
  const includes = rois.filter((r) => r.kind === "include");
  const excludes = rois.filter((r) => r.kind === "exclude");
  return cells.filter((cell) => {
    if (includes.length > 0) {
      const inSomeInclude = includes.some((r) =>
        roiContains(r, cell.cx, cell.cy),
      );
      if (!inSomeInclude) return false;
    }
    if (excludes.some((r) => roiContains(r, cell.cx, cell.cy))) {
      return false;
    }
    return true;
  });
}
