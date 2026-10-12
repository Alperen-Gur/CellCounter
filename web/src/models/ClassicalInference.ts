import { measureCells } from "../domain/measurements";
import type { AnalysisParameters, Calibration, DetectionResultDTO } from "../domain/types";
import { connectedComponents, otsuThreshold } from "../analysis/math";
import { labelMapToGeometry, type InferenceEngine, type WebInferenceRequest } from "./WebGpuInference";
import { readNativeRaster } from "../import/sourcePlanes";
import { applyPreprocessing } from "../../../shared/preprocessing";

export const CLASSICAL_MODEL_ID = "classical" as const;
export const CLASSICAL_VERSION = "1.1.0";
export interface PreparedPlane { width: number; height: number; values: Float32Array; }
const MAX_PIXELS = 4_000_000;
function checkSize(width: number, height: number) {
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width <= 0 || height <= 0 || width * height > MAX_PIXELS) throw new Error("Browser segmentation supports fields up to 4 million pixels. Crop or downsample locally first.");
}
function cancelled(signal?: AbortSignal) { if (signal?.aborted) throw new DOMException("Analysis cancelled", "AbortError"); }
async function yieldTask(signal?: AbortSignal) { await new Promise((resolve) => setTimeout(resolve, 0)); cancelled(signal); }

/** Raw source samples; projection remains in the original source pixel geometry. */
export async function preparePlane(request: WebInferenceRequest): Promise<PreparedPlane> {
  const channel = request.parameters.sourceChannel ?? -1;
  const raster = await readNativeRaster(request.source.blob, request.source.fileName, { t: request.parameters.sourceTime, z: request.parameters.sourceZ, projection: request.parameters.projection, channels: channel >= 0 ? [channel] : undefined }, request.signal);
  const values = new Float32Array(raster.width * raster.height);
  for (let i = 0; i < values.length; i++) values[i] = channel >= 0 || raster.channels < 3 ? Number(raster.data[i * raster.channels]) : .2126 * Number(raster.data[i * raster.channels]) + .7152 * Number(raster.data[i * raster.channels + 1]) + .0722 * Number(raster.data[i * raster.channels + 2]);
  return { width: raster.width, height: raster.height, values };
}

function localMean(values: Float32Array, width: number, height: number, radius: number): Float32Array {
  const stride = width + 1;
  const integral = new Float64Array(stride * (height + 1));
  for (let y = 0; y < height; y++) {
    let row = 0;
    for (let x = 0; x < width; x++) { row += values[y * width + x]; integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + row; }
  }
  const output = new Float32Array(values.length);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const x0 = Math.max(0, x - radius); const y0 = Math.max(0, y - radius);
    const x1 = Math.min(width, x + radius + 1); const y1 = Math.min(height, y + radius + 1);
    output[y * width + x] = (integral[y1 * stride + x1] - integral[y0 * stride + x1] - integral[y1 * stride + x0] + integral[y0 * stride + x0]) / ((x1 - x0) * (y1 - y0));
  }
  return output;
}

export function triangleThreshold(values: Float32Array): number {
  const histogram = new Uint32Array(256);
  for (const value of values) histogram[Math.min(255, Math.max(0, Math.round(value * 255)))]++;
  let peak = 0; let low = 0; let high = 255;
  for (let i = 1; i < 256; i++) if (histogram[i] > histogram[peak]) peak = i;
  while (low < peak && !histogram[low]) low++;
  while (high > peak && !histogram[high]) high--;
  const end = peak - low > high - peak ? low : high;
  const dx = end - peak; const dy = histogram[end] - histogram[peak];
  let best = peak; let distance = -1;
  for (let i = Math.min(end, peak); i <= Math.max(end, peak); i++) {
    const next = Math.abs(dy * (i - peak) - dx * (histogram[i] - histogram[peak]));
    if (next > distance) { distance = next; best = i; }
  }
  return best / 255;
}

