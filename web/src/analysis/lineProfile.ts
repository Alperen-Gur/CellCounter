import { assertCalibration, assertRaster, type Point, type Raster } from "./types";

export interface LineProfileSample {
  readonly index: number;
  readonly xPx: number;
  readonly yPx: number;
  readonly distancePx: number;
  readonly distanceUm: number | null;
  readonly channels: readonly number[];
  readonly luminance: number;
}
function bilinear(raster: Raster, x: number, y: number, channel: number): number {
  const x0 = Math.floor(x); const y0 = Math.floor(y);
  const x1 = Math.min(raster.width - 1, x0 + 1); const y1 = Math.min(raster.height - 1, y0 + 1);
  const fx = x - x0; const fy = y - y0;
  const sample = (sx: number, sy: number) => Number(raster.data[(sy * raster.width + sx) * raster.channels + channel]);
  return sample(x0, y0) * (1 - fx) * (1 - fy) + sample(x1, y0) * fx * (1 - fy) + sample(x0, y1) * (1 - fx) * fy + sample(x1, y1) * fx * fy;
}

export function sampleLineProfile(
  raster: Raster,
  start: Point,
  end: Point,
  options: { readonly stepPx?: number; readonly pxPerUm?: number } = {},
): LineProfileSample[] {
  assertRaster(raster);
  for (const point of [start, end]) if (point.x < 0 || point.x > raster.width - 1 || point.y < 0 || point.y > raster.height - 1) throw new RangeError("Line-profile endpoints must lie inside the source image.");
  if (options.pxPerUm !== undefined) assertCalibration(options.pxPerUm);
  const distance = Math.hypot(end.x - start.x, end.y - start.y);
  const step = options.stepPx ?? 1;
  if (!(step > 0) || !Number.isFinite(step)) throw new RangeError("Line-profile step must be finite and greater than zero.");
  const segments = Math.max(1, Math.ceil(distance / step));
  return Array.from({ length: segments + 1 }, (_, index) => {
    const fraction = index / segments;
    const xPx = start.x + (end.x - start.x) * fraction;
    const yPx = start.y + (end.y - start.y) * fraction;
    const channels = Array.from({ length: raster.channels }, (__, channel) => bilinear(raster, xPx, yPx, channel));
    const luminance = channels.length >= 3 ? 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2] : channels[0];
    const distancePx = distance * fraction;
    return { index, xPx, yPx, distancePx, distanceUm: options.pxPerUm ? distancePx / options.pxPerUm : null, channels, luminance };
  });
}
