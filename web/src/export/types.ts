export interface ExportPoint { readonly x: number; readonly y: number }
export interface ExportCell {
  readonly id: string;
  readonly cx: number;
  readonly cy: number;
  readonly diameterPx: number;
  readonly diameterUm?: number;
  readonly confidence?: number;
  readonly isManual?: boolean;
  readonly contourPx?: readonly (ExportPoint | readonly [number, number])[];
}
export interface RgbaImage {
  readonly data: Uint8Array | Uint8ClampedArray;
  readonly width: number;
  readonly height: number;
}

export function contourPoints(cell: ExportCell, circleSegments = 32): ExportPoint[] {
  if (cell.contourPx && cell.contourPx.length >= 3) return cell.contourPx.map((point) => Array.isArray(point) ? { x: point[0], y: point[1] } : point as ExportPoint);
  const radius = cell.diameterPx / 2;
  return Array.from({ length: circleSegments }, (_, index) => {
    const angle = index * Math.PI * 2 / circleSegments;
    return { x: cell.cx + Math.cos(angle) * radius, y: cell.cy + Math.sin(angle) * radius };
  });
}