/** Distance-ordered seeded watershed. Every foreground pixel remains assigned to one instance. */
export function watershedLabels(binary: Uint8Array, width: number, height: number, separation: number): Uint32Array {
  checkSize(width, height);
  if (binary.length !== width * height || !Number.isFinite(separation) || separation <= 0) throw new Error("Watershed needs matching dimensions and a finite positive seed separation.");
  let seedWork = 0;
  const countSeedWork = () => { if (++seedWork > 20_000_000) throw new Error("Watershed exceeds twenty million seed/neighborhood comparisons. Reduce the seed distance, crop the field or disable splitting."); };
  const distance = new Float32Array(binary.length);
  const labels = new Uint32Array(binary.length);
  for (let i = 0; i < distance.length; i++) distance[i] = binary[i] ? Math.min(i % width + 1, width - i % width, Math.floor(i / width) + 1, height - Math.floor(i / width)) : 0;
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) { const i = y * width + x; if (binary[i]) distance[i] = Math.min(distance[i], x ? distance[i - 1] + 1 : 1, y ? distance[i - width] + 1 : 1, x && y ? distance[i - width - 1] + Math.SQRT2 : Infinity, x + 1 < width && y ? distance[i - width + 1] + Math.SQRT2 : Infinity); }
  for (let y = height - 1; y >= 0; y--) for (let x = width - 1; x >= 0; x--) { const i = y * width + x; if (binary[i]) distance[i] = Math.min(distance[i], x + 1 < width ? distance[i + 1] + 1 : 1, y + 1 < height ? distance[i + width] + 1 : 1, x + 1 < width && y + 1 < height ? distance[i + width + 1] + Math.SQRT2 : Infinity, x && y + 1 < height ? distance[i + width - 1] + Math.SQRT2 : Infinity); }
  let nextLabel = 0;
  const components = connectedComponents(binary, width, height, false);
  for (const component of components) {
    const ordered = Array.from(component.pixels).sort((a, b) => distance[b] - distance[a] || a - b);
    const seeds: number[] = [];
    for (const i of ordered) {
      const x = i % width; const y = Math.floor(i / width);
      const neighbors = [x ? i - 1 : i, x + 1 < width ? i + 1 : i, y ? i - width : i, y + 1 < height ? i + width : i];
      if (neighbors.some((n) => distance[n] > distance[i])) continue;
      let higher = false;
      const radius = Math.max(1, Math.floor(separation / 2));
      for (let yy = Math.max(0, y - radius); yy <= Math.min(height - 1, y + radius) && !higher; yy++) for (let xx = Math.max(0, x - radius); xx <= Math.min(width - 1, x + radius); xx++) { countSeedWork(); if (distance[yy * width + xx] > distance[i] + 1e-6) { higher = true; break; } }
      if (higher) continue;
      if (seeds.some((s) => { countSeedWork(); return Math.hypot(s % width - x, Math.floor(s / width) - y) < separation; })) continue;
      if (nextLabel >= 50_000) throw new Error("Watershed exceeds 50,000 instances. Crop the field or adjust segmentation settings.");
      seeds.push(i); labels[i] = ++nextLabel;
    }
    if (!seeds.length) { if (nextLabel >= 50_000) throw new Error("Watershed exceeds 50,000 instances. Crop the field or adjust segmentation settings."); seeds.push(ordered[0]); labels[ordered[0]] = ++nextLabel; }
    // Maximum-priority flood avoids crossing a low saddle before filling each peak.
    const heap: number[] = [];
    const push = (value: number) => { let at = heap.length; heap.push(value); while (at > 0) { const parent = (at - 1) >> 1; if (distance[heap[parent]] >= distance[value]) break; heap[at] = heap[parent]; at = parent; } heap[at] = value; };
    const pop = () => { const first = heap[0]; const last = heap.pop()!; if (heap.length) { let at = 0; while (at * 2 + 1 < heap.length) { let child = at * 2 + 1; if (child + 1 < heap.length && distance[heap[child + 1]] > distance[heap[child]]) child++; if (distance[last] >= distance[heap[child]]) break; heap[at] = heap[child]; at = child; } heap[at] = last; } return first; };
    for (const seed of seeds) push(seed);
    while (heap.length) {
      const i = pop(); const x = i % width; const y = Math.floor(i / width);
      for (const n of [x ? i - 1 : i, x + 1 < width ? i + 1 : i, y ? i - width : i, y + 1 < height ? i + width : i]) if (binary[n] && !labels[n]) { labels[n] = labels[i]; push(n); }
    }
  }
  return labels;
}

export function subtractBackground(plane: PreparedPlane, radius: number): PreparedPlane {
  if (!Number.isSafeInteger(radius) || radius < 1 || radius > 1024) throw new Error("Background radius must be 1–1024 pixels.");
  const mean = localMean(plane.values, plane.width, plane.height, radius); const values = plane.values.slice();
  for (let i = 0; i < values.length; i++) values[i] = Math.max(0, values[i] - mean[i]);
  return { ...plane, values };
}

export async function prepareDetectionPlane(plane: PreparedPlane, parameters: AnalysisParameters, signal?: AbortSignal): Promise<PreparedPlane> {
  const background = parameters.backgroundSubtract ? subtractBackground(plane, parameters.rollingBallRadiusPx) : plane;
  return { ...plane, values: await applyPreprocessing(background.values, plane.width, plane.height, parameters.preprocessingPreset ?? "none", signal) };
}

