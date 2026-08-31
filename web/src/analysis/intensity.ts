import { mean, median, otsuThreshold, percentile, sampleStandardDeviation } from "./math";
import { assertAligned, type LabelMap, type Raster } from "./types";

export type IntensityMetric = "mean" | "integrated" | "median";

export interface ChannelStatistic {
  readonly channel: number;
  readonly mean: number;
  readonly integrated: number;
  /** Null unless exact medians were explicitly requested. */
  readonly median: number | null;
}

export interface CellIntensity {
  readonly label: number;
  readonly areaPx: number;
  readonly channels: readonly ChannelStatistic[];
}

function requireChannel(image: Raster, channel: number): void {
  if (!Number.isInteger(channel) || channel < 0 || channel >= image.channels) {
    throw new RangeError(`Channel ${channel} is outside this ${image.channels}-channel raster.`);
  }
}

function channelValue(cell: CellIntensity, channel: number, metric: IntensityMetric): number | null {
  const entry = cell.channels.find((candidate) => candidate.channel === channel);
  if (!entry) return null;
  return metric === "median" ? entry.median ?? entry.mean : entry[metric];
}

/**
 * One source-pixel pass with O(cellCount × channelCount) default memory.
 * Exact medians retain per-cell pixel values and are opt-in; dispatch that
 * mode to a Worker for large microscopy images.
 */
export function measureCellIntensities(labels: LabelMap, image: Raster, options: { readonly includeMedian?: boolean; readonly signal?: AbortSignal } = {}): CellIntensity[] {
  assertAligned(labels, image);
  interface Accumulator { areaPx: number; sums: Float64Array; values: number[][] | null }
  const accumulators = new Map<number, Accumulator>();
  for (let index = 0; index < labels.data.length; index += 1) {
    if ((index & 0xffff) === 0) options.signal?.throwIfAborted();
    const label = labels.data[index];
    if (!label) continue;
    let accumulator = accumulators.get(label);
    if (!accumulator) {
      accumulator = { areaPx: 0, sums: new Float64Array(image.channels), values: options.includeMedian ? Array.from({ length: image.channels }, () => []) : null };
      accumulators.set(label, accumulator);
    }
    accumulator.areaPx += 1;
    for (let channel = 0; channel < image.channels; channel += 1) {
      const value = Number(image.data[index * image.channels + channel]);
      accumulator.sums[channel] += value;
      accumulator.values?.[channel].push(value);
    }
  }
  return [...accumulators.entries()].sort(([a], [b]) => a - b).map(([label, accumulator]) => ({
    label,
    areaPx: accumulator.areaPx,
    channels: Array.from({ length: image.channels }, (_, channel) => {
      const integrated = accumulator.sums[channel];
      return { channel, integrated, mean: integrated / accumulator.areaPx, median: accumulator.values ? median(accumulator.values[channel]) : null };
    }),
  }));
}

export type ThresholdSpec =
  | { readonly mode: "manual"; readonly value: number }
  | { readonly mode: "otsu" }
  | { readonly mode: "negative-control-sd"; readonly negativeValues: readonly number[]; readonly k?: number };

export interface PositivityResult {
  readonly threshold: number;
  readonly thresholdMode: ThresholdSpec["mode"];
  readonly cellCount: number;
  readonly positiveCount: number;
  readonly negativeCount: number;
  readonly percentPositive: number;
  readonly meanPositive: number | null;
  readonly meanNegative: number | null;
  readonly perCell: readonly { label: number; value: number; positive: boolean }[];
}

function resolveThreshold(values: readonly number[], spec: ThresholdSpec): number {
  if (spec.mode === "manual") {
    if (!Number.isFinite(spec.value)) throw new RangeError("Manual threshold must be finite.");
    return spec.value;
  }
  if (spec.mode === "negative-control-sd") {
    const negative = spec.negativeValues.filter(Number.isFinite);
    if (negative.length < 2) throw new RangeError("Negative-control thresholding needs at least two control values.");
    return mean(negative)! + (spec.k ?? 3) * sampleStandardDeviation(negative)!;
  }
  const threshold = otsuThreshold(values);
  if (threshold === null) throw new RangeError("Otsu threshold is undefined for an empty or constant population; choose a manual threshold.");
  return threshold;
}

