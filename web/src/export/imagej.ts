import { zipSync, type Zippable } from "fflate";
import { contourPoints, type ExportCell } from "./types";

function safeName(value: string): string { return value.replaceAll(/[^A-Za-z0-9._-]+/g, "_").replace(/^_+|_+$/g, "") || "cell"; }

/** ImageJ ROI format v217 polygon record, using source-pixel coordinates. */
export function encodeImageJPolygonRoi(cell: ExportCell): Uint8Array {
  const points = contourPoints(cell, 48);
  if (points.length > 65_535) throw new RangeError("ImageJ ROI supports at most 65,535 polygon vertices.");
  let left = Infinity; let top = Infinity; let right = -Infinity; let bottom = -Infinity;
  for (const point of points) { left = Math.min(left, Math.floor(point.x)); top = Math.min(top, Math.floor(point.y)); right = Math.max(right, Math.ceil(point.x)); bottom = Math.max(bottom, Math.ceil(point.y)); }
  for (const value of [left, top, right, bottom]) if (value < 0 || value > 65_535) throw new RangeError("ImageJ ROI coordinates must fit unsigned 16-bit source-pixel bounds.");
  const output = new Uint8Array(64 + points.length * 4);
  output.set([0x49, 0x6f, 0x75, 0x74]);
  const view = new DataView(output.buffer);
  view.setUint16(4, 217, false); output[6] = 0; // polygon
  view.setUint16(8, top, false); view.setUint16(10, left, false); view.setUint16(12, bottom, false); view.setUint16(14, right, false);
  view.setUint16(16, points.length, false);
  points.forEach((point, index) => {
    view.setUint16(64 + index * 2, Math.max(0, Math.min(65_535, Math.round(point.x) - left)), false);
    view.setUint16(64 + points.length * 2 + index * 2, Math.max(0, Math.min(65_535, Math.round(point.y) - top)), false);
  });
  return output;
}

export function exportImageJRoiZip(cells: readonly ExportCell[]): Uint8Array {
  if (!cells.length) throw new RangeError("ImageJ ROI export needs at least one cell.");
  const files: Zippable = {};
  const deterministicZipDate = new Date(1980, 0, 1, 0, 0, 0);
  [...cells].sort((a, b) => a.id.localeCompare(b.id)).forEach((cell, index) => {
    const name = `${String(index + 1).padStart(4, "0")}-${safeName(cell.id)}.roi`;
    files[name] = [encodeImageJPolygonRoi(cell), { level: 0, mtime: deterministicZipDate }];
  });
  return zipSync(files, { level: 0, mtime: deterministicZipDate });
}
