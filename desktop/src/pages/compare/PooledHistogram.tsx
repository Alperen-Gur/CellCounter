/**
 * pages/compare/PooledHistogram.tsx — one condition's pooled diameter histogram
 * (feature `feat-compare`).
 *
 * Port of `PooledHistogram` in `Views/Compare/CompareView.swift`. Draws the
 * 24-bucket 8–60 µm histogram in the condition's plot color, scaled to a Y-axis
 * maximum SHARED across all panels (so bar heights are comparable between
 * conditions). Threshold values are drawn as small tick labels under the bars.
 *
 * The bars are colored by the condition, not by size bin — matching the Swift
 * original (the per-bin coloring lives in the bin-breakdown rows below the
 * histogram, drawn by ConditionPanel).
 */

import {
  HIST_BUCKET_COUNT,
  HIST_MIN,
  HIST_MAX,
} from "./histogram";

/** Fixed plot height in px (Swift used a 70pt bar area). */
const BAR_AREA_PX = 70;

interface PooledHistogramProps {
  /** Pre-bucketed counts (length `HIST_BUCKET_COUNT`). */
  buckets: number[];
  /** Shared Y-axis maximum across all panels (≥1). */
  sharedYMax: number;
  /** This condition's plot color (hex). */
  color: string;
  /** Size thresholds (µm) rendered as ticks. */
  thresholds: number[];
}

export function PooledHistogram({
  buckets,
  sharedYMax,
  color,
  thresholds,
}: PooledHistogramProps) {
  return (
    <div className="cc-compare__hist">
      <div className="cc-compare__hist-head">
        <span className="cc-compare__hist-title">DIAMETER</span>
        <span className="cc-compare__hist-range">
          {HIST_MIN} – {HIST_MAX} µm
        </span>
      </div>

      <div
        className="cc-compare__hist-bars"
        style={{ height: `${BAR_AREA_PX}px` }}
      >
        {Array.from({ length: HIST_BUCKET_COUNT }, (_, i) => {
          const h = buckets[i] ?? 0;
          // Fraction of the shared axis; give any non-empty bucket a minimum
          // visible sliver (2/70), exactly like the Swift `max(…, h>0 ? 2/70:0)`.
          const frac =
            sharedYMax > 0
              ? Math.max(h / sharedYMax, h > 0 ? 2 / BAR_AREA_PX : 0)
              : 0;
          return (
            <div
              key={i}
              className="cc-compare__hist-bar"
              style={{
                height: `${BAR_AREA_PX * frac}px`,
                background: color,
              }}
              title={`${h}`}
            />
          );
        })}
      </div>

      <div className="cc-compare__hist-ticks" aria-hidden="true">
        {thresholds.map((t, i) => {
          const raw = (t - HIST_MIN) / (HIST_MAX - HIST_MIN);
          const pos = Math.min(0.98, Math.max(0.02, raw));
          return (
            <span
              key={i}
              className="cc-compare__hist-tick"
              style={{ left: `${pos * 100}%` }}
            >
              {Math.round(t)}
            </span>
          );
        })}
      </div>
    </div>
  );
}
