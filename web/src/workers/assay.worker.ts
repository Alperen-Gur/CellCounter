/// <reference lib="webworker" />
import {
  analyzeNeurites,
  assessImageQuality,
  cellCycleHistogram,
  colocalization,
  confluenceAndMaskFromIntensity,
  detectPuncta,
  markerPositivity,
  matchGroundTruth,
  measureCellIntensities,
  nuclearCytoplasmicRatio,
  sampleLineProfile,
  scratchWoundFromCellMask,
  spatialStatistics,
  spheroidAnalysis,
  trackCells,
  transfectionEfficiency,
  viability,
  type LabelMap,
  type Raster,
} from "../analysis";
import { readNativeRaster } from "../import/sourcePlanes";
import type { WorkspaceCell } from "../app/types";

export type AssayKind = "qc" | "intensity" | "area" | "puncta" | "spatial" | "tracking" | "neurite" | "line-profile" | "ground-truth";
export function assayNeedsCellLabels(kind: AssayKind): boolean {
  return kind === "intensity" || kind === "puncta";
}
export interface AssayJob {
  readonly id: string;
  readonly kind: AssayKind;
  readonly source?: Blob;
  readonly auxiliary?: Blob;
  readonly auxiliaryFileName?: string;
  readonly fileName?: string;
  readonly projection?: "first" | "max" | "mean" | "sum";
  readonly sourceTime?: number; readonly sourceZ?: number; readonly channelA?: number; readonly channelB?: number;
  readonly width: number;
  readonly height: number;
  readonly pxPerUm: number;
  readonly cells: readonly WorkspaceCell[];
  readonly truth?: readonly { id: string; x: number; y: number }[];
  readonly frames?: readonly { frame: number; points: readonly { id: string; x: number; y: number }[] }[];
  readonly frameIntervalMin?: number;
  readonly maxDisplacementUm?: number;
  readonly lineStart?: { readonly x: number; readonly y: number };
  readonly lineEnd?: { readonly x: number; readonly y: number };
}

const MAX_ASSAY_WORKING_BYTES = 384 * 1024 * 1024;
const bytesPerPixelByAssay: Record<AssayKind, number> = { qc: 24, intensity: 40, area: 48, puncta: 64, spatial: 4, tracking: 4, neurite: 72, "line-profile": 20, "ground-truth": 4 };

function assertWorkingSet(kind: AssayKind, width: number, height: number, sourceBytes: number, extraFactor = 1): void {
  const pixels = width * height;
  const estimate = sourceBytes + pixels * bytesPerPixelByAssay[kind] * extraFactor;
  if (!Number.isSafeInteger(pixels) || width <= 0 || height <= 0 || estimate > MAX_ASSAY_WORKING_BYTES) throw new Error(`${kind} on ${width}×${height} pixels is estimated to need ${Math.ceil(estimate / 1024 / 1024)} MB, above the 384 MB browser assay budget. Crop or downsample locally, or analyze a smaller ROI.`);
}

function isTiff(name = "", source?: Blob): boolean { return /\.ome\.tiff?$|\.tiff?$/i.test(name) || /tiff/i.test(source?.type ?? ""); }

async function decodeStandard(source: Blob, kind: AssayKind): Promise<Raster> {
  const bitmap = await createImageBitmap(source);
  try { assertWorkingSet(kind, bitmap.width, bitmap.height, source.size); }
  catch (error) { bitmap.close(); throw error; }
  const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
  const context = canvas.getContext("2d", { willReadFrequently: true });
  if (!context) throw new Error("2D OffscreenCanvas is unavailable for local assay decoding");
  context.drawImage(bitmap, 0, 0); bitmap.close();
  const rgba = context.getImageData(0, 0, canvas.width, canvas.height).data;
  const rgb = new Uint8Array(canvas.width * canvas.height * 3);
  for (let pixel = 0; pixel < canvas.width * canvas.height; pixel += 1) {
    rgb[pixel * 3] = rgba[pixel * 4]; rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]; rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2];
  }
  return { data: rgb, width: canvas.width, height: canvas.height, channels: 3 };
}

