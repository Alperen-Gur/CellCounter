/**
 * pages/batch/SizeDistBar.tsx — the per-row size-class mini-distribution.
 *
 * Renders a compact segmented bar of the cell counts per size bin, aligned 1:1
 * with `binsFromThresholds(thresholds)`. Bin colors reuse the shell's size-bin
 * tokens (small / mid / large) and cycle for any extra interior bins. Purely
 * presentational — the counts come from `batchStats.binCountsFor`.
 */

import { binsFromThresholds } from "../../kernel/calibration/calibration";

/** Size-bin palette (shell tokens). Cycles if there are more than 3 bins. */
const BIN_COLORS = [
  "var(--cc-bin-small)",
  "var(--cc-bin-mid)",
  "var(--cc-bin-large)",
];

export function binColor(index: number): string {
  return BIN_COLORS[index % BIN_COLORS.length];
}

interface SizeDistBarProps {
  binCounts: number[];
  thresholds: number[];
}

export function SizeDistBar({ binCounts, thresholds }: SizeDistBarProps) {
  const bins = binsFromThresholds(thresholds);
  const total = binCounts.reduce((a, b) => a + b, 0);

  if (binCounts.length === 0 || total === 0) {
    return <span className="cc-batch__dist-empty">—</span>;
  }

  return (
    <div
      className="cc-batch__dist"
      role="img"
      aria-label={bins
        .map((b, i) => `${b.label}: ${binCounts[i] ?? 0}`)
        .join(", ")}
    >
      <div className="cc-batch__dist-bar">
        {bins.map((b, i) => {
          const count = binCounts[i] ?? 0;
          const pct = (count / total) * 100;
          if (count === 0) return null;
          return (
            <span
              key={b.label}
              className="cc-batch__dist-seg"
              style={{ width: `${pct}%`, background: binColor(i) }}
              title={`${b.label}: ${count}`}
            />
          );
        })}
      </div>
      <div className="cc-batch__dist-legend">
        {bins.map((b, i) => {
          const count = binCounts[i] ?? 0;
          return (
            <span key={b.label} className="cc-batch__dist-chip" title={b.label}>
              <span
                className="cc-batch__dist-swatch"
                style={{ background: binColor(i) }}
                aria-hidden="true"
              />
              {count}
            </span>
          );
        })}
      </div>
    </div>
  );
}
