import { connectedComponents, otsuThreshold } from "./math";
import { assertCalibration, assertLabelMap, assertRaster, type LabelMap, type PixelArray, type Raster } from "./types";

export interface ConfluenceResult {
  readonly mode: "mask" | "threshold";
  readonly widthPx: number;
  readonly heightPx: number;
  readonly coveragePct: number;
  readonly coveredAreaUm2: number;
  readonly uncoveredAreaUm2: number;
  readonly totalAreaUm2: number;
  readonly thresholdMethod: "" | "otsu" | "fixed";
  readonly thresholdValue: number | null;
}

function coverage(mask: ArrayLike<number>, width: number, height: number, pxPerUm: number, mode: ConfluenceResult["mode"], thresholdMethod: ConfluenceResult["thresholdMethod"], thresholdValue: number | null): ConfluenceResult {
  assertCalibration(pxPerUm);
  if (mask.length !== width * height) throw new RangeError("Mask dimensions do not match its data.");
  let covered = 0;
  for (let index = 0; index < mask.length; index += 1) if (mask[index]) covered += 1;
  const total = width * height;
  const totalAreaUm2 = total / pxPerUm ** 2;
  const coveredAreaUm2 = covered / pxPerUm ** 2;
  return {
    mode, widthPx: width, heightPx: height, coveragePct: covered * 100 / total,
    coveredAreaUm2, uncoveredAreaUm2: totalAreaUm2 - coveredAreaUm2, totalAreaUm2,
    thresholdMethod, thresholdValue,
  };
}

export function confluenceFromMask(mask: LabelMap, pxPerUm: number): ConfluenceResult {
  assertLabelMap(mask);
  return coverage(mask.data, mask.width, mask.height, pxPerUm, "mask", "", null);
}

export function confluenceFromIntensity(
  raster: Raster,
  options: { readonly pxPerUm: number; readonly channel?: number; readonly invert?: boolean; readonly threshold?: { readonly mode: "fixed"; readonly value: number } | { readonly mode: "otsu" } },
): ConfluenceResult {
  return confluenceAndMaskFromIntensity(raster, options).confluence;
}

/** Resolves the threshold and materializes its mask once for downstream area assays. */
export function confluenceAndMaskFromIntensity(
  raster: Raster,
  options: { readonly pxPerUm: number; readonly channel?: number; readonly invert?: boolean; readonly threshold?: { readonly mode: "fixed"; readonly value: number } | { readonly mode: "otsu" } },
): { readonly confluence: ConfluenceResult; readonly mask: LabelMap } {
  assertRaster(raster); assertCalibration(options.pxPerUm);
  const channel = options.channel ?? 0;
  if (channel < 0 || channel >= raster.channels) throw new RangeError("Threshold channel is outside the raster.");
  const plane = new Float64Array(raster.width * raster.height);
  for (let pixel = 0; pixel < plane.length; pixel += 1) plane[pixel] = Number(raster.data[pixel * raster.channels + channel]);
  const spec = options.threshold ?? { mode: "otsu" as const };
  const threshold = spec.mode === "fixed" ? spec.value : otsuThreshold(plane);
  if (threshold === null || !Number.isFinite(threshold)) throw new RangeError("The image has no intensity variation; a threshold cannot be resolved.");
  const mask = new Uint32Array(plane.length);
  for (let index = 0; index < plane.length; index += 1) mask[index] = Number(options.invert ? plane[index] <= threshold : plane[index] > threshold);
  return {
    confluence: coverage(mask, raster.width, raster.height, options.pxPerUm, "threshold", spec.mode, threshold),
    mask: { data: mask, width: raster.width, height: raster.height },
  };
}

export interface ScratchWoundResult {
  readonly widthPx: number;
  readonly heightPx: number;
  readonly gapAreaUm2: number;
  readonly gapFractionPct: number;
  readonly totalAreaUm2: number;
  readonly woundBboxPx: readonly [number, number, number, number] | null;
  readonly message: string;
}

