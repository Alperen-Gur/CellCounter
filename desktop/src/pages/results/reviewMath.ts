import type { CellDTO } from "../../kernel/types";

export type MeasurementMetric = "diameterUm" | "areaUm2" | "perimeterUm" | "meanIntensity" | "circularity" | "confidence";
export const MEASUREMENT_METRICS: { id: MeasurementMetric; label: string }[] = [
  { id: "diameterUm", label: "Diameter (µm)" }, { id: "areaUm2", label: "Area (µm²)" },
  { id: "perimeterUm", label: "Perimeter (µm)" }, { id: "meanIntensity", label: "Mean intensity" },
  { id: "circularity", label: "Circularity" }, { id: "confidence", label: "Confidence" },
];
export const MEASUREMENT_PAGE_SIZE = 50;
export const SCATTER_DRAW_LIMIT = 2500;
export interface MeasurementPoint { id: string; x: number; y: number }
export function scatterSample(points: readonly MeasurementPoint[], selected: ReadonlySet<string>): MeasurementPoint[] {
  const sampled: MeasurementPoint[] = [];
  for (const point of points) if (selected.has(point.id) && sampled.length < SCATTER_DRAW_LIMIT) sampled.push(point);
  const stride = Math.max(1, Math.ceil(points.length / SCATTER_DRAW_LIMIT));
  for (let i = 0; i < points.length && sampled.length < SCATTER_DRAW_LIMIT; i += stride) {
    if (!selected.has(points[i].id)) sampled.push(points[i]);
  }
  return sampled;
}
export function measurementPoints(cells: readonly CellDTO[], x: MeasurementMetric, y: MeasurementMetric): MeasurementPoint[] {
  return cells.flatMap(cell => {
    const xv = cell[x], yv = cell[y];
    return typeof xv === "number" && Number.isFinite(xv) && typeof yv === "number" && Number.isFinite(yv)
      ? [{ id: cell.id, x: xv, y: yv }] : [];
  });
}
export function pointRange(points: readonly MeasurementPoint[], axis: "x" | "y"): [number, number] {
  let low = Infinity, high = -Infinity;
  for (const point of points) { low = Math.min(low, point[axis]); high = Math.max(high, point[axis]); }
  if (!Number.isFinite(low)) return [0, 1];
  if (low === high) { const pad = Math.max(1, Math.abs(low) * .05); return [low - pad, high + pad]; }
  return [low, high];
}
export function selectMeasurementRange(points: readonly MeasurementPoint[], x: [number, number], y: [number, number]): Set<string> {
  return new Set(points.filter(p => p.x >= Math.min(...x) && p.x <= Math.max(...x) && p.y >= Math.min(...y) && p.y <= Math.max(...y)).map(p => p.id));
}
export function selectMeasurementPage(cells: readonly CellDTO[], page: number): readonly CellDTO[] {
  const start = Math.max(0, Math.min(Math.floor(page), Math.max(0, Math.ceil(cells.length / MEASUREMENT_PAGE_SIZE) - 1))) * MEASUREMENT_PAGE_SIZE;
  return cells.slice(start, start + MEASUREMENT_PAGE_SIZE);
}

function geometryKey(cell: CellDTO): string {
  const round = (n: number) => Math.round(n * 1000) / 1000;
  const points = (cell.contourPx ?? []).map(p => `${round(p[0])},${round(p[1])}`);
  if (points.length > 1 && points[0] === points[points.length - 1]) points.pop();
  // Polygon winding and starting vertex can change between exports.
  let polygon = "";
  if (points.length) {
    let first = 0;
    for (let i = 1; i < points.length; i++) if (points[i] < points[first]) first = i;
    const forward = points.slice(first).concat(points.slice(0, first)).join(";");
    const backward = [points[first], ...points.slice(0, first).reverse(), ...points.slice(first + 1).reverse()].join(";");
    polygon = forward < backward ? forward : backward;
  }
  return `${round(cell.cx)}:${round(cell.cy)}:${round(cell.diameterPx)}:${polygon}`;
}

export interface MaskDifference {
  unchanged: number;
  changed: number;
  removed: Set<string>;
  added: Set<string>;
  savedChanged: Set<string>;
  currentChanged: Set<string>;
}
export function compareMasks(saved: readonly CellDTO[], current: readonly CellDTO[]): MaskDifference {
  const result: MaskDifference = { unchanged: 0, changed: 0, removed: new Set(), added: new Set(), savedChanged: new Set(), currentChanged: new Set() };
  const currentByID = new Map(current.map(cell => [cell.id, cell]));
  const keys = new Map(current.map(cell => [cell.id, geometryKey(cell)]));
  const unmatched: CellDTO[] = [];
  for (const old of saved) {
    const match = currentByID.get(old.id);
    if (!match) { unmatched.push(old); continue; }
    currentByID.delete(old.id);
    if (geometryKey(old) === keys.get(match.id)) result.unchanged++;
    else { result.changed++; result.savedChanged.add(old.id); result.currentChanged.add(match.id); }
  }
  const geometryMatches = new Map<string, string[]>();
  for (const cell of currentByID.values()) {
    const key = keys.get(cell.id)!;
    const bucket = geometryMatches.get(key) ?? [];
    bucket.push(cell.id); geometryMatches.set(key, bucket);
  }
  for (const old of unmatched) {
    const matchedID = geometryMatches.get(geometryKey(old))?.pop();
    if (matchedID) { result.unchanged++; currentByID.delete(matchedID); }
    else result.removed.add(old.id);
  }
  for (const id of currentByID.keys()) result.added.add(id);
  return result;
}

export function blocksImageWrites(imageID: string | undefined, active: boolean,
  jobs: readonly { status: string; items: readonly { imageId: string; status: string }[] }[]): boolean {
  return !!imageID && active && jobs.some(job => job.status === "running" && job.items.some(item => item.imageId === imageID && item.status !== "completed"));
}
