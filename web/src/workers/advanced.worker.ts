/// <reference lib="webworker" />
import { assertSourceIdentity } from "../app/sourceIdentity";
import { preparePlane, segmentPlane, prepareDetectionPlane } from "../models/ClassicalInference";
import { labelMapToGeometry } from "../models/WebGpuInference";
import { otsuThreshold } from "../analysis/math";
import { matchGroundTruth } from "../analysis/groundTruth";
import type { AnalysisParameters, BrowserImageSource, Calibration, SourcePointPx } from "../domain/types";

export interface AdvancedJob {
  id: string; kind: "prompt" | "optimize" | "source-preview"; source: BrowserImageSource; expectedSourceSha256?: string; parameters: AnalysisParameters; calibration: Calibration;
  prompt?: { start: SourcePointPx; end?: SourcePointPx }; truth?: readonly { id: string; x: number; y: number }[];
}
async function execute(job: AdvancedJob): Promise<unknown> {
  await assertSourceIdentity(job.source.blob, job.expectedSourceSha256);
  const plane = await preparePlane({ source: job.source, parameters: job.parameters, calibration: job.calibration });
  if (job.kind === "source-preview") {
    let low = Infinity, high = -Infinity;
    for (const value of plane.values) { low = Math.min(low, value); high = Math.max(high, value); }
    const context = new OffscreenCanvas(plane.width, plane.height).getContext("2d");
    if (!context) throw new Error("Source preview needs OffscreenCanvas.");
    const pixels = context.createImageData(plane.width, plane.height);
    for (let i = 0; i < plane.values.length; i++) { const value = Math.round((plane.values[i] - low) / Math.max(1e-12, high - low) * 255); pixels.data[i * 4] = value; pixels.data[i * 4 + 1] = value; pixels.data[i * 4 + 2] = value; pixels.data[i * 4 + 3] = 255; }
    context.putImageData(pixels, 0, 0);
    return { blob: await context.canvas.convertToBlob({ type: "image/png" }), width: plane.width, height: plane.height, sourceMinimum: low, sourceMaximum: high };
  }
  if (job.kind === "optimize") {
    if (job.parameters.modelId !== "classical") throw new Error("Browser optimization currently evaluates the explicitly selected classical detector only. Learned models require validated browser artifacts.");
    const prepared = await prepareDetectionPlane(plane, job.parameters);
    const candidates: Array<{ parameters: AnalysisParameters; count: number; score: number; basis: string }> = [];
    for (const thresholdMethod of ["otsu", "triangle", "adaptive", "manual"] as const) for (const watershedSplit of [false, true]) {
      const parameters = { ...job.parameters, thresholdMethod, watershedSplit };
      const result = segmentPlane(prepared, { ...parameters, backgroundSubtract: false }, job.calibration);
      const truth = job.truth ?? [];
      const expected = job.parameters.expectedDiameterUm;
      let score: number;
      if (truth.length) score = matchGroundTruth(truth, result.cells.map((cell) => ({ id: cell.id, x: cell.centroidPx.x, y: cell.centroidPx.y })), 10 * job.calibration.pxPerUm).f1 ?? 0;
      else score = result.cells.length ? result.cells.reduce((sum, cell) => sum + (expected && expected > 0 ? Math.exp(-Math.abs(Math.log(Math.max(1e-9, cell.equivalentDiameterUm / expected)))) : cell.circularity) * (cell.edgeTouching ? .5 : 1), 0) / result.cells.length : 0;
      candidates.push({ parameters, count: result.cells.length, score, basis: truth.length ? "ground-truth F1" : "size/shape heuristic; confirm visually" });
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
    return candidates.sort((a, b) => b.score - a.score);
  }
  if (!job.prompt) throw new Error("A point or box prompt is required.");
  const a = job.prompt.start, b = job.prompt.end;
  if (![a.x, a.y, ...(b ? [b.x, b.y] : [])].every(Number.isFinite) || [a, ...(b ? [b] : [])].some((p) => p.x < 0 || p.y < 0 || p.x >= plane.width || p.y >= plane.height)) throw new Error("Prompt coordinates must lie within the source plane.");
  const center = b ? { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 } : a;
  if (b && (Math.abs(a.x - b.x) * 1.4 + 24 > 1024 || Math.abs(a.y - b.y) * 1.4 + 24 > 1024)) throw new Error("Prompt boxes including their context must fit within 1024 × 1024 source pixels. Choose a smaller box.");
  const side = Math.min(1024, Math.max(96, (job.parameters.expectedDiameterUm ?? 30) * job.calibration.pxPerUm * 4));
  const x0 = Math.max(0, Math.floor(b ? Math.min(a.x, b.x) - Math.max(12, Math.abs(a.x - b.x) * .2) : center.x - side / 2));
  const y0 = Math.max(0, Math.floor(b ? Math.min(a.y, b.y) - Math.max(12, Math.abs(a.y - b.y) * .2) : center.y - side / 2));
  const width = Math.min(1024, plane.width - x0, Math.ceil(b ? Math.abs(a.x - b.x) * 1.4 + 24 : side));
  const height = Math.min(1024, plane.height - y0, Math.ceil(b ? Math.abs(a.y - b.y) * 1.4 + 24 : side));
  if (width < 1 || height < 1 || center.x < x0 || center.y < y0 || center.x >= x0 + width || center.y >= y0 + height) throw new Error("Prompt center lies outside the bounded source crop. Choose a smaller box.");
  const values = new Float32Array(width * height); let low = Infinity, high = -Infinity, total = 0;
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) { const value = plane.values[(y + y0) * plane.width + x + x0]; values[y * width + x] = value; low = Math.min(low, value); high = Math.max(high, value); total += value; }
  if (low === high) throw new Error("Prompt crop has no intensity contrast.");
  for (let i = 0; i < values.length; i++) values[i] = (values[i] - low) / (high - low);
  const threshold = otsuThreshold(values) ?? .5;
  let sx = Math.max(0, Math.min(width - 1, Math.floor(center.x) - x0)), sy = Math.max(0, Math.min(height - 1, Math.floor(center.y) - y0));
  let localSum = 0, localCount = 0;
  for (let y = Math.max(0, sy - 3); y <= Math.min(height - 1, sy + 3); y++) for (let x = Math.max(0, sx - 3); x <= Math.min(width - 1, sx + 3); x++) { localSum += values[y * width + x]; localCount++; }
  const dark = localSum / localCount < (total / values.length - low) / (high - low);
  const foreground = (i: number) => dark ? values[i] <= threshold : values[i] >= threshold;
  if (!foreground(sy * width + sx)) { let found = false; for (let r = 1; r <= 12 && !found; r++) for (let y = Math.max(0, sy - r); y <= Math.min(height - 1, sy + r) && !found; y++) for (let x = Math.max(0, sx - r); x <= Math.min(width - 1, sx + r); x++) if (foreground(y * width + x)) { sx = x; sy = y; found = true; break; } }
  const labels = new Uint32Array(values.length), queue = new Uint32Array(values.length); let length = 0;
  if (foreground(sy * width + sx)) { queue[length++] = sy * width + sx; labels[queue[0]] = 1; }
  for (let cursor = 0; cursor < length; cursor++) {
    const at = queue[cursor], x = at % width, y = Math.floor(at / width);
    for (const next of [x > 0 ? at - 1 : -1, x + 1 < width ? at + 1 : -1, y > 0 ? at - width : -1, y + 1 < height ? at + width : -1]) if (next >= 0 && !labels[next] && foreground(next)) { labels[next] = 1; queue[length++] = next; }
  }
  if (length > width * height * .95) throw new Error("Prompt foreground occupies nearly the entire crop; choose a tighter box or stronger-contrast plane.");
  if (length < 9) throw new Error("Prompt did not isolate a usable object.");
  const geometry = labelMapToGeometry(labels, width)[0];
  if (!geometry || geometry.contourPx.length < 3) throw new Error("Prompt produced an empty contour.");
  return { backend: "browser/adaptive-connected-component", contourPx: geometry.contourPx.map((p) => ({ x: p.x + x0, y: p.y + y0 })), centerPx: { x: geometry.centroidPx.x + x0, y: geometry.centroidPx.y + y0 }, diameterUm: 2 * Math.sqrt(length / Math.PI) / job.calibration.pxPerUm };
}
self.onmessage = async (event: MessageEvent<AdvancedJob>) => {
  try { self.postMessage({ id: event.data.id, ok: true, result: await execute(event.data) }); }
  catch (error) { self.postMessage({ id: event.data.id, ok: false, error: error instanceof Error ? error.message : String(error) }); }
};
export {};