/** Measures the largest connected cell-free region from a binary/label cell mask. */
export function scratchWoundFromCellMask(mask: LabelMap, pxPerUm: number, minimumGapAreaUm2 = 0): ScratchWoundResult {
  assertLabelMap(mask); assertCalibration(pxPerUm);
  const inverse = new Uint8Array(mask.data.length);
  for (let index = 0; index < mask.data.length; index += 1) inverse[index] = mask.data[index] ? 0 : 1;
  const minimumPixels = Math.max(0, Math.ceil(minimumGapAreaUm2 * pxPerUm ** 2));
  const largest = connectedComponents(inverse, mask.width, mask.height, true)
    .filter(({ pixels }) => pixels.length >= minimumPixels)
    .sort((a, b) => b.pixels.length - a.pixels.length || a.minY - b.minY || a.minX - b.minX)[0];
  const totalAreaUm2 = mask.data.length / pxPerUm ** 2;
  const gapPixels = largest?.pixels.length ?? 0;
  return {
    widthPx: mask.width,
    heightPx: mask.height,
    gapAreaUm2: gapPixels / pxPerUm ** 2,
    gapFractionPct: gapPixels * 100 / mask.data.length,
    totalAreaUm2,
    woundBboxPx: largest ? [largest.minX, largest.minY, largest.maxX + 1, largest.maxY + 1] : null,
    message: largest ? "" : "No open wound met the minimum-area criterion.",
  };
}

export interface ScratchWoundSeriesResult {
  readonly timepoints: readonly (ScratchWoundResult & { readonly frame: number; readonly timeHours: number | null; readonly percentClosure: number })[];
  readonly initialGapAreaUm2: number;
  readonly finalGapAreaUm2: number;
  readonly totalPercentClosure: number;
  readonly closureRateUm2PerHour: number | null;
}

export function scratchWoundSeries(
  masks: readonly LabelMap[],
  options: { readonly pxPerUm: number; readonly timepointsHours?: readonly number[]; readonly minimumGapAreaUm2?: number },
): ScratchWoundSeriesResult {
  if (masks.length < 2) throw new RangeError("A wound series needs at least two frames.");
  if (options.timepointsHours && options.timepointsHours.length !== masks.length) throw new RangeError("Timepoint count must match frame count.");
  const frames = masks.map((mask) => scratchWoundFromCellMask(mask, options.pxPerUm, options.minimumGapAreaUm2));
  const initial = frames[0].gapAreaUm2;
  const closure = (area: number) => initial > 0 ? (initial - area) * 100 / initial : 0;
  const timepoints = frames.map((frame, index) => ({ ...frame, frame: index, timeHours: options.timepointsHours?.[index] ?? null, percentClosure: closure(frame.gapAreaUm2) }));
  const final = frames.at(-1)!.gapAreaUm2;
  const elapsed = options.timepointsHours ? options.timepointsHours.at(-1)! - options.timepointsHours[0] : null;
  return {
    timepoints,
    initialGapAreaUm2: initial,
    finalGapAreaUm2: final,
    totalPercentClosure: closure(final),
    closureRateUm2PerHour: elapsed !== null && elapsed > 0 ? (initial - final) / elapsed : null,
  };
}

export interface RegionObject {
  readonly label: number;
  readonly areaUm2: number;
  readonly equivalentDiameterUm: number;
  readonly perimeterUm: number;
  readonly circularity: number;
  readonly majorAxisUm: number;
  readonly minorAxisUm: number;
  readonly centroidXpx: number;
  readonly centroidYpx: number;
  readonly bboxPx: readonly [number, number, number, number];
}