export function markerPositivity(
  cells: readonly CellIntensity[],
  options: { readonly channel: number; readonly metric?: IntensityMetric; readonly threshold: ThresholdSpec },
): PositivityResult {
  const metric = options.metric ?? "mean";
  const measured = cells.map((cell) => ({ label: cell.label, value: channelValue(cell, options.channel, metric) }))
    .filter((entry): entry is { label: number; value: number } => entry.value !== null && Number.isFinite(entry.value));
  if (!measured.length) throw new RangeError("No cells contain the requested channel measurement.");
  const threshold = resolveThreshold(measured.map(({ value }) => value), options.threshold);
  const perCell = measured.map(({ label, value }) => ({ label, value, positive: value > threshold }));
  const positive = perCell.filter((entry) => entry.positive).map((entry) => entry.value);
  const negative = perCell.filter((entry) => !entry.positive).map((entry) => entry.value);
  return {
    threshold,
    thresholdMode: options.threshold.mode,
    cellCount: perCell.length,
    positiveCount: positive.length,
    negativeCount: negative.length,
    percentPositive: positive.length * 100 / perCell.length,
    meanPositive: mean(positive),
    meanNegative: mean(negative),
    perCell,
  };
}

/** Named presentation of the same per-cell threshold statistic. */
export function transfectionEfficiency(
  cells: readonly CellIntensity[],
  options: { readonly channel: number; readonly metric?: IntensityMetric; readonly threshold: ThresholdSpec },
): PositivityResult & { readonly percentTransfected: number } {
  const result = markerPositivity(cells, options);
  return { ...result, percentTransfected: result.percentPositive };
}

export interface ViabilityResult {
  readonly liveThreshold: number;
  readonly deadThreshold: number;
  readonly cellCount: number;
  readonly liveCount: number;
  readonly deadCount: number;
  readonly unlabelledCount: number;
  readonly doublePositiveCount: number;
  readonly percentViable: number;
  readonly percentViableOfAll: number;
  readonly perCell: readonly { label: number; state: "live" | "dead" | "unlabelled"; doublePositive: boolean }[];
}

export function viability(
  cells: readonly CellIntensity[],
  options: {
    readonly liveChannel: number;
    readonly deadChannel: number;
    readonly metric?: IntensityMetric;
    readonly liveThreshold: ThresholdSpec;
    readonly deadThreshold: ThresholdSpec;
  },
): ViabilityResult {
  if (options.liveChannel === options.deadChannel) throw new RangeError("Live and dead channels must differ.");
  const metric = options.metric ?? "mean";
  const paired = cells.map((cell) => ({
    label: cell.label,
    live: channelValue(cell, options.liveChannel, metric),
    dead: channelValue(cell, options.deadChannel, metric),
  })).filter((entry): entry is { label: number; live: number; dead: number } => entry.live !== null && entry.dead !== null);
  if (!paired.length) throw new RangeError("No cells have both requested channel measurements.");
  const liveThreshold = resolveThreshold(paired.map(({ live }) => live), options.liveThreshold);
  const deadThreshold = resolveThreshold(paired.map(({ dead }) => dead), options.deadThreshold);
  const perCell = paired.map(({ label, live, dead }) => {
    const livePositive = live > liveThreshold;
    const deadPositive = dead > deadThreshold;
    return {
      label,
      state: (deadPositive ? "dead" : livePositive ? "live" : "unlabelled") as "live" | "dead" | "unlabelled",
      doublePositive: livePositive && deadPositive,
    };
  });
  const liveCount = perCell.filter(({ state }) => state === "live").length;
  const deadCount = perCell.filter(({ state }) => state === "dead").length;
  const denominator = liveCount + deadCount;
  return {
    liveThreshold,
    deadThreshold,
    cellCount: perCell.length,
    liveCount,
    deadCount,
    unlabelledCount: perCell.length - liveCount - deadCount,
    doublePositiveCount: perCell.filter(({ doublePositive }) => doublePositive).length,
    percentViable: denominator ? liveCount * 100 / denominator : 0,
    percentViableOfAll: liveCount * 100 / perCell.length,
    perCell,
  };
}

export interface NuclearCytoplasmicResult {
  readonly channel: number;
  readonly cellCount: number;
  readonly skippedCount: number;
  readonly meanRatio: number;
  readonly medianRatio: number;
  readonly sdRatio: number;
  readonly perCell: readonly {
    label: number;
    nuclear: number;
    cytoplasmic: number;
    ratio: number;
    nuclearPx: number;
    cytoplasmicPx: number;
  }[];
  readonly definition: string;
}

