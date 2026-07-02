/**
 * pages/compare/MannWhitneyPanel.tsx — pairwise Mann–Whitney U panel (feature
 * `feat-compare`).
 *
 * Port of `MannWhitneyPanel` / `StatsBody` in `Views/Compare/CompareView.swift`.
 * Shown ONLY when exactly two conditions are selected (the page gates on this).
 * Pools each condition's cell diameters and runs the two-tailed Mann–Whitney U
 * test — the math is the FROZEN kernel `mannWhitneyU` (§3.7); this panel never
 * re-implements the statistics.
 *
 * `mannWhitneyU` returns `null` when either group has < 3 values, which is the
 * same guard the Swift panel applies before showing "Not enough data for
 * statistical comparison".
 */

import { mannWhitneyU } from "../../kernel/stats/stats";
import type { PooledCondition } from "./comparePooling";
import { diametersOf } from "./comparePooling";

interface MannWhitneyPanelProps {
  /** Exactly two pools (the page guarantees length 2 before mounting). */
  a: PooledCondition;
  b: PooledCondition;
}

/** `+%.1f µm` style signed format, matching the Swift `%+.1f`. */
function signed1(v: number): string {
  const s = v.toFixed(1);
  return v >= 0 ? `+${s}` : s;
}

function signed2(v: number): string {
  const s = v.toFixed(2);
  return v >= 0 ? `+${s}` : s;
}

export function MannWhitneyPanel({ a, b }: MannWhitneyPanelProps) {
  const da = diametersOf(a);
  const db = diametersOf(b);
  const result = mannWhitneyU(da, db);

  return (
    <div className="cc-compare__mw">
      <div className="cc-compare__mw-head">
        <span className="cc-compare__mw-title">COMPARISON</span>
        <span className="cc-compare__mw-sub">Mann–Whitney U test</span>
      </div>

      {result === null ? (
        <div className="cc-compare__mw-empty">
          Not enough data for statistical comparison
        </div>
      ) : (
        (() => {
          const significant = result.pValue < 0.05;
          return (
            <div className="cc-compare__mw-body">
              {/* per-group rows */}
              <GroupRow
                label="Batch A"
                name={a.condition}
                color={a.color}
                n={result.n1}
                median={result.median1}
              />
              <GroupRow
                label="Batch B"
                name={b.condition}
                color={b.color}
                n={result.n2}
                median={result.median2}
              />

              <div className="cc-compare__mw-mediandiff">
                <span className="cc-compare__mw-mediandiff-label">
                  Median difference
                </span>
                <span className="cc-compare__mono cc-compare__mono--strong">
                  {signed1(result.medianDifference)} µm
                </span>
              </div>

              <div className="cc-compare__mw-divider" />

              {/* U / z / significance triplet */}
              <div className="cc-compare__mw-stats">
                <StatCell label="U" value={result.u.toFixed(0)} />
                <StatCell label="z" value={result.z.toFixed(2)} />
                <div className="cc-compare__mw-sig">
                  <span
                    className={
                      "cc-compare__dot " +
                      (significant
                        ? "cc-compare__dot--sig"
                        : "cc-compare__dot--nsig")
                    }
                    aria-hidden="true"
                  />
                  <div className="cc-compare__mw-sig-text">
                    <span className="cc-compare__mono cc-compare__mono--strong">
                      {result.significanceLabel}
                    </span>
                    <span className="cc-compare__mw-sig-caption">
                      two-tailed
                    </span>
                  </div>
                </div>
              </div>

              <div className="cc-compare__mw-effect">
                <span className="cc-compare__mono cc-compare__mono--dim">
                  Effect size r = {signed2(result.rankBiserial)}
                </span>
                <span className="cc-compare__mw-effect-label">
                  ({result.effectSizeLabel})
                </span>
              </div>
            </div>
          );
        })()
      )}
    </div>
  );
}

function GroupRow({
  label,
  name,
  color,
  n,
  median,
}: {
  label: string;
  name: string;
  color: string;
  n: number;
  median: number;
}) {
  return (
    <div className="cc-compare__mw-grouprow">
      <span className="cc-compare__mw-grouplabel">{label}</span>
      <span
        className="cc-compare__dot"
        style={{ background: color }}
        aria-hidden="true"
      />
      <span className="cc-compare__mw-groupname">{name}</span>
      <span className="cc-compare__mono cc-compare__mono--dim">
        n = {n} cells
      </span>
      <span className="cc-compare__mono cc-compare__mono--dim cc-compare__mw-groupmedian">
        median {median.toFixed(1)} µm
      </span>
    </div>
  );
}

function StatCell({ label, value }: { label: string; value: string }) {
  return (
    <div className="cc-compare__mw-statcell">
      <span className="cc-compare__mono cc-compare__mono--strong">{value}</span>
      <span className="cc-compare__mw-statcell-label">{label}</span>
    </div>
  );
}