function regionObject(pixels: Uint32Array, label: number, width: number, height: number, pxPerUm: number, mask: ArrayLike<number>): RegionObject {
  let sx = 0; let sy = 0; let perimeterEdges = 0;
  let minX = width; let minY = height; let maxX = 0; let maxY = 0;
  for (const index of pixels) {
    const x = index % width; const y = Math.floor(index / width);
    sx += x; sy += y; minX = Math.min(minX, x); maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y);
    if (x === 0 || !mask[index - 1]) perimeterEdges += 1;
    if (x === width - 1 || !mask[index + 1]) perimeterEdges += 1;
    if (y === 0 || !mask[index - width]) perimeterEdges += 1;
    if (y === height - 1 || !mask[index + width]) perimeterEdges += 1;
  }
  const centroidXpx = sx / pixels.length; const centroidYpx = sy / pixels.length;
  let xx = 0; let yy = 0; let xy = 0;
  for (const index of pixels) {
    const dx = index % width - centroidXpx; const dy = Math.floor(index / width) - centroidYpx;
    xx += dx * dx; yy += dy * dy; xy += dx * dy;
  }
  xx /= pixels.length; yy /= pixels.length; xy /= pixels.length;
  const trace = xx + yy; const discriminant = Math.sqrt(Math.max(0, (xx - yy) ** 2 + 4 * xy ** 2));
  const majorAxisPx = 4 * Math.sqrt(Math.max(0, (trace + discriminant) / 2));
  const minorAxisPx = 4 * Math.sqrt(Math.max(0, (trace - discriminant) / 2));
  const perimeterUm = perimeterEdges / pxPerUm;
  const areaUm2 = pixels.length / pxPerUm ** 2;
  return {
    label, areaUm2, equivalentDiameterUm: 2 * Math.sqrt(areaUm2 / Math.PI), perimeterUm,
    circularity: perimeterUm > 0 ? Math.min(1, 4 * Math.PI * areaUm2 / perimeterUm ** 2) : 0,
    majorAxisUm: majorAxisPx / pxPerUm, minorAxisUm: minorAxisPx / pxPerUm,
    centroidXpx, centroidYpx, bboxPx: [minX, minY, maxX + 1, maxY + 1],
  };
}

export interface RegionAssayResult { readonly widthPx: number; readonly heightPx: number; readonly count: number; readonly objects: readonly RegionObject[] }

/** Spheroid/organoid sizing from a foreground mask, sorted largest first. */
export function spheroidAnalysis(mask: LabelMap, options: { readonly pxPerUm: number; readonly minimumAreaUm2?: number; readonly minimumCircularity?: number }): RegionAssayResult {
  assertLabelMap(mask); assertCalibration(options.pxPerUm);
  const binary = new Uint8Array(mask.data.length);
  for (let index = 0; index < mask.data.length; index += 1) binary[index] = mask.data[index] ? 1 : 0;
  const objects = connectedComponents(binary, mask.width, mask.height, true)
    .map((component) => regionObject(component.pixels, component.label, mask.width, mask.height, options.pxPerUm, binary))
    .filter((object) => object.areaUm2 >= (options.minimumAreaUm2 ?? 0) && object.circularity >= (options.minimumCircularity ?? 0))
    .sort((a, b) => b.areaUm2 - a.areaUm2 || a.label - b.label)
    .map((object, index) => ({ ...object, label: index + 1 }));
  return { widthPx: mask.width, heightPx: mask.height, count: objects.length, objects };
}

/** Colony sizing uses the same calibrated connected-region geometry as spheroids. */
export function colonyAnalysis(mask: LabelMap, options: { readonly pxPerUm: number; readonly minimumAreaUm2?: number }): RegionAssayResult {
  return spheroidAnalysis(mask, { ...options, minimumCircularity: 0 });
}

export function binaryLabelMap(data: PixelArray, width: number, height: number, predicate: (value: number) => boolean = (value) => value > 0): LabelMap {
  if (data.length !== width * height) throw new RangeError("Binary source dimensions do not match its data.");
  const labels = new Uint32Array(data.length);
  for (let index = 0; index < data.length; index += 1) labels[index] = predicate(Number(data[index])) ? 1 : 0;
  return { data: labels, width, height };
}