export function segmentPlane(plane: PreparedPlane, parameters: AnalysisParameters, calibration: Calibration): DetectionResultDTO {
  const { width, height } = plane;
  checkSize(width, height);
  if (plane.values.length !== width * height) throw new Error("Source plane dimensions do not match its intensities.");
  let values = plane.values.slice();
  if (parameters.backgroundSubtract) { const mean = localMean(values, width, height, parameters.rollingBallRadiusPx); for (let i = 0; i < values.length; i++) values[i] = Math.max(0, values[i] - mean[i]); }
  let low = Infinity; let high = -Infinity;
  for (const value of values) { low = Math.min(low, value); high = Math.max(high, value); }
  if (high === low) return { imageWidth: width, imageHeight: height, cells: [], imageStats: { sourceMinimum: low, sourceMaximum: high, foregroundPixels: 0 } };
  for (let i = 0; i < values.length; i++) values[i] = (values[i] - low) / (high - low);
  const method = parameters.thresholdMethod ?? "otsu";
  const threshold = method === "manual" ? (parameters.manualThreshold ?? .5) : method === "triangle" ? triangleThreshold(values) : otsuThreshold(values) ?? .5;
  const means = method === "adaptive" ? localMean(values, width, height, Math.max(2, Math.round((parameters.expectedDiameterUm ?? 20) * calibration.pxPerUm / 2))) : undefined;
  const binary = new Uint8Array(values.length);
  for (let i = 0; i < values.length; i++) { const cutoff = means ? means[i] + .03 : threshold; binary[i] = Number(parameters.invert ? values[i] < cutoff : values[i] > cutoff); }
  let labels: Uint32Array;
  if (parameters.watershedSplit) labels = watershedLabels(binary, width, height, Math.max(2, parameters.watershedMinDistanceUm * calibration.pxPerUm));
  else { labels = new Uint32Array(binary.length); for (const component of connectedComponents(binary, width, height, false)) for (const i of component.pixels) labels[i] = component.label; }
  const counts = new Map<number, number>();
  for (const label of labels) if (label) counts.set(label, (counts.get(label) ?? 0) + 1);
  const minimum = Math.max(1, Math.round(parameters.minimumAreaPx ?? 9));
  let foregroundPixels = 0;
  for (let i = 0; i < labels.length; i++) { if ((counts.get(labels[i]) ?? 0) < minimum) labels[i] = 0; if (labels[i]) foregroundPixels++; }
  const cells = measureCells(labelMapToGeometry(labels, width), calibration, { widthPx: width, heightPx: height }, parameters.sizeThresholdsUm);
  return { imageWidth: width, imageHeight: height, cells, imageStats: { thresholdNormalized: threshold, sourceMinimum: low, sourceMaximum: high, foregroundPixels } };
}

export class ClassicalInference implements InferenceEngine {
  async analyze(request: WebInferenceRequest): Promise<DetectionResultDTO> {
    if (request.parameters.modelId !== CLASSICAL_MODEL_ID) throw new Error("The classical engine only executes an explicitly selected classical analysis.");
    request.onProgress?.({ stage: "decode", completed: 0, total: 1 });
    const plane = await preparePlane(request);
    await yieldTask(request.signal);
    request.onProgress?.({ stage: "inference", completed: 0, total: 1 });
    const preprocessed = await prepareDetectionPlane(plane, request.parameters, request.signal);
    const result = segmentPlane(preprocessed, { ...request.parameters, backgroundSubtract: false }, request.calibration);
    const canvas = new OffscreenCanvas(plane.width, plane.height);
    const context = canvas.getContext("2d");
    if (!context) throw new Error("A 2D canvas is required for the source-plane preview.");
    const pixels = context.createImageData(plane.width, plane.height);
    let low = Infinity; let high = -Infinity;
    for (const value of plane.values) { low = Math.min(low, value); high = Math.max(high, value); }
    for (let i = 0; i < plane.values.length; i++) { const value = Math.round((plane.values[i] - low) / Math.max(1e-12, high - low) * 255); pixels.data[i * 4] = value; pixels.data[i * 4 + 1] = value; pixels.data[i * 4 + 2] = value; pixels.data[i * 4 + 3] = 255; }
    context.putImageData(pixels, 0, 0);
    const displayPlane = await canvas.convertToBlob({ type: "image/png" });
    await yieldTask(request.signal);
    request.onProgress?.({ stage: "postprocess", completed: 1, total: 1 });
    return { ...result, displayPlane };
  }
}
