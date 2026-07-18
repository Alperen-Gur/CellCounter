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
 *
 * Generalized beyond diameter to any per-cell morphology metric (circularity,
 * aspect ratio, solidity, area) via an OPTIONAL `metric` parameter — see
 * `HistogramMetric` / `METRIC_SPECS` below. `histogramBuckets(cells)` with no
 * second argument keeps bucketing `diameterUm` over the original 8–60 µm / 24
 * -bucket window, so every existing caller (Compare's `useCompareData`, the
 * Results `DistributionPanel`) is unaffected unless it opts in.
 */

import type { CellDTO } from "../types";

/** Number of histogram buckets (Swift `HistogramMath.bucketCount`) — diameter's. */
export const HIST_BUCKET_COUNT = 24;
/** Low edge of the histogram window, µm (Swift `HistogramMath.histMin`). */
export const HIST_MIN = 8;
/** High edge of the histogram window, µm (Swift `HistogramMath.histMax`). */
export const HIST_MAX = 60;

/** Per-cell morphology metrics the Results distribution histogram can plot. */
export type HistogramMetric =
  | "diameter"
  | "circularity"
  | "aspectRatio"
  | "solidity"
  | "area";

/** Ordered list for building a metric picker UI (labels via `METRIC_SPECS`). */
export const HISTOGRAM_METRICS: readonly HistogramMetric[] = [
  "diameter",
  "circularity",
  "aspectRatio",
  "solidity",
  "area",
];

interface MetricSpec {
  min: number;
  max: number;
  bucketCount: number;
  /** Display unit, "" when the metric is a dimensionless ratio. */
  unit: string;
  /** Human label for the picker / panel header. */
  label: string;
  /** Suggested decimal places for range/tick formatting. */
  decimals: number;
  /** Reads the metric off a cell; undefined/non-finite ⇒ excluded from the histogram. */
  accessor: (c: CellDTO) => number | undefined;
}

/**
 * Fixed range + accessor per supported metric. `diameter` mirrors the
 * `HIST_MIN` / `HIST_MAX` / `HIST_BUCKET_COUNT` constants exactly — those stay
 * exported separately (and this table reads them, not a duplicate literal)
 * because `PooledHistogram` (Compare) still imports the constants directly for
 * its diameter-only axis and must never drift from this table's window.
 *
 * Ranges for the other metrics are fixed, sensible windows for cultured-cell
 * morphology, not derived from the data: circularity/solidity are shape-factor
 * ratios in [0,1]; aspect ratio runs 1 (circular) up to ~5 (very elongated);
 * area's 0–3000 µm² window brackets the diameter window's implied area range
 * (π·(60/2)² ≈ 2827 µm²).
 */
const METRIC_SPECS: Record<HistogramMetric, MetricSpec> = {
  diameter: {
    min: HIST_MIN,
    max: HIST_MAX,
    bucketCount: HIST_BUCKET_COUNT,
    unit: "µm",
    label: "Diameter",
    decimals: 0,
    accessor: (c) => c.diameterUm,
  },
  circularity: {
    min: 0,
    max: 1,
    bucketCount: 20,
    unit: "",
    label: "Circularity",
    decimals: 2,
    accessor: (c) => c.circularity,
  },
  aspectRatio: {
    min: 1,
    max: 5,
    bucketCount: 20,
    unit: "",
    label: "Aspect ratio",
    decimals: 1,
    accessor: (c) => c.aspectRatio,
  },
  solidity: {
    min: 0,
    max: 1,
    bucketCount: 20,
    unit: "",
    label: "Solidity",
    decimals: 2,
    accessor: (c) => c.solidity,
  },
  area: {
    min: 0,
    max: 3000,
    bucketCount: 24,
    unit: "µm²",
    label: "Area",
    decimals: 0,
    accessor: (c) => c.areaUm2,
  },
};

/** Display metadata for a metric's fixed window (range/unit/label/decimals). */
export function histogramRange(metric: HistogramMetric = "diameter"): {
  min: number;
  max: number;
  bucketCount: number;
  unit: string;
  label: string;
  decimals: number;
} {
  const { min, max, bucketCount, unit, label, decimals } = METRIC_SPECS[metric];
  return { min, max, bucketCount, unit, label, decimals };
}

/**
 * Bucket the cells' chosen metric into that metric's fixed window. Values
 * outside the window are clamped into the first / last bucket (Swift
 * `min/max` clamp, port of `HistogramMath.buckets(for:)`). Cells missing the
 * metric (optional per-cell measurement, e.g. `circularity` on a manual
 * marker) are skipped rather than clamped.
 *
 * `metric` defaults to `"diameter"` — the original required, always-finite
 * field — so the signature and behavior are backward-compatible for every
 * existing caller.
 */
export function histogramBuckets(
  cells: CellDTO[],
  metric: HistogramMetric = "diameter",
): number[] {
  const spec = METRIC_SPECS[metric];
  const { min, max, bucketCount, accessor } = spec;
  const span = max - min;
  const out = new Array<number>(bucketCount).fill(0);
  for (const c of cells) {
    const v = accessor(c);
    if (v === undefined || v === null || !Number.isFinite(v)) continue;
    const raw = ((v - min) / span) * bucketCount;
    const i = Math.min(bucketCount - 1, Math.max(0, Math.floor(raw)));
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