async function decodeTiff(source: Blob, projection: "first" | "max" | "mean" | "sum", kind: AssayKind): Promise<Raster> {
  const raster = await readNativeRaster(source, "auxiliary.tif", { projection });
  assertWorkingSet(kind, raster.width, raster.height, source.size);
  return raster;
}

function pointInPolygon(x: number, y: number, points: readonly (readonly [number, number])[]): boolean {
  let inside = false;
  for (let i = 0, j = points.length - 1; i < points.length; j = i++) { const a = points[i], b = points[j]; if ((a[1] > y) !== (b[1] > y) && x < (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]) + a[0]) inside = !inside; }
  return inside;
}
function cellLabels(cells: readonly WorkspaceCell[], width: number, height: number): LabelMap {
  const data = new Uint32Array(width * height);
  cells.forEach((cell, cellIndex) => {
    const radius = cell.diameterPx / 2;
    const polygon = cell.contourPx && cell.contourPx.length >= 3 ? cell.contourPx : undefined;
    let lowX = cell.cx - radius; let highX = cell.cx + radius; let lowY = cell.cy - radius; let highY = cell.cy + radius;
    if (polygon) for (const [x, y] of polygon) { lowX = Math.min(lowX, x); highX = Math.max(highX, x); lowY = Math.min(lowY, y); highY = Math.max(highY, y); }
    const minX = Math.max(0, Math.floor(lowX)); const maxX = Math.min(width - 1, Math.ceil(highX));
    const minY = Math.max(0, Math.floor(lowY)); const maxY = Math.min(height - 1, Math.ceil(highY));
    for (let y = minY; y <= maxY; y += 1) for (let x = minX; x <= maxX; x += 1) {
      if (polygon ? pointInPolygon(x + 0.5, y + 0.5, polygon) : (x - cell.cx) ** 2 + (y - cell.cy) ** 2 <= radius ** 2) data[y * width + x] = cellIndex + 1;
    }
  });
  return { data, width, height };
}