export function nuclearCytoplasmicRatio(
  cellLabels: LabelMap,
  nuclearMask: LabelMap,
  image: Raster,
  options: { readonly channel: number; readonly metric?: "mean" | "median"; readonly minNuclearPx?: number; readonly minCytoplasmicPx?: number; readonly signal?: AbortSignal },
): NuclearCytoplasmicResult {
  assertAligned(cellLabels, image);
  if (nuclearMask.width !== cellLabels.width || nuclearMask.height !== cellLabels.height) throw new RangeError("Nuclear and cell masks must align.");
  requireChannel(image, options.channel);
  interface CompartmentAccumulator { nuclearSum: number; cytoplasmicSum: number; nuclearCount: number; cytoplasmicCount: number; nuclearValues: number[] | null; cytoplasmicValues: number[] | null }
  const exactMedian = options.metric === "median";
  const byLabel = new Map<number, CompartmentAccumulator>();
  for (let index = 0; index < cellLabels.data.length; index += 1) {
    if ((index & 0xffff) === 0) options.signal?.throwIfAborted();
    const label = cellLabels.data[index];
    if (!label) continue;
    let parts = byLabel.get(label);
    if (!parts) {
      parts = { nuclearSum: 0, cytoplasmicSum: 0, nuclearCount: 0, cytoplasmicCount: 0, nuclearValues: exactMedian ? [] : null, cytoplasmicValues: exactMedian ? [] : null };
      byLabel.set(label, parts);
    }
    const value = Number(image.data[index * image.channels + options.channel]);
    if (nuclearMask.data[index]) { parts.nuclearSum += value; parts.nuclearCount += 1; parts.nuclearValues?.push(value); }
    else { parts.cytoplasmicSum += value; parts.cytoplasmicCount += 1; parts.cytoplasmicValues?.push(value); }
  }
  const minNucleus = options.minNuclearPx ?? 4;
  const minCytoplasm = options.minCytoplasmicPx ?? 4;
  let skippedCount = 0;
  const perCell = [...byLabel.entries()].sort(([a], [b]) => a - b).flatMap(([label, parts]) => {
    if (parts.nuclearCount < minNucleus || parts.cytoplasmicCount < minCytoplasm) { skippedCount += 1; return []; }
    const nuclear = exactMedian ? median(parts.nuclearValues!)! : parts.nuclearSum / parts.nuclearCount;
    const cytoplasmic = exactMedian ? median(parts.cytoplasmicValues!)! : parts.cytoplasmicSum / parts.cytoplasmicCount;
    if (!(cytoplasmic > 0)) { skippedCount += 1; return []; }
    return [{ label, nuclear, cytoplasmic, ratio: nuclear / cytoplasmic, nuclearPx: parts.nuclearCount, cytoplasmicPx: parts.cytoplasmicCount }];
  });
  if (!perCell.length) throw new RangeError("No cell has measurable nuclear and cytoplasmic compartments.");
  const ratios = perCell.map(({ ratio }) => ratio);
  return {
    channel: options.channel,
    cellCount: perCell.length,
    skippedCount,
    meanRatio: mean(ratios)!,
    medianRatio: median(ratios)!,
    sdRatio: sampleStandardDeviation(ratios) ?? 0,
    perCell,
    definition: `cytoplasm = cell mask minus nuclear mask; ratio = ${options.metric ?? "mean"} nuclear / cytoplasmic intensity`,
  };
}

interface ColocalizationScope { readonly pearson: number | null; readonly mandersM1: number | null; readonly mandersM2: number | null; readonly pixelCount: number }
export interface ColocalizationResult {
  readonly channelA: number;
  readonly channelB: number;
  readonly thresholds: { readonly mode: "manual" | "otsu" | "zero"; readonly scope: "image" | "in-cells"; readonly a: number; readonly b: number; readonly note: string };
  readonly image: ColocalizationScope;
  readonly inCells: ColocalizationScope | null;
  readonly perCell: readonly (ColocalizationScope & { readonly label: number })[];
  readonly perCellMeanPearson: number | null;
}

