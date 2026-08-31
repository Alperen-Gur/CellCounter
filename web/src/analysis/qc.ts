import { mean, sampleStandardDeviation } from "./math";
import { assertRaster, type Raster } from "./types";

export interface ImageQualityResult {
  /** Variance of a 4-neighbour Laplacian; higher is sharper. */
  readonly focusScore: number;
  /** Coefficient of variation of block means; lower is flatter illumination. */
  readonly illuminationResidual: number;
  readonly blockCount: number;
}

export function assessImageQuality(raster: Raster, options: { readonly channel?: number; readonly blockSizePx?: number } = {}): ImageQualityResult {
  assertRaster(raster);
  const channel = options.channel ?? 0;
  if (channel < 0 || channel >= raster.channels) throw new RangeError("QC channel is outside the raster.");
  const value = (x: number, y: number) => Number(raster.data[(y * raster.width + x) * raster.channels + channel]);
  let laplacianCount = 0; let laplacianMean = 0; let laplacianM2 = 0;
  for (let y = 1; y < raster.height - 1; y += 1) {
    for (let x = 1; x < raster.width - 1; x += 1) {
      const laplacian = value(x - 1, y) + value(x + 1, y) + value(x, y - 1) + value(x, y + 1) - 4 * value(x, y);
      laplacianCount += 1;
      const delta = laplacian - laplacianMean;
      laplacianMean += delta / laplacianCount;
      laplacianM2 += delta * (laplacian - laplacianMean);
    }
  }
  const focusScore = laplacianCount > 1 ? laplacianM2 / (laplacianCount - 1) : 0;
  const blockSize = Math.max(4, Math.trunc(options.blockSizePx ?? Math.max(8, Math.min(raster.width, raster.height) / 8)));
  const blockMeans: number[] = [];
  for (let y0 = 0; y0 < raster.height; y0 += blockSize) {
    for (let x0 = 0; x0 < raster.width; x0 += blockSize) {
      let sum = 0; let count = 0;
      for (let y = y0; y < Math.min(raster.height, y0 + blockSize); y += 1) {
        for (let x = x0; x < Math.min(raster.width, x0 + blockSize); x += 1) { sum += value(x, y); count += 1; }
      }
      blockMeans.push(sum / count);
    }
  }
  const average = mean(blockMeans) ?? 0;
  return { focusScore, illuminationResidual: average !== 0 ? (sampleStandardDeviation(blockMeans) ?? 0) / Math.abs(average) : 0, blockCount: blockMeans.length };
}
