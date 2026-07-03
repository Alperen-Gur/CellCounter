/**
 * kernel/stats/histogram.ts — the fixed size-distribution histogram math.
 *
 * Direct port of `HistogramMath` (declared in `Views/Compare/CompareView.swift`
 * and shared by the Results `DistributionPanel`). A fixed 24-bucket histogram
 * over a fixed 8–60 µm diameter window, so bars line up ACROSS the Results
 * distribution panel and the Compare pooled histogram.
 *
 * This is the single source of truth for the window + bucketing: both the
 * Results sidebar and the Compare screen import `HIST_*` / `histogramBuckets`
 * from here, so the fixed window can never drift between the two views. Pure —
 * no React, no I/O, no ports.
 */

import type { CellDTO } from "../types";

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

/**
 * The shared Y-axis maximum across a set of already-bucketed histograms. At
 * least 1 so an all-empty comparison still renders a valid (flat) axis. Mirrors
 * `PanelsScroll.sharedYMax` in CompareView.
 *
 * Sharing one Y max across panels is the whole point of the Compare view — you
 * cannot eyeball two histograms drawn on independent Y-axes.
 */
export function sharedYMaxOf(bucketsPerCondition: number[][]): number {
  let m = 1;
  for (const buckets of bucketsPerCondition) {
    for (const h of buckets) if (h > m) m = h;
  }
  return m;
}
