/**
 * pages/results/histogram.ts — the size-distribution histogram math for the
 * Results sidebar DISTRIBUTION panel.
 *
 * Direct port of `HistogramMath` (declared in `Views/Compare/CompareView.swift`,
 * reused by the Results `DistributionPanel`). Fixed 24-bucket histogram over a
 * fixed 8–60 µm diameter window so bars line up across images/conditions. Pure.
 */

import type { CellDTO } from "../../kernel/types";

/** Number of histogram buckets (Swift `HistogramMath.bucketCount`). */
export const HIST_BUCKET_COUNT = 24;
/** Low edge of the histogram window, µm (Swift `HistogramMath.histMin`). */
export const HIST_MIN = 8;
/** High edge of the histogram window, µm (Swift `HistogramMath.histMax`). */
export const HIST_MAX = 60;

/**
 * Bucket the cells' diameters into the fixed 8–60 µm window. Values outside the
 * window are clamped into the first / last bucket (Swift `min/max` clamp). Port
 * of `HistogramMath.buckets(for:)`.
 */
export function histogramBuckets(cells: CellDTO[]): number[] {
  const out = new Array<number>(HIST_BUCKET_COUNT).fill(0);
  for (const c of cells) {
    const raw =
      ((c.diameterUm - HIST_MIN) / (HIST_MAX - HIST_MIN)) * HIST_BUCKET_COUNT;
    const i = Math.min(HIST_BUCKET_COUNT - 1, Math.max(0, Math.floor(raw)));
    out[i] += 1;
  }
  return out;
}

/**
 * The µm center of bucket `i` — used to pick that bar's size-bin color via
 * `binIndex`. Mirrors the Swift `center` computation in `DistributionPanel`.
 */
export function bucketCenterUm(i: number): number {
  return HIST_MIN + (i + 0.5) * ((HIST_MAX - HIST_MIN) / HIST_BUCKET_COUNT);
}
