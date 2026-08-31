import type { BatchAnalysis, BatchSummary, ComparisonResult } from "./types";

function mean(values: readonly number[]): number {
  return values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : 0;
}

function median(values: readonly number[]): number {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function standardDeviation(values: readonly number[]): number {
  if (!values.length) return 0;
  const average = mean(values);
  return Math.sqrt(mean(values.map((value) => (value - average) ** 2)));
}

function erf(value: number): number {
  const sign = value < 0 ? -1 : 1;
  const x = Math.abs(value);
  const t = 1 / (1 + 0.3275911 * x);
  const polynomial =
    (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t;
  return sign * (1 - polynomial * Math.exp(-x * x));
}

function twoTailedNormalP(z: number): number {
  return Math.max(0, Math.min(1, 1 - erf(Math.abs(z) / Math.SQRT2)));
}

function mannWhitney(first: readonly number[], second: readonly number[]): ComparisonResult["mannWhitney"] {
  if (first.length < 3 || second.length < 3) return null;
  const pooled = [
    ...first.map((value) => ({ value, first: true })),
    ...second.map((value) => ({ value, first: false })),
  ].sort((a, b) => a.value - b.value);
  const ranks = new Array<number>(pooled.length);
  let tieCorrection = 0;
  for (let index = 0; index < pooled.length; ) {
    let end = index + 1;
    while (end < pooled.length && pooled[end].value === pooled[index].value) end += 1;
    const averageRank = (index + 1 + end) / 2;
    ranks.fill(averageRank, index, end);
    const tieSize = end - index;
    tieCorrection += tieSize ** 3 - tieSize;
    index = end;
  }
  const n1 = first.length;
  const n2 = second.length;
  const u1 = pooled.reduce((sum, item, index) => sum + (item.first ? ranks[index] : 0), 0) - (n1 * (n1 + 1)) / 2;
  const u2 = n1 * n2 - u1;
  const u = Math.min(u1, u2);
  const n = n1 + n2;
  const variance = (n1 * n2 / 12) * (n + 1 - tieCorrection / (n * (n - 1)));
  const z = variance > 0 ? (u - n1 * n2 / 2 + 0.5) / Math.sqrt(variance) : 0;
  return {
    u,
    z,
    pValue: twoTailedNormalP(z),
    medianDifferenceUm: median(second) - median(first),
    rankBiserial: 1 - (2 * u1) / (n1 * n2),
  };
}

export function summarizeBatch(batch: BatchAnalysis, thresholdsUm: readonly number[]): BatchSummary {
  const cells = batch.analyses.flatMap((analysis) => analysis.cells);
  const diameters = cells.map((cell) => cell.equivalentDiameterUm);
  const sortedThresholds = [...thresholdsUm].sort((a, b) => a - b);
  const bins = new Array(sortedThresholds.length + 1).fill(0) as number[];
  for (const diameter of diameters) {
    const found = sortedThresholds.findIndex((threshold) => diameter < threshold);
    bins[found < 0 ? bins.length - 1 : found] += 1;
  }
  return {
    batchId: batch.id,
    condition: batch.condition,
    imageCount: batch.analyses.length,
    cellCount: cells.length,
    meanDiameterUm: mean(diameters),
    medianDiameterUm: median(diameters),
    standardDeviationUm: standardDeviation(diameters),
    meanAreaUm2: mean(cells.map((cell) => cell.areaUm2)),
    binCounts: bins,
  };
}

export interface LightweightComparisonGroup {
  readonly id: string;
  readonly condition: string;
  readonly imageCount: number;
  readonly cells: readonly { readonly diameterUm: number; readonly areaUm2: number }[];
}

/** Batch comparison from geometry-free persisted summaries. */
export function compareCellGroups(inputs: readonly LightweightComparisonGroup[], thresholdsUm: readonly number[]): ComparisonResult {
  const ordered = [...inputs].sort((a, b) => a.id.localeCompare(b.id));
  const sortedThresholds = [...thresholdsUm].sort((a, b) => a - b);
  const groups = ordered.map((input): BatchSummary => {
    const diameters = input.cells.map((cell) => cell.diameterUm);
    const bins = new Array(sortedThresholds.length + 1).fill(0) as number[];
    for (const diameter of diameters) {
      const found = sortedThresholds.findIndex((threshold) => diameter < threshold);
      bins[found < 0 ? bins.length - 1 : found] += 1;
    }
    return {
      batchId: input.id, condition: input.condition, imageCount: input.imageCount,
      cellCount: input.cells.length, meanDiameterUm: mean(diameters), medianDiameterUm: median(diameters),
      standardDeviationUm: standardDeviation(diameters), meanAreaUm2: mean(input.cells.map((cell) => cell.areaUm2)), binCounts: bins,
    };
  });
  const test = ordered.length === 2 ? mannWhitney(
    ordered[0].cells.map((cell) => cell.diameterUm),
    ordered[1].cells.map((cell) => cell.diameterUm),
  ) : null;
  return { groups, mannWhitney: test };
}

export function compareBatches(batches: readonly BatchAnalysis[], thresholdsUm: readonly number[]): ComparisonResult {
  return compareCellGroups(batches.map((batch) => ({
    id: batch.id, condition: batch.condition, imageCount: batch.analyses.length,
    cells: batch.analyses.flatMap((analysis) => analysis.cells.map((cell) => ({ diameterUm: cell.equivalentDiameterUm, areaUm2: cell.areaUm2 }))),
  })), thresholdsUm);
}