interface ColocalizationAccumulator { count: number; sumA: number; sumB: number; sumAA: number; sumBB: number; sumAB: number; positiveA: number; positiveB: number; coincidentA: number; coincidentB: number }
function newColocalizationAccumulator(): ColocalizationAccumulator { return { count: 0, sumA: 0, sumB: 0, sumAA: 0, sumBB: 0, sumAB: 0, positiveA: 0, positiveB: 0, coincidentA: 0, coincidentB: 0 }; }
function addColocalization(accumulator: ColocalizationAccumulator, a: number, b: number, thresholdA: number, thresholdB: number): void {
  accumulator.count += 1; accumulator.sumA += a; accumulator.sumB += b; accumulator.sumAA += a * a; accumulator.sumBB += b * b; accumulator.sumAB += a * b;
  const positiveA = Math.max(0, a); const positiveB = Math.max(0, b);
  accumulator.positiveA += positiveA; accumulator.positiveB += positiveB;
  if (b > thresholdB) accumulator.coincidentA += positiveA;
  if (a > thresholdA) accumulator.coincidentB += positiveB;
}
function finishColocalization(accumulator: ColocalizationAccumulator): ColocalizationScope {
  const covariance = accumulator.sumAB - accumulator.sumA * accumulator.sumB / accumulator.count;
  const varianceA = accumulator.sumAA - accumulator.sumA ** 2 / accumulator.count;
  const varianceB = accumulator.sumBB - accumulator.sumB ** 2 / accumulator.count;
  const denominator = Math.sqrt(Math.max(0, varianceA * varianceB));
  return {
    pearson: accumulator.count >= 2 && denominator > 0 ? covariance / denominator : null,
    mandersM1: accumulator.positiveA > 0 ? accumulator.coincidentA / accumulator.positiveA : null,
    mandersM2: accumulator.positiveB > 0 ? accumulator.coincidentB / accumulator.positiveB : null,
    pixelCount: accumulator.count,
  };
}

export function colocalization(
  labels: LabelMap,
  image: Raster,
  options: {
    readonly channelA: number;
    readonly channelB: number;
    readonly threshold?: { readonly mode: "manual"; readonly a: number; readonly b: number } | { readonly mode: "otsu"; readonly scope?: "image" | "in-cells" } | { readonly mode: "zero" };
    readonly signal?: AbortSignal;
  },
): ColocalizationResult {
  assertAligned(labels, image);
  requireChannel(image, options.channelA); requireChannel(image, options.channelB);
  if (options.channelA === options.channelB) throw new RangeError("Colocalization channels must differ.");
  const spec = options.threshold ?? { mode: "otsu" as const };
  let thresholdA = spec.mode === "manual" ? spec.a : 0;
  let thresholdB = spec.mode === "manual" ? spec.b : 0;
  if (spec.mode === "otsu") {
    let sampleCount = labels.data.length;
    const inCells = spec.scope === "in-cells";
    if (inCells) { sampleCount = 0; for (let index = 0; index < labels.data.length; index += 1) if (labels.data[index]) sampleCount += 1; }
    const samplesA = new Float64Array(sampleCount); const samplesB = new Float64Array(sampleCount); let cursor = 0;
    for (let pixel = 0; pixel < labels.data.length; pixel += 1) {
      if ((pixel & 0xffff) === 0) options.signal?.throwIfAborted();
      if (inCells && !labels.data[pixel]) continue;
      samplesA[cursor] = Number(image.data[pixel * image.channels + options.channelA]);
      samplesB[cursor] = Number(image.data[pixel * image.channels + options.channelB]); cursor += 1;
    }
    thresholdA = otsuThreshold(samplesA) ?? 0; thresholdB = otsuThreshold(samplesB) ?? 0;
  }
  if (!Number.isFinite(thresholdA) || !Number.isFinite(thresholdB)) throw new RangeError("Manders thresholds must be finite.");
  const imageAccumulator = newColocalizationAccumulator();
  const cellsAccumulator = newColocalizationAccumulator();
  const perLabel = new Map<number, ColocalizationAccumulator>();
  for (let pixel = 0; pixel < labels.data.length; pixel += 1) {
    if ((pixel & 0xffff) === 0) options.signal?.throwIfAborted();
    const a = Number(image.data[pixel * image.channels + options.channelA]); const b = Number(image.data[pixel * image.channels + options.channelB]);
    addColocalization(imageAccumulator, a, b, thresholdA, thresholdB);
    const label = labels.data[pixel];
    if (!label) continue;
    addColocalization(cellsAccumulator, a, b, thresholdA, thresholdB);
    let accumulator = perLabel.get(label); if (!accumulator) { accumulator = newColocalizationAccumulator(); perLabel.set(label, accumulator); }
    addColocalization(accumulator, a, b, thresholdA, thresholdB);
  }
  const perCell = [...perLabel.entries()].sort(([x], [y]) => x - y).map(([label, accumulator]) => ({ label, ...finishColocalization(accumulator) }));
  return {
    channelA: options.channelA,
    channelB: options.channelB,
    thresholds: {
      mode: spec.mode,
      scope: spec.mode === "otsu" && spec.scope === "in-cells" ? "in-cells" : "image",
      a: thresholdA,
      b: thresholdB,
      note: "Manders M1/M2 are threshold-dependent; report both thresholds with the coefficients.",
    },
    image: finishColocalization(imageAccumulator),
    inCells: cellsAccumulator.count ? finishColocalization(cellsAccumulator) : null,
    perCell,
    perCellMeanPearson: mean(perCell.flatMap((entry) => entry.pearson === null ? [] : [entry.pearson])),
  };
}