async function run(job: AssayJob): Promise<unknown> {
  if (job.kind === "spatial") return spatialStatistics(job.cells.map((cell) => ({ id: cell.id, x: cell.cx, y: cell.cy })), { widthPx: job.width, heightPx: job.height, pxPerUm: job.pxPerUm });
  if (job.kind === "tracking") return trackCells(job.frames ?? [], { pxPerUm: job.pxPerUm, frameIntervalMin: job.frameIntervalMin ?? 10, maxDisplacementUm: job.maxDisplacementUm ?? 50 });
  if (job.kind === "ground-truth") return matchGroundTruth(job.truth ?? [], job.cells.map((cell) => ({ id: cell.id, x: cell.cx, y: cell.cy })), 10 * job.pxPerUm);
  if (!job.source) throw new Error("This assay needs a locally loaded source image");
  const raster = await readNativeRaster(job.source, job.fileName ?? "source.png", { t: job.sourceTime, z: job.sourceZ, projection: job.projection });
  assertWorkingSet(job.kind, raster.width, raster.height, job.source.size);
  const channelA = job.channelA ?? 0, channelB = job.channelB ?? 1;
  if (!Number.isInteger(channelA) || channelA < 0 || channelA >= raster.channels) throw new Error("Selected assay channel A is unavailable.");
  if (raster.width !== job.width || raster.height !== job.height) throw new Error("Decoded assay raster dimensions do not match the workspace source coordinates");
  if (job.kind === "intensity" && !job.cells.length) throw new Error("Intensity assays need segmented or manually added cells");
  const labels = assayNeedsCellLabels(job.kind) ? cellLabels(job.cells, raster.width, raster.height) : undefined;
  if (job.kind === "qc") return assessImageQuality(raster);
  if (job.kind === "line-profile") return sampleLineProfile(raster, job.lineStart ?? { x: 0, y: raster.height / 2 }, job.lineEnd ?? { x: raster.width - 1, y: raster.height / 2 }, { pxPerUm: job.pxPerUm, stepPx: Math.max(1, raster.width / 256) });
  if (job.kind === "intensity") {
    const cells = measureCellIntensities(labels!, raster);
    const positivity = markerPositivity(cells, { channel: channelA, threshold: { mode: "otsu" } });
    const result: Record<string, unknown> = { cells, positivity, transfection: transfectionEfficiency(cells, { channel: channelA, threshold: { mode: "otsu" } }) };
    if (raster.channels >= 2 && channelB >= 0 && channelB < raster.channels && channelA !== channelB) {
      result.colocalization = colocalization(labels!, raster, { channelA, channelB, threshold: { mode: "otsu", scope: "in-cells" } });
      result.viability = viability(cells, { liveChannel: channelA, deadChannel: channelB, liveThreshold: { mode: "otsu" }, deadThreshold: { mode: "otsu" } });
    }
    if (job.auxiliary) {
      const nuclei = isTiff(job.auxiliaryFileName, job.auxiliary) ? await decodeTiff(job.auxiliary, job.projection ?? "first", job.kind) : await decodeStandard(job.auxiliary, job.kind);
      if (nuclei.width !== raster.width || nuclei.height !== raster.height) throw new Error("Nuclear mask dimensions must match the source image");
      const binary = confluenceAndMaskFromIntensity(nuclei, { pxPerUm: job.pxPerUm, threshold: { mode: "otsu" } }).mask;
      const nucleusLabels = new Uint32Array(labels!.data.length);
      for (let index = 0; index < nucleusLabels.length; index += 1) if (binary.data[index]) nucleusLabels[index] = labels!.data[index];
      result.nuclearCytoplasmic = nuclearCytoplasmicRatio(labels!, { data: nucleusLabels, width: labels!.width, height: labels!.height }, raster, { channel: channelA });
    }
    if (cells.length >= 20) result.cellCycle = cellCycleHistogram(cells, { channel: channelA });
    return result;
  }
  if (job.kind === "puncta") return detectPuncta(raster, labels!, { channel: channelA });
  const { confluence, mask } = confluenceAndMaskFromIntensity(raster, { pxPerUm: job.pxPerUm, threshold: { mode: "otsu" } });
  if (job.kind === "area") {
    const regions = spheroidAnalysis(mask, { pxPerUm: job.pxPerUm });
    return { confluence, wound: scratchWoundFromCellMask(mask, job.pxPerUm), spheroids: regions, colonies: regions };
  }
  if (job.kind === "neurite") {
    let neuriteMask = mask;
    if (job.auxiliary) {
      const auxiliary = isTiff(job.auxiliaryFileName, job.auxiliary) ? await decodeTiff(job.auxiliary, job.projection ?? "first", job.kind) : await decodeStandard(job.auxiliary, job.kind);
      if (auxiliary.width !== raster.width || auxiliary.height !== raster.height) throw new Error("Neurite mask dimensions must match the source image");
      neuriteMask = confluenceAndMaskFromIntensity(auxiliary, { pxPerUm: job.pxPerUm, threshold: { mode: "otsu" } }).mask;
    }
    const result = analyzeNeurites(neuriteMask, job.cells.map((cell) => ({ id: cell.id, x: cell.cx, y: cell.cy, radiusPx: cell.diameterPx / 2 })), { pxPerUm: job.pxPerUm });
    return { ...result, skeleton: undefined, skeletonPixelCount: result.skeleton.reduce((sum, value) => sum + value, 0) };
  }
  throw new Error(`Unknown assay ${job.kind}`);
}

self.onmessage = async (event: MessageEvent<AssayJob>) => {
  try { self.postMessage({ id: event.data.id, ok: true, result: await run(event.data) }); }
  catch (error) { self.postMessage({ id: event.data.id, ok: false, error: error instanceof Error ? error.message : String(error) }); }
};

export {};
