/**
 * kernel/stats/stats.ts — pure, portable statistics (ARCHITECTURE.md §3.7).
 *
 * Direct port of `Services/Statistics.swift` (Mann–Whitney U, normal
 * approximation + continuity correction + rank-biserial) and
 * `Detection/AnnotationMatcher.swift` (greedy nearest-neighbour F1).
 *
 * No platform deps — runs identically in the desktop and the future WebGPU
 * browser build. All distance math is in SOURCE-PIXEL space.
 *
 * Numerics are frozen to match the Swift originals bit-for-bit where it matters
 * (labels, thresholds, continuity correction, tie-averaged ranks).
 */

import type {
  CompareResult,
  F1Score,
  GroundTruthDTO,
  CellDTO,
} from "../types";

// ===========================================================================
// erf — needed by normalCdf. Swift uses libm `erf`; JS has none, so we use the
// Abramowitz & Stegun 7.1.26 rational approximation (max abs error ~1.5e-7),
// which is more than enough for a two-tailed p-value.
// ===========================================================================

function erf(x: number): number {
  // erf(0) = 0 exactly — short-circuit so normalCdf(0) is exactly 0.5 and
  // twoTailedNormalP(0) is exactly 1.0 (the A&S polynomial leaves a ~1e-9
  // residual at 0 otherwise).
  if (x === 0) return 0;
  // Save the sign; erf is odd.
  const sign = x < 0 ? -1 : 1;
  const ax = Math.abs(x);

  // A&S 7.1.26 constants.
  const a1 = 0.254829592;
  const a2 = -0.284496736;
  const a3 = 1.421413741;
  const a4 = -1.453152027;
  const a5 = 1.061405429;
  const p = 0.3275911;

  const t = 1.0 / (1.0 + p * ax);
  const y =
    1.0 -
    ((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t * Math.exp(-ax * ax);
  return sign * y;
}

// ===========================================================================
// Mann–Whitney U (port of Services/Statistics.swift)
// ===========================================================================

/**
 * Standard normal CDF via erf: `0.5 * (1 + erf(x / √2))`.
 * (Swift: `Statistics.normalCDF`.)
 */
export function normalCdf(x: number): number {
  return 0.5 * (1.0 + erf(x / Math.SQRT2));
}

/**
 * Two-tailed p-value for a z-score under the standard normal, clamped to [0,1].
 * (Swift: `Statistics.twoTailedNormalP`.)
 */
export function twoTailedNormalP(z: number): number {
  const p = 2.0 * (1.0 - normalCdf(Math.abs(z)));
  return Math.min(1.0, Math.max(0.0, p));
}

/**
 * Arithmetic mean of a sample; 0 for an empty list. Matches the descriptive
 * mean the Swift `ExportService` summary, Batch view, and Compare panel report.
 */
export function mean(xs: number[]): number {
  if (xs.length === 0) return 0;
  let sum = 0;
  for (const x of xs) sum += x;
  return sum / xs.length;
}

/**
 * Population standard deviation (÷N, not ÷(N−1)) — the descriptive σ the Swift
 * `ExportService` summary, Batch view, and Compare panel all report. Returns 0
 * for an empty sample; a single-element sample yields 0 by construction (the one
 * deviation is 0), so the empty-guard is the only special case needed.
 */
export function stdDev(xs: number[]): number {
  if (xs.length === 0) return 0;
  const m = mean(xs);
  let acc = 0;
  for (const x of xs) {
    const d = x - m;
    acc += d * d;
  }
  return Math.sqrt(acc / xs.length);
}

/**
 * Median of a sample. Empty input ⇒ 0 (matches Swift's `guard !xs.isEmpty`).
 * Does not mutate the input.
 */
export function median(xs: number[]): number {
  if (xs.length === 0) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const n = s.length;
  if (n % 2 === 1) return s[(n - 1) / 2];
  return (s[n / 2 - 1] + s[n / 2]) / 2.0;
}

/** `significanceLabel` — matches `MannWhitneyResult.significanceLabel`. */
function significanceLabel(pValue: number): string {
  if (pValue < 0.001) return "p < 0.001 (***)";
  if (pValue < 0.01) return `p = ${pValue.toFixed(3)} (**)`;
  if (pValue < 0.05) return `p = ${pValue.toFixed(3)} (*)`;
  // >= 0.05
  return `p = ${pValue.toFixed(2)} (n.s.)`;
}

/** `effectSizeLabel` — matches `MannWhitneyResult.effectSizeLabel`. */
function effectSizeLabel(
  rankBiserial: number,
): CompareResult["effectSizeLabel"] {
  const r = Math.abs(rankBiserial);
  if (r < 0.1) return "negligible";
  if (r < 0.3) return "small";
  if (r < 0.5) return "medium";
  return "large";
}

/**
 * Mann–Whitney U test, two-tailed, normal approximation with continuity
 * correction + rank-biserial effect size. Returns `null` when either sample has
 * fewer than 3 elements (matches the Swift `guard a.count >= 3, b.count >= 3`).
 *
 * Formulas (from Statistics.swift):
 *   R1       = Σ ranks of group A   (ties averaged, 1-based)
 *   U1       = R1 − n1·(n1+1)/2
 *   U2       = n1·n2 − U1
 *   U_stat   = min(U1, U2)
 *   μ_U      = n1·n2 / 2
 *   σ_U      = √((n1·n2/12)·((n+1) − Σ(t³−t)/(n(n−1))))  (n=n1+n2; standard tie correction)
 *   z        = (U_stat − μ_U + 0.5) / σ_U  (continuity correction; U_stat ≤ μ_U)
 *   p_two    = 2·(1 − Φ(|z|))
 *   rB       = 1 − 2·U1 / (n1·n2)          (rank-biserial)
 */
export function mannWhitneyU(a: number[], b: number[]): CompareResult | null {
  if (a.length < 3 || b.length < 3) return null;
  const n1 = a.length;
  const n2 = b.length;

  // 1) Pool with origin labels, sort ascending, assign average ranks for ties.
  interface Pair {
    v: number;
    isA: boolean;
  }
  const pooled: Pair[] = [];
  for (const v of a) pooled.push({ v, isA: true });
  for (const v of b) pooled.push({ v, isA: false });
  pooled.sort((x, y) => x.v - y.v);

  const ranks = new Array<number>(pooled.length).fill(0);
  // Accumulate Σ(t³ − t) over tie-group sizes t for the tie correction.
  let tieCorrection = 0;
  let i = 0;
  while (i < pooled.length) {
    let j = i;
    while (j + 1 < pooled.length && pooled[j + 1].v === pooled[i].v) j += 1;
    // Tied positions [i..j] share the average 1-based rank.
    const avg = ((i + 1) + (j + 1)) / 2.0;
    for (let k = i; k <= j; k++) ranks[k] = avg;
    const t = j - i + 1;
    if (t > 1) tieCorrection += t * t * t - t;
    i = j + 1;
  }

  // 2) Sum of ranks for group A.
  let r1 = 0;
  for (let k = 0; k < pooled.length; k++) {
    if (pooled[k].isA) r1 += ranks[k];
  }

  const n1n2 = n1 * n2;
  const u1 = r1 - (n1 * (n1 + 1)) / 2.0;
  const u2 = n1n2 - u1;
  const uStat = Math.min(u1, u2);

  // 3) Normal approximation.
  const muU = n1n2 / 2.0;
  // Variance with the standard tie correction:
  //   σ_U = sqrt( (n1·n2/12) · ((n+1) − Σ(t³−t)/(n(n−1))) )
  // where the sum runs over tie-group sizes t and n = n1+n2. Reduces to the
  // untied sqrt(n1·n2·(n+1)/12) when there are no ties (tieCorrection == 0).
  const n = n1 + n2;
  const tieTerm = n > 1 ? tieCorrection / (n * (n - 1)) : 0;
  const sigmaU = Math.sqrt((n1n2 / 12.0) * ((n + 1) - tieTerm));

  const z = sigmaU > 0 ? (uStat - muU + 0.5) / sigmaU : 0;
  const p = twoTailedNormalP(z);

  const rB = 1.0 - (2.0 * u1) / n1n2;

  const m1 = median(a);
  const m2 = median(b);

  return {
    u: uStat,
    z,
    pValue: p,
    n1,
    n2,
    median1: m1,
    median2: m2,
    medianDifference: m2 - m1,
    rankBiserial: rB,
    significanceLabel: significanceLabel(p),
    effectSizeLabel: effectSizeLabel(rB),
  };
}

// ===========================================================================
// Greedy F1 (port of Detection/AnnotationMatcher.swift)
// ===========================================================================

/**
 * Greedy nearest-neighbour F1 between user ground-truth points and detections.
 * Distances are in SOURCE-PIXEL space (annotations + detections share the
 * coordinate system, so no scaling).
 *
 * Algorithm (from AnnotationMatcher.evaluate):
 *   1. For every (annotation, detection) pair, compute Euclidean distance.
 *      A candidate links them iff `dist ≤ matchRadiusFactor·max(det.diameterPx, 1)`.
 *   2. Sort candidates ascending by distance.
 *   3. Walk in order, claiming each annotation + detection at most once.
 *   TP = matched pairs, FP = unmatched detections, FN = unmatched annotations.
 *
 * Precision/recall/F1 are `null` when their denominator is 0, so callers can
 * render "—" instead of 0/0 (matches the Swift optional accessors).
 */
export function evaluateF1(
  annotations: GroundTruthDTO[],
  detections: CellDTO[],
  matchRadiusFactor: number = 1.0,
): F1Score {
  const score = (tp: number, fp: number, fn: number): F1Score => {
    const precDenom = tp + fp;
    const recDenom = tp + fn;
    const precision = precDenom > 0 ? tp / precDenom : null;
    const recall = recDenom > 0 ? tp / recDenom : null;
    let f1: number | null = null;
    if (precision !== null && recall !== null) {
      const denom = precision + recall;
      f1 = denom > 0 ? (2 * precision * recall) / denom : null;
    }
    return { tp, fp, fn, precision, recall, f1, matchRadiusFactor };
  };

  // Empty-input fast paths (match the Swift `Score` fast paths).
  if (annotations.length === 0) {
    return score(0, detections.length, 0);
  }
  if (detections.length === 0) {
    return score(0, 0, annotations.length);
  }

  interface Candidate {
    annIdx: number;
    detIdx: number;
    distance: number;
  }
  const candidates: Candidate[] = [];
  for (let ai = 0; ai < annotations.length; ai++) {
    const an = annotations[ai];
    for (let di = 0; di < detections.length; di++) {
      const d = detections[di];
      const dx = an.cx - d.cx;
      const dy = an.cy - d.cy;
      const dist = Math.sqrt(dx * dx + dy * dy);
      // Match window scales by EACH detection's own diameter (min 1px).
      const radius = matchRadiusFactor * Math.max(d.diameterPx, 1);
      if (dist <= radius) {
        candidates.push({ annIdx: ai, detIdx: di, distance: dist });
      }
    }
  }
  candidates.sort((x, y) => x.distance - y.distance);

  const claimedAnns = new Set<number>();
  const claimedDets = new Set<number>();
  let pairs = 0;
  for (const c of candidates) {
    if (claimedAnns.has(c.annIdx)) continue;
    if (claimedDets.has(c.detIdx)) continue;
    claimedAnns.add(c.annIdx);
    claimedDets.add(c.detIdx);
    pairs += 1;
  }

  const tp = pairs;
  const fp = detections.length - claimedDets.size;
  const fn = annotations.length - claimedAnns.size;
  return score(tp, fp, fn);
}