export type CellCyclePhase = "sub-G1" | "G1" | "S" | "G2/M" | ">G2/M";
export interface CellCycleResult {
  readonly cellCount: number;
  readonly g1Peak: number;
  readonly g2Peak: number;
  readonly g2PeakFound: boolean;
  readonly gateWidth: number;
  readonly counts: Readonly<Record<CellCyclePhase, number>>;
  readonly perCell: readonly { label: number; integratedDna: number; phase: CellCyclePhase }[];
  readonly histogram: readonly number[];
  readonly histogramRange: readonly [number, number];
  readonly caveat: string;
}

export function cellCycleHistogram(
  cells: readonly CellIntensity[],
  options: { readonly channel: number; readonly bins?: number; readonly gateWidth?: number; readonly minimumCells?: number },
): CellCycleResult {
  const pairs = cells.flatMap((cell) => {
    const value = channelValue(cell, options.channel, "integrated");
    return value === null ? [] : [{ label: cell.label, value }];
  });
  const minimumCells = options.minimumCells ?? 20;
  if (pairs.length < minimumCells) throw new RangeError(`Cell-cycle estimation needs at least ${minimumCells} cells.`);
  const values = pairs.map(({ value }) => value);
  let low = Infinity;
  let maximum = -Infinity;
  for (const value of values) {
    if (value < low) low = value;
    if (value > maximum) maximum = value;
  }
  const capCandidate = percentile(values, 99.5)!;
  const cap = capCandidate > low ? capCandidate : maximum;
  if (!(cap > low)) throw new RangeError("DNA intensities are constant; histogram peaks cannot be resolved.");
  const bins = Math.max(8, Math.trunc(options.bins ?? 64));
  const width = (cap - low) / bins;
  const histogram = new Array<number>(bins).fill(0);
  values.filter((value) => value >= low && value <= cap).forEach((value) => { histogram[Math.min(bins - 1, Math.floor((value - low) / width))] += 1; });
  const smoothed = histogram.map((_, index) => ((histogram[index - 1] ?? 0) + histogram[index] + (histogram[index + 1] ?? 0)) / 3);
  const peaks = smoothed.map((value, index) => ({ value, index })).filter(({ value, index }) => value > 0 && value >= (smoothed[index - 1] ?? -Infinity) && value >= (smoothed[index + 1] ?? -Infinity));
  const g1Index = peaks.sort((a, b) => b.value - a.value || a.index - b.index)[0]?.index;
  if (g1Index === undefined) throw new RangeError("DNA histogram has no resolvable peak.");
  const center = (index: number) => low + (index + 0.5) * width;
  const g1Peak = center(g1Index);
  const g2Candidate = peaks.filter(({ index }) => index !== g1Index && center(index) >= 1.6 * g1Peak && center(index) <= 2.4 * g1Peak)
    .sort((a, b) => b.value - a.value || a.index - b.index)[0];
  const g2Peak = g2Candidate ? center(g2Candidate.index) : g1Peak * 2;
  const gateWidth = Math.max(0.01, options.gateWidth ?? 0.15);
  const g1Low = g1Peak * (1 - gateWidth);
  let g1High = g1Peak * (1 + gateWidth);
  let g2Low = g2Peak * (1 - gateWidth);
  const g2High = g2Peak * (1 + gateWidth);
  if (g2Low <= g1High) g1High = g2Low = (g1High + g2Low) / 2;
  const counts: Record<CellCyclePhase, number> = { "sub-G1": 0, G1: 0, S: 0, "G2/M": 0, ">G2/M": 0 };
  const perCell = pairs.map(({ label, value }) => {
    const phase: CellCyclePhase = value < g1Low ? "sub-G1" : value <= g1High ? "G1" : value < g2Low ? "S" : value <= g2High ? "G2/M" : ">G2/M";
    counts[phase] += 1;
    return { label, integratedDna: value, phase };
  });
  return {
    cellCount: pairs.length, g1Peak, g2Peak, g2PeakFound: Boolean(g2Candidate), gateWidth, counts, perCell, histogram,
    histogramRange: [low, cap],
    caveat: "Estimate. Phases are peak-gated, not fitted with a cell-cycle model; verify against flow cytometry before reporting.",
  };
}
