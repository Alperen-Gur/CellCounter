import { mean } from "./math";
import { assertCalibration, type IdentifiedPoint } from "./types";

export interface SpatialStatistics {
  readonly cellCount: number;
  readonly areaUm2: number;
  readonly nearestNeighborUm: Readonly<Record<string, number | null>>;
  readonly meanNearestNeighborUm: number | null;
  readonly localDensityPerMm2: Readonly<Record<string, number>>;
  readonly meanLocalDensityPerMm2: number;
  readonly clarkEvansR: number | null;
  readonly clarkEvansZ: number | null;
  readonly clarkEvansInterpretation: "clustered" | "random" | "dispersed" | "insufficient-data";
  readonly caveat: string;
}

interface KdNode { readonly index: number; readonly axis: 0 | 1; readonly left: KdNode | null; readonly right: KdNode | null }
function buildTree(indices: number[], points: readonly IdentifiedPoint[], depth = 0): KdNode | null {
  if (!indices.length) return null;
  const axis = (depth % 2) as 0 | 1;
  const coordinate = (index: number) => axis ? points[index].y : points[index].x;
  indices.sort((a, b) => coordinate(a) - coordinate(b) || points[a].id.localeCompare(points[b].id));
  const middle = Math.floor(indices.length / 2);
  return { index: indices[middle], axis, left: buildTree(indices.slice(0, middle), points, depth + 1), right: buildTree(indices.slice(middle + 1), points, depth + 1) };
}

function nearestDistance(root: KdNode | null, points: readonly IdentifiedPoint[], queryIndex: number): number | null {
  const query = points[queryIndex]; let best = Infinity;
  const visit = (node: KdNode | null): void => {
    if (!node) return;
    const point = points[node.index];
    if (node.index !== queryIndex) best = Math.min(best, (point.x - query.x) ** 2 + (point.y - query.y) ** 2);
    const delta = node.axis ? query.y - point.y : query.x - point.x;
    visit(delta <= 0 ? node.left : node.right);
    if (delta * delta <= best) visit(delta <= 0 ? node.right : node.left);
  };
  visit(root);
  return Number.isFinite(best) ? Math.sqrt(best) : null;
}

export function spatialStatistics(
  points: readonly IdentifiedPoint[],
  options: { readonly widthPx: number; readonly heightPx: number; readonly pxPerUm: number; readonly densityRadiusUm?: number; readonly signal?: AbortSignal },
): SpatialStatistics {
  assertCalibration(options.pxPerUm);
  if (!(options.widthPx > 0) || !(options.heightPx > 0)) throw new RangeError("Spatial domain dimensions must be positive.");
  if (new Set(points.map(({ id }) => id)).size !== points.length) throw new RangeError("Spatial point ids must be unique.");
  const areaUm2 = options.widthPx * options.heightPx / options.pxPerUm ** 2;
  const radiusUm = options.densityRadiusUm ?? 50;
  if (!(radiusUm > 0)) throw new RangeError("Density radius must be positive.");
  const radiusPx = radiusUm * options.pxPerUm;
  const tree = buildTree(points.map((_, index) => index), points);
  const grid = new Map<string, number[]>();
  const cellKey = (x: number, y: number) => `${Math.floor(x / radiusPx)},${Math.floor(y / radiusPx)}`;
  points.forEach((point, index) => { const key = cellKey(point.x, point.y); const bucket = grid.get(key); if (bucket) bucket.push(index); else grid.set(key, [index]); });
  const nearestNeighborUm: Record<string, number | null> = {};
  const localDensityPerMm2: Record<string, number> = {};
  points.forEach((point, pointIndex) => {
    if ((pointIndex & 255) === 0) options.signal?.throwIfAborted();
    const nearestPx = nearestDistance(tree, points, pointIndex);
    nearestNeighborUm[point.id] = nearestPx === null ? null : nearestPx / options.pxPerUm;
    const gridX = Math.floor(point.x / radiusPx); const gridY = Math.floor(point.y / radiusPx);
    let neighborCount = 0;
    for (let dy = -1; dy <= 1; dy += 1) for (let dx = -1; dx <= 1; dx += 1) {
      for (const otherIndex of grid.get(`${gridX + dx},${gridY + dy}`) ?? []) {
        if (otherIndex !== pointIndex && Math.hypot(points[otherIndex].x - point.x, points[otherIndex].y - point.y) <= radiusPx) neighborCount += 1;
      }
    }
    localDensityPerMm2[point.id] = neighborCount / (Math.PI * radiusUm ** 2) * 1_000_000;
  });
  const observed = mean(Object.values(nearestNeighborUm).filter((value): value is number => value !== null));
  const density = points.length / areaUm2;
  const expected = density > 0 ? 0.5 / Math.sqrt(density) : null;
  const r = observed !== null && expected ? observed / expected : null;
  const standardError = points.length > 1 && density > 0 ? 0.26136 / Math.sqrt(points.length * density) : null;
  const z = observed !== null && expected !== null && standardError ? (observed - expected) / standardError : null;
  return {
    cellCount: points.length, areaUm2, nearestNeighborUm, meanNearestNeighborUm: observed, localDensityPerMm2,
    meanLocalDensityPerMm2: mean(Object.values(localDensityPerMm2)) ?? 0,
    clarkEvansR: r, clarkEvansZ: z,
    clarkEvansInterpretation: z === null ? "insufficient-data" : z < -1.96 ? "clustered" : z > 1.96 ? "dispersed" : "random",
    caveat: "Clark–Evans uses an uncorrected rectangular observation window; cells near an image edge have truncated neighbourhoods.",
  };
}
