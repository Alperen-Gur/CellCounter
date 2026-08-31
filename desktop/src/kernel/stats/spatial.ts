import type { CellDTO } from "../types";

export interface SpatialSummary {
  n: number;
  meanNndUm: number;
  medianNndUm: number;
  minNndUm: number;
  maxNndUm: number;
  meanLocalDensity: number;
  densityRadiusUm: number;
  clarkEvansR: number;
  clarkEvansZ: number;
  classification: "clustered" | "random" | "dispersed";
}

/** Exact nearest-neighbour distances with an x-sorted pruning sweep.
 * Average microscopy fields avoid the quadratic all-pairs allocation while
 * retaining exact Euclidean answers and deterministic ordering.
 */
function nearestDistancesPx(cells: readonly CellDTO[]): number[] {
  const points = cells
    .map((cell, index) => ({ x: cell.cx, y: cell.cy, index }))
    .sort((a, b) => a.x - b.x || a.y - b.y || a.index - b.index);
  const result = new Array<number>(cells.length).fill(Number.POSITIVE_INFINITY);

  for (let i = 0; i < points.length; i += 1) {
    const point = points[i];
    let bestSquared = result[point.index] ** 2;
    for (let j = i - 1; j >= 0; j -= 1) {
      const candidate = points[j];
      const dx = point.x - candidate.x;
      if (dx * dx >= bestSquared) break;
      const dy = point.y - candidate.y;
      const squared = dx * dx + dy * dy;
      if (squared < bestSquared) {
        bestSquared = squared;
        result[point.index] = Math.sqrt(squared);
      }
      if (squared < result[candidate.index] ** 2) {
        result[candidate.index] = Math.sqrt(squared);
      }
    }
    // A point may not have a finite left-side candidate (the leftmost point).
    // Scan right until x-distance alone cannot improve its current best.
    if (!Number.isFinite(result[point.index])) {
      for (let j = i + 1; j < points.length; j += 1) {
        const candidate = points[j];
        const dx = candidate.x - point.x;
        if (dx * dx >= bestSquared) break;
        const dy = point.y - candidate.y;
        const squared = dx * dx + dy * dy;
        if (squared < bestSquared) {
          bestSquared = squared;
          result[point.index] = Math.sqrt(squared);
        }
      }
    }
  }
  return result;
}

function localDensities(cells: readonly CellDTO[], radiusPx: number): number[] {
  const size = Math.max(radiusPx, 1e-9);
  const buckets = new Map<string, number[]>();
  const key = (x: number, y: number) => `${x}:${y}`;
  cells.forEach((cell, index) => {
    const gx = Math.floor(cell.cx / size);
    const gy = Math.floor(cell.cy / size);
    const bucketKey = key(gx, gy);
    const bucket = buckets.get(bucketKey);
    if (bucket) bucket.push(index);
    else buckets.set(bucketKey, [index]);
  });

  const radiusSquared = radiusPx * radiusPx;
  return cells.map((cell, index) => {
    const gx = Math.floor(cell.cx / size);
    const gy = Math.floor(cell.cy / size);
    let count = 0;
    for (let oy = -1; oy <= 1; oy += 1) {
      for (let ox = -1; ox <= 1; ox += 1) {
        for (const otherIndex of buckets.get(key(gx + ox, gy + oy)) ?? []) {
          if (otherIndex === index) continue;
          const other = cells[otherIndex];
          const dx = cell.cx - other.cx;
          const dy = cell.cy - other.cy;
          if (dx * dx + dy * dy <= radiusSquared) count += 1;
        }
      }
    }
    return count;
  });
}

function median(values: readonly number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[middle - 1] + sorted[middle]) / 2
    : sorted[middle];
}

export function spatialSummary(
  cells: readonly CellDTO[],
  pxPerUm: number,
  widthPx: number,
  heightPx: number,
  densityRadiusUm = 50,
): SpatialSummary | null {
  if (cells.length < 2 || !(pxPerUm > 0) || !(widthPx > 0) || !(heightPx > 0)) {
    return null;
  }
  const distancesUm = nearestDistancesPx(cells).map((distance) => distance / pxPerUm);
  if (distancesUm.some((distance) => !Number.isFinite(distance))) return null;
  const meanNndUm = distancesUm.reduce((sum, value) => sum + value, 0) / distancesUm.length;
  const minNndUm = distancesUm.reduce(
    (minimum, value) => Math.min(minimum, value),
    Number.POSITIVE_INFINITY,
  );
  const maxNndUm = distancesUm.reduce(
    (maximum, value) => Math.max(maximum, value),
    Number.NEGATIVE_INFINITY,
  );
  const densities = localDensities(cells, densityRadiusUm * pxPerUm);
  const meanLocalDensity = densities.reduce((sum, value) => sum + value, 0) / densities.length;

  const areaUm2 = (widthPx / pxPerUm) * (heightPx / pxPerUm);
  const density = cells.length / areaUm2;
  const expected = 0.5 / Math.sqrt(density);
  const standardError = 0.26136 / Math.sqrt(cells.length * density);
  const clarkEvansR = meanNndUm / expected;
  const clarkEvansZ = standardError > 0 ? (meanNndUm - expected) / standardError : 0;
  const classification = Math.abs(clarkEvansZ) < 1.96
    ? "random"
    : clarkEvansR < 1
      ? "clustered"
      : "dispersed";

  return {
    n: cells.length,
    meanNndUm,
    medianNndUm: median(distancesUm),
    minNndUm,
    maxNndUm,
    meanLocalDensity,
    densityRadiusUm,
    clarkEvansR,
    clarkEvansZ,
    classification,
  };
}
