/**
 * pages/compare/ConditionPanel.tsx — one pooled-condition card (feature
 * `feat-compare`).
 *
 * Port of `ConditionPanel` in `Views/Compare/CompareView.swift`: header dot +
 * name, pooled `n cells · k batches`, `mean ± σ µm`, the shared-axis histogram,
 * the per-bin breakdown bars, and the `% small / % intermediate / % large` mono
 * trio.
 *
 * Binning uses `binsFromThresholds` + `binIndex` from the kernel calibration
 * module. The `% small/intermediate/large` trio mirrors the Swift indexing:
 * small = bin 0, large = last bin, intermediate = bin 1 only when there are ≥3
 * bins (i.e. two thresholds).
 */

import type { PooledCondition } from "./comparePooling";
import { mean, stdDev, diametersOf } from "./comparePooling";
import {
  binsFromThresholds,
  binIndex,
} from "../../kernel/calibration/calibration";
import { binColor } from "./binColors";
import { PooledHistogram } from "./PooledHistogram";

interface ConditionPanelProps {
  pool: PooledCondition;
  /** Pre-bucketed histogram for this pool (from useCompareData). */
  buckets: number[];
  sharedYMax: number;
  thresholds: number[];
}

function pctOf(count: number, total: number): number {
  return total > 0 ? (count / total) * 100 : 0;
}

export function ConditionPanel({
  pool,
  buckets,
  sharedYMax,
  thresholds,
}: ConditionPanelProps) {
  const cells = pool.cells;
  const total = cells.length;
  const diameters = diametersOf(pool);
  const m = mean(diameters);
  const sd = stdDev(diameters);

  const bins = binsFromThresholds(thresholds);
  const binCounts = new Array<number>(bins.length).fill(0);
  for (const c of cells) {
    const idx = binIndex(c.diameterUm, thresholds);
    if (idx >= 0 && idx < binCounts.length) binCounts[idx] += 1;
  }

  const pctSmall = pctOf(binCounts[0] ?? 0, total);
  const pctLarge = pctOf(binCounts[bins.length - 1] ?? 0, total);
  const pctIntermediate =
    bins.length >= 3 ? pctOf(binCounts[1] ?? 0, total) : 0;

  return (
    <div className="cc-compare__panel">
      {/* header */}
      <div className="cc-compare__panel-head">
        <span
          className="cc-compare__dot cc-compare__dot--lg"
          style={{ background: pool.color }}
          aria-hidden="true"
        />
        <span className="cc-compare__panel-name">{pool.condition}</span>
      </div>

      {/* pooled stats */}
      <div className="cc-compare__panel-stats">
        <span className="cc-compare__mono">
          {total} cells · {pool.batches.length} batch
          {pool.batches.length === 1 ? "" : "es"}
        </span>
        <span className="cc-compare__mono cc-compare__mono--dim">
          {m.toFixed(1)} ± {sd.toFixed(1)} µm
        </span>
      </div>

      {/* histogram (shared Y axis) */}
      <PooledHistogram
        buckets={buckets}
        sharedYMax={sharedYMax}
        color={pool.color}
        thresholds={thresholds}
      />

      {/* bin breakdown */}
      <div className="cc-compare__bins">
        {bins.map((bin, i) => {
          const count = binCounts[i] ?? 0;
          const pct = pctOf(count, total);
          return (
            <div key={bin.label} className="cc-compare__binrow">
              <span
                className="cc-compare__swatch"
                style={{ background: binColor(i) }}
                aria-hidden="true"
              />
              <span className="cc-compare__binlabel">{bin.label}</span>
              <span className="cc-compare__bintrack">
                <span
                  className="cc-compare__binfill"
                  style={{ width: `${pct}%`, background: binColor(i) }}
                />
              </span>
              <span className="cc-compare__bincount">{count}</span>
            </div>
          );
        })}
      </div>

      {/* mono trio */}
      <div className="cc-compare__trio">
        <MonoStat label="% small" value={pctSmall} />
        <MonoStat label="% intermediate" value={pctIntermediate} />
        <MonoStat label="% large" value={pctLarge} />
      </div>
    </div>
  );
}

function MonoStat({ label, value }: { label: string; value: number }) {
  return (
    <div className="cc-compare__monostat">
      <span className="cc-compare__monostat-value">{value.toFixed(1)}%</span>
      <span className="cc-compare__monostat-label">{label}</span>
    </div>
  );
}
