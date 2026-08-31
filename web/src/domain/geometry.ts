import type { SourcePointPx, SourcePolygonPx, SourceRectPx } from "./types";

const EPSILON = 1e-9;

export function polygonSignedArea(contour: SourcePolygonPx): number {
  let doubled = 0;
  for (let index = 0; index < contour.length; index += 1) {
    const current = contour[index];
    const next = contour[(index + 1) % contour.length];
    doubled += current.x * next.y - next.x * current.y;
  }
  return doubled / 2;
}

export function polygonArea(contour: SourcePolygonPx): number {
  return Math.abs(polygonSignedArea(contour));
}

export function polygonPerimeter(contour: SourcePolygonPx): number {
  let result = 0;
  for (let index = 0; index < contour.length; index += 1) {
    const current = contour[index];
    const next = contour[(index + 1) % contour.length];
    result += Math.hypot(next.x - current.x, next.y - current.y);
  }
  return result;
}

export function polygonBounds(contour: SourcePolygonPx): SourceRectPx {
  if (contour.length === 0) throw new RangeError("A contour cannot be empty");
  let minX = contour[0].x;
  let maxX = contour[0].x;
  let minY = contour[0].y;
  let maxY = contour[0].y;
  for (const point of contour.slice(1)) {
    minX = Math.min(minX, point.x);
    maxX = Math.max(maxX, point.x);
    minY = Math.min(minY, point.y);
    maxY = Math.max(maxY, point.y);
  }
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}

export function polygonCentroid(contour: SourcePolygonPx): SourcePointPx {
  const signedArea = polygonSignedArea(contour);
  if (Math.abs(signedArea) <= EPSILON) {
    const sum = contour.reduce(
      (acc, point) => ({ x: acc.x + point.x, y: acc.y + point.y }),
      { x: 0, y: 0 },
    );
    return { x: sum.x / contour.length, y: sum.y / contour.length };
  }
  let x = 0;
  let y = 0;
  for (let index = 0; index < contour.length; index += 1) {
    const current = contour[index];
    const next = contour[(index + 1) % contour.length];
    const cross = current.x * next.y - next.x * current.y;
    x += (current.x + next.x) * cross;
    y += (current.y + next.y) * cross;
  }
  const factor = 1 / (6 * signedArea);
  return { x: x * factor, y: y * factor };
}

function cross(origin: SourcePointPx, a: SourcePointPx, b: SourcePointPx): number {
  return (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x);
}

export function convexHull(points: SourcePolygonPx): SourcePointPx[] {
  const sorted = [...points]
    .map((point) => ({ ...point }))
    .sort((a, b) => a.x - b.x || a.y - b.y)
    .filter((point, index, all) => index === 0 || point.x !== all[index - 1].x || point.y !== all[index - 1].y);
  if (sorted.length <= 2) return sorted;

  const lower: SourcePointPx[] = [];
  for (const point of sorted) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower[lower.length - 1], point) <= 0) {
      lower.pop();
    }
    lower.push(point);
  }
  const upper: SourcePointPx[] = [];
  for (const point of [...sorted].reverse()) {
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper[upper.length - 1], point) <= 0) {
      upper.pop();
    }
    upper.push(point);
  }
  lower.pop();
  upper.pop();
  return [...lower, ...upper];
}

export function circleContour(center: SourcePointPx, diameterPx: number, vertices = 32): SourcePointPx[] {
  if (!Number.isFinite(diameterPx) || diameterPx <= 0) throw new RangeError("Diameter must be positive");
  return Array.from({ length: vertices }, (_, index) => {
    const angle = (index / vertices) * Math.PI * 2;
    return {
      x: center.x + Math.cos(angle) * diameterPx * 0.5,
      y: center.y + Math.sin(angle) * diameterPx * 0.5,
    };
  });
}

export function clipPolygonByLine(
  polygon: SourcePolygonPx,
  lineStart: SourcePointPx,
  lineEnd: SourcePointPx,
  keepPositive: boolean,
): SourcePointPx[] {
  const dx = lineEnd.x - lineStart.x;
  const dy = lineEnd.y - lineStart.y;
  if (Math.hypot(dx, dy) <= EPSILON) throw new RangeError("Split line must have non-zero length");
  const side = (point: SourcePointPx) => dx * (point.y - lineStart.y) - dy * (point.x - lineStart.x);
  const inside = (point: SourcePointPx) => (keepPositive ? side(point) >= -EPSILON : side(point) <= EPSILON);
  const output: SourcePointPx[] = [];

  for (let index = 0; index < polygon.length; index += 1) {
    const current = polygon[index];
    const next = polygon[(index + 1) % polygon.length];
    const currentInside = inside(current);
    const nextInside = inside(next);
    if (currentInside) output.push({ ...current });
    if (currentInside !== nextInside) {
      const a = side(current);
      const b = side(next);
      const t = a / (a - b);
      output.push({ x: current.x + t * (next.x - current.x), y: current.y + t * (next.y - current.y) });
    }
  }
  return output;
}
