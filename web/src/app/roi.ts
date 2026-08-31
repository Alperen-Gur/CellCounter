import type { WorkspaceCell, WorkspaceImage, WorkspaceRoi } from "./types";

function contains(roi: WorkspaceRoi, cell: WorkspaceCell): boolean {
  return cell.cx >= roi.x && cell.cx <= roi.x + roi.width && cell.cy >= roi.y && cell.cy <= roi.y + roi.height;
}

/** Centroid-based include/exclude filter in immutable source-pixel coordinates. */
export function filterCellsByRois(image: Pick<WorkspaceImage, "cells" | "rois">): WorkspaceCell[] {
  const include = image.rois.filter((roi) => roi.kind === "include");
  const exclude = image.rois.filter((roi) => roi.kind === "exclude");
  return image.cells.filter((cell) => (!include.length || include.some((roi) => contains(roi, cell))) && !exclude.some((roi) => contains(roi, cell)));
}
