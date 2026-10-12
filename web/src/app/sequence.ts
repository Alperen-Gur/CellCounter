import type { WorkspaceCell, WorkspaceImage } from "./types";
/** Pixel-space propagation requires the same acquired plane and physical pixel grid. */
export function assertSequenceSpace(images: readonly WorkspaceImage[]): void {
  if (!images.length) return;
  const first = images[0];
  const plane = (image: WorkspaceImage) => {
    if (!image.analysis && ((image.sourceDimensions?.t ?? 1) > 1 || (image.sourceDimensions?.z ?? image.planeCount ?? 1) > 1 || (image.sourceDimensions?.c ?? image.samplesPerPixel ?? 3) > 3)) throw new Error("Analyze multidimensional sequence fields before propagation so the source plane is recorded.");
    const parameters = image.analysis?.parameters;
    return JSON.stringify([parameters?.sourceTime ?? 0, parameters?.sourceZ ?? 0, parameters?.sourceChannel ?? -1, parameters?.projection ?? "first", parameters?.channels ?? [0, 0]]);
  };
  const sourcePlane = plane(first), calibrated = Boolean(first.calibrationSource && first.calibrationSource !== "default");
  for (const image of images) {
    if (!Number.isFinite(image.pxPerUm) || image.pxPerUm <= 0 || Math.abs(image.pxPerUm - first.pxPerUm) > 1e-6 * first.pxPerUm || Boolean(image.calibrationSource && image.calibrationSource !== "default") !== calibrated || image.width !== first.width || image.height !== first.height || plane(image) !== sourcePlane) throw new Error("Sequence fields need matching calibration and captured time/Z/channel/projection. Register or convert them to a common source grid before propagation.");
  }
}
export interface DriftOffset { frame: number; dxPx: number; dyPx: number; matchedObjects: number }
function median(values: number[]): number { values.sort((a, b) => a - b); const m = Math.floor(values.length / 2); return values.length ? values.length % 2 ? values[m] : (values[m - 1] + values[m]) / 2 : 0; }
function nearest(cells: readonly WorkspaceCell[], queries: readonly WorkspaceCell[], limit: number, work: { evaluations: number }): number[] {
  const size = Math.max(8, Math.min(64, limit / 4)); const grid = new Map<string, number[]>();
  cells.forEach((cell, index) => { const key = `${Math.floor(cell.cx / size)}:${Math.floor(cell.cy / size)}`; const bucket = grid.get(key) ?? []; bucket.push(index); grid.set(key, bucket); });
  return queries.map((query) => {
    let best = -1, distance = limit * limit;
    const x0 = Math.floor((query.cx - limit) / size), x1 = Math.floor((query.cx + limit) / size), y0 = Math.floor((query.cy - limit) / size), y1 = Math.floor((query.cy + limit) / size);
    const charge = () => { if (++work.evaluations > 5_000_000) throw new Error("Dense sequence drift exceeds five million spatial visits/comparisons. Use fewer fields, fewer objects or disable drift estimation."); };
    for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) { charge(); for (const index of grid.get(`${x}:${y}`) ?? []) { charge(); const cell = cells[index]; const d = (cell.cx - query.cx) ** 2 + (cell.cy - query.cy) ** 2; if (d < distance || (d === distance && (best < 0 || index < best))) { best = index; distance = d; } } }
    return best;
  });
}
export function estimateDrift(frames: readonly (readonly WorkspaceCell[])[], limit = 120): DriftOffset[] {
  if (!Number.isFinite(limit) || limit <= 0 || limit > 10000 || frames.length > 10000 || frames.some((frame) => frame.length > 100000)) throw new Error("Sequence drift exceeds the bounded centroid-search budget.");
  if (frames.some((frame) => frame.some((cell) => !Number.isFinite(cell.cx) || !Number.isFinite(cell.cy) || Math.abs(cell.cx) > 1e9 || Math.abs(cell.cy) > 1e9))) throw new Error("Sequence centroids must be finite bounded pixel coordinates.");
  const work = { evaluations: 0 };
  let dxPx = 0, dyPx = 0; return frames.map((frame, index) => {
    if (!index) return { frame: index, dxPx, dyPx, matchedObjects: 0 };
    const previous = frames[index - 1], forward = nearest(frame, previous, limit, work), backward = nearest(previous, frame, limit, work);
    const pairs = forward.flatMap((target, source) => target >= 0 && backward[target] === source ? [{ source: previous[source], target: frame[target] }] : []);
    dxPx += median(pairs.map((pair) => pair.target.cx - pair.source.cx)); dyPx += median(pairs.map((pair) => pair.target.cy - pair.source.cy));
    return { frame: index, dxPx, dyPx, matchedObjects: pairs.length };
  });
}
function contour(cell: WorkspaceCell): Array<[number, number]> { return cell.contourPx ?? Array.from({ length: 32 }, (_, i) => [cell.cx + Math.cos(i * Math.PI / 16) * cell.diameterPx / 2, cell.cy + Math.sin(i * Math.PI / 16) * cell.diameterPx / 2]); }
function resample(points: Array<[number, number]>, count = 64): Array<[number, number]> {
  const lengths = [0]; for (let i = 1; i <= points.length; i++) lengths.push(lengths.at(-1)! + Math.hypot(points[i % points.length][0] - points[i - 1][0], points[i % points.length][1] - points[i - 1][1]));
  const total = lengths.at(-1)!; if (!total) throw new Error("Cannot interpolate a degenerate contour.");
  return Array.from({ length: count }, (_, i) => { const d = total * i / count; let s = 0; while (s + 1 < lengths.length - 1 && lengths[s + 1] < d) s++; const t = (d - lengths[s]) / Math.max(1e-9, lengths[s + 1] - lengths[s]); const a = points[s], b = points[(s + 1) % points.length]; return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]; });
}
export function translatedContour(cell: WorkspaceCell, dx: number, dy: number): Array<{ x: number; y: number }> { return contour(cell).map(([x, y]) => ({ x: x + dx, y: y + dy })); }
export function interpolatedContour(start: WorkspaceCell, end: WorkspaceCell, fraction: number): Array<{ x: number; y: number }> {
  const a = resample(contour(start)), b = resample(contour(end));
  // Match winding and cyclic phase before interpolating to avoid twisting masks.
  const signed = (values: Array<[number, number]>) => values.reduce((sum, p, i) => sum + p[0] * values[(i + 1) % values.length][1] - p[1] * values[(i + 1) % values.length][0], 0);
  if (signed(a) * signed(b) < 0) b.reverse();
  let best = 0, minimum = Infinity;
  for (let shift = 0; shift < b.length; shift++) { const distance = a.reduce((sum, p, i) => sum + (p[0] - start.cx - b[(i + shift) % b.length][0] + end.cx) ** 2 + (p[1] - start.cy - b[(i + shift) % b.length][1] + end.cy) ** 2, 0); if (distance < minimum) { minimum = distance; best = shift; } }
  return a.map((p, i) => ({ x: p[0] + (b[(i + best) % b.length][0] - p[0]) * fraction, y: p[1] + (b[(i + best) % b.length][1] - p[1]) * fraction }));
}
