/**
 * pages/compare/histogram.ts — pooled-histogram math for the Compare screen
 * (feature `feat-compare`).
 *
 * Direct port of `HistogramMath` as declared in `Views/Compare/CompareView.swift`
 * (the Swift original defines it *inside* CompareView and shares it with the
 * Results DistributionPanel). Fixed 24-bucket histogram over a fixed 8–60 µm
 * diameter window so bars line up across conditions AND across the Results
 * distribution panel.
 *
 * This is intentionally a local copy of the same constants used by
 * `pages/results/histogram.ts` — this task owns only `pages/compare/` and must
 * not import a sibling page's module. The Swift source of truth is the same
 * `HistogramMath` enum, so the two copies are byte-for-byte identical by design;
 * if the kernel later hoists `HistogramMath`, both collapse to a re-export.
 *
 * Pure — no React, no I/O, no ports.
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
