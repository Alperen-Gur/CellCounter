import { measureCells } from "../domain/measurements";
import type {
  BrowserImageSource,
  Calibration,
  CellGeometry,
  DetectionParams,
  DetectionResultDTO,
  ModelId,
  SourcePointPx,
} from "../domain/types";
import { getModelManifest, type ModelManifest } from "./catalog";
import {
  CancelledInferenceError,
  InferenceError,
  ModelArtifactUnavailableError,
  NoWebGpuError,
  normalizeInferenceError,
} from "./errors";
import { verifySha256 } from "./hash";

export interface InferenceProgress {
  readonly stage: "environment" | "model" | "decode" | "inference" | "postprocess";
  readonly completed: number;
  readonly total: number;
}

export interface WebInferenceRequest {
  readonly source: BrowserImageSource;
  readonly calibration: Calibration;
  readonly parameters: DetectionParams;
  readonly signal?: AbortSignal;
  readonly onProgress?: (progress: InferenceProgress) => void;
}

export interface InferenceEngine {
  analyze(request: WebInferenceRequest): Promise<DetectionResultDTO>;
}

export interface ModelArtifactCache {
  get(key: string): Promise<ArrayBuffer | null>;
  put(key: string, value: ArrayBuffer): Promise<void>;
  delete(key: string): Promise<void>;
}

interface GpuAdapterLike {}
interface GpuNavigator extends Navigator {
  readonly gpu?: { requestAdapter(): Promise<GpuAdapterLike | null> };
}

type OrtTensorData = Float32Array | Int32Array | BigInt64Array | Uint32Array;
interface OrtTensorLike {
  readonly data: OrtTensorData;
  readonly dims: readonly number[];
  dispose?(): Promise<void> | void;
}
interface OrtSessionLike {
  run(feeds: Record<string, unknown>): Promise<Record<string, OrtTensorLike>>;
  release?(): Promise<void> | void;
}
interface OrtModuleLike {
  Tensor: new (type: "float32", data: Float32Array, dims: readonly number[]) => OrtTensorLike;
  InferenceSession: {
    create(bytes: Uint8Array, options: Record<string, unknown>): Promise<OrtSessionLike>;
  };
}

export class ReusableSessionSlot<T extends { release?(): Promise<void> | void }> {
  private active: { key: string; value: T } | null = null;

  async acquire(key: string, create: () => Promise<T>): Promise<T> {
    if (this.active?.key === key) return this.active.value;
    const value = await create();
    const previous = this.active;
    this.active = { key, value };
    await previous?.value.release?.();
    return value;
  }

  async dispose(): Promise<void> {
    const active = this.active;
    this.active = null;
    await active?.value.release?.();
  }
}

export async function disposeTileTensors(input: OrtTensorLike, outputs: Record<string, OrtTensorLike>): Promise<void> {
  await Promise.all(Object.values(outputs).map(async (output) => output.dispose?.()));
  await input.dispose?.();
}

export async function assertWebGpuAvailable(): Promise<void> {
  const gpu = (globalThis.navigator as GpuNavigator | undefined)?.gpu;
  if (!gpu) throw new NoWebGpuError();
  const adapter = await gpu.requestAdapter();
  if (!adapter) throw new NoWebGpuError();
}

function abortIfNeeded(signal: AbortSignal | undefined, modelId: ModelId): void {
  if (signal?.aborted) throw new CancelledInferenceError(modelId);
}

async function fetchArtifact(
  manifest: ModelManifest,
  cache: ModelArtifactCache | null,
  signal: AbortSignal | undefined,
): Promise<ArrayBuffer> {
  if (manifest.artifact.availability !== "ready" || manifest.artifact.byteLength <= 0) {
    throw new ModelArtifactUnavailableError(manifest.id, "a validated custom build is required for this release");
  }
  const cacheKey = `${manifest.id}@${manifest.manifestVersion}:${manifest.artifact.sha256}`;
  const cached = await cache?.get(cacheKey);
  if (cached) {
    try {
      await verifySha256(manifest.id, cached, manifest.artifact.sha256);
      return cached;
    } catch (error) {
      await cache?.delete(cacheKey);
      throw error;
    }
  }

  let response: Response;
  try {
    response = await fetch(manifest.artifact.url, {
      signal,
      cache: "no-store",
      credentials: "same-origin",
      referrerPolicy: "no-referrer",
    });
  } catch (error) {
    if (signal?.aborted) throw new CancelledInferenceError(manifest.id);
    throw new ModelArtifactUnavailableError(manifest.id, error instanceof Error ? error.message : "fetch failed");
  }
  if (!response.ok) throw new ModelArtifactUnavailableError(manifest.id, `HTTP ${response.status}`);
  const bytes = await response.arrayBuffer();
  if (bytes.byteLength !== manifest.artifact.byteLength) {
    throw new ModelArtifactUnavailableError(
      manifest.id,
      `artifact length mismatch (expected ${manifest.artifact.byteLength}, received ${bytes.byteLength})`,
    );
  }
  await verifySha256(manifest.id, bytes, manifest.artifact.sha256);
  // IndexedDB performs the required structured clone. Avoid an additional
  // model-sized in-process copy before that write.
  await cache?.put(cacheKey, bytes);
  return bytes;
}

interface DecodedPixels {
  readonly width: number;
  readonly height: number;
  readonly rgba: Uint8ClampedArray;
}

async function decodeImage(source: BrowserImageSource): Promise<DecodedPixels> {
  if (!("createImageBitmap" in globalThis) || !("OffscreenCanvas" in globalThis)) {
    throw new InferenceError("image-decode-failed", "This browser cannot decode images inside a Worker", null);
  }
  try {
    const bitmap = await createImageBitmap(source.blob);
    try {
      const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
      const context = canvas.getContext("2d", { willReadFrequently: true });
      if (!context) throw new Error("2D canvas context unavailable");
      context.drawImage(bitmap, 0, 0);
      const data = context.getImageData(0, 0, bitmap.width, bitmap.height).data;
      return { width: bitmap.width, height: bitmap.height, rgba: data };
    } finally {
      bitmap.close();
    }
  } catch (error) {
    throw new InferenceError("image-decode-failed", `Could not decode ${source.fileName}`, null, { cause: error });
  }
}

function histogramPercentile(histogram: Uint32Array, sampleCount: number, fraction: number): number {
  const target = Math.floor(Math.max(0, sampleCount - 1) * fraction);
  let cumulative = 0;
  for (let value = 0; value < histogram.length; value += 1) {
    cumulative += histogram[value];
    if (cumulative > target) return value;
  }
  return 255;
}

function normalizedTile(
  pixels: DecodedPixels,
  originX: number,
  originY: number,
  tileSize: number,
): Float32Array {
  const output = new Float32Array(3 * tileSize * tileSize);
  const histograms = [new Uint32Array(256), new Uint32Array(256), new Uint32Array(256)];
  for (let y = 0; y < tileSize; y += 1) {
    for (let x = 0; x < tileSize; x += 1) {
      const sx = Math.min(pixels.width - 1, originX + x);
      const sy = Math.min(pixels.height - 1, originY + y);
      const inputOffset = (sy * pixels.width + sx) * 4;
      for (let channel = 0; channel < 3; channel += 1) histograms[channel][pixels.rgba[inputOffset + channel]] += 1;
    }
  }
  const sampleCount = tileSize * tileSize;
  const lows = histograms.map((histogram) => histogramPercentile(histogram, sampleCount, 0.01));
  const highs = histograms.map((histogram) => histogramPercentile(histogram, sampleCount, 0.99));
  for (let y = 0; y < tileSize; y += 1) {
    for (let x = 0; x < tileSize; x += 1) {
      const sx = Math.min(pixels.width - 1, originX + x);
      const sy = Math.min(pixels.height - 1, originY + y);
      const inputOffset = (sy * pixels.width + sx) * 4;
      const tileOffset = y * tileSize + x;
      for (let channel = 0; channel < 3; channel += 1) {
        const scale = Math.max(1, highs[channel] - lows[channel]);
        output[channel * sampleCount + tileOffset] = Math.max(
          0,
          Math.min(1, (pixels.rgba[inputOffset + channel] - lows[channel]) / scale),
        );
      }
    }
  }
  return output;
}

export interface LabelTile {
  readonly originX: number;
  readonly originY: number;
  readonly width: number;
  readonly height: number;
  readonly labels: Uint32Array;
}

/** Incrementally stitches a tile and releases the tile-sized label map at the call boundary. */
export class IncrementalLabelStitcher {
  private readonly output: Uint32Array;
  private readonly parent: number[] = [0];
  private nextGlobalLabel = 1;

  constructor(private readonly width: number, private readonly height: number) {
    if (!Number.isSafeInteger(width * height) || width <= 0 || height <= 0) throw new RangeError("Invalid output dimensions");
    this.output = new Uint32Array(width * height);
  }

  private find(value: number): number {
    let root = value;
    while (this.parent[root] !== root) root = this.parent[root];
    while (this.parent[value] !== value) {
      const next = this.parent[value];
      this.parent[value] = root;
      value = next;
    }
    return root;
  }

  private union(left: number, right: number): void {
    const leftRoot = this.find(left);
    const rightRoot = this.find(right);
    if (leftRoot !== rightRoot) this.parent[Math.max(leftRoot, rightRoot)] = Math.min(leftRoot, rightRoot);
  }

  add(tile: LabelTile): void {
    if (tile.labels.length !== tile.width * tile.height) throw new RangeError("Tile dimensions do not match its labels");
    const localToGlobal = new Map<number, number>();
    for (let y = 0; y < tile.height; y += 1) {
      for (let x = 0; x < tile.width; x += 1) {
        const localLabel = tile.labels[y * tile.width + x];
        if (!localLabel) continue;
        let globalLabel = localToGlobal.get(localLabel);
        if (!globalLabel) {
          globalLabel = this.nextGlobalLabel;
          this.nextGlobalLabel += 1;
          this.parent[globalLabel] = globalLabel;
          localToGlobal.set(localLabel, globalLabel);
        }
        const sourceX = tile.originX + x;
        const sourceY = tile.originY + y;
        if (sourceX < 0 || sourceY < 0 || sourceX >= this.width || sourceY >= this.height) continue;
        const outputIndex = sourceY * this.width + sourceX;
        const existing = this.output[outputIndex];
        if (existing) this.union(existing, globalLabel);
        else this.output[outputIndex] = globalLabel;
      }
    }
  }

  finish(): Uint32Array {
    const compact = new Map<number, number>();
    let nextCompact = 1;
    for (let index = 0; index < this.output.length; index += 1) {
      if (!this.output[index]) continue;
      const root = this.find(this.output[index]);
      let label = compact.get(root);
      if (!label) {
        label = nextCompact;
        nextCompact += 1;
        compact.set(root, label);
      }
      this.output[index] = label;
    }
    return this.output;
  }
}

/** Compatibility helper; production inference calls add as each tile completes. */
export function stitchLabelTiles(tiles: readonly LabelTile[], width: number, height: number): Uint32Array {
  const stitcher = new IncrementalLabelStitcher(width, height);
  for (const tile of tiles) stitcher.add(tile);
  return stitcher.finish();
}

function tileOrigins(length: number, tileSize: number, overlapPx: number): number[] {
  if (length <= tileSize) return [0];
  const stride = tileSize - overlapPx * 2;
  if (stride <= 0) throw new RangeError("Model tile overlap leaves no usable stride");
  const origins: number[] = [];
  for (let origin = 0; origin < length - tileSize; origin += stride) origins.push(origin);
  const finalOrigin = length - tileSize;
  if (origins[origins.length - 1] !== finalOrigin) origins.push(finalOrigin);
  return origins;
}

function edgeEnd(vertex: number, direction: number, vertexWidth: number): number {
  if (direction === 0) return vertex + 1;
  if (direction === 1) return vertex + vertexWidth;
  if (direction === 2) return vertex - 1;
  return vertex - vertexWidth;
}

function simplifyOrthogonalContour(points: SourcePointPx[]): SourcePointPx[] {
  if (points.length <= 4) return points;
  const output: SourcePointPx[] = [];
  for (let index = 0; index < points.length; index += 1) {
    const previous = points[(index + points.length - 1) % points.length];
    const current = points[index];
    const next = points[(index + 1) % points.length];
    if ((previous.x === current.x && current.x === next.x) || (previous.y === current.y && current.y === next.y)) continue;
    output.push(current);
  }
  return output.length >= 3 ? output : points;
}

function largestBoundaryLoop(edges: readonly number[], vertexWidth: number): SourcePointPx[] {
  const outgoing = new Map<number, number[]>();
  edges.forEach((code, index) => {
    const start = Math.floor(code / 4);
    const candidates = outgoing.get(start) ?? [];
    candidates.push(index);
    outgoing.set(start, candidates);
  });
  const used = new Uint8Array(edges.length);
  let largest: SourcePointPx[] = [];
  let largestArea = -1;
  for (let seed = 0; seed < edges.length; seed += 1) {
    if (used[seed]) continue;
    const loop: SourcePointPx[] = [];
    const startVertex = Math.floor(edges[seed] / 4);
    let edgeIndex = seed;
    while (!used[edgeIndex]) {
      const code = edges[edgeIndex];
      const vertex = Math.floor(code / 4);
      used[edgeIndex] = 1;
      loop.push({ x: vertex % vertexWidth, y: Math.floor(vertex / vertexWidth) });
      const end = edgeEnd(vertex, code % 4, vertexWidth);
      if (end === startVertex) break;
      const next = (outgoing.get(end) ?? []).find((candidate) => !used[candidate]);
      if (next === undefined) break;
      edgeIndex = next;
    }
    if (loop.length < 3) continue;
    let doubledArea = 0;
    for (let index = 0; index < loop.length; index += 1) {
      const current = loop[index];
      const next = loop[(index + 1) % loop.length];
      doubledArea += current.x * next.y - next.x * current.y;
    }
    const area = Math.abs(doubledArea);
    if (area > largestArea) { largest = simplifyOrthogonalContour(loop); largestArea = area; }
  }
  return largest;
}

/** Converts a label raster using O(label-count + boundary) JS objects, not O(foreground-pixels). */
export function labelMapToGeometry(labels: Uint32Array, width: number): CellGeometry[] {
  if (width <= 0 || labels.length % width !== 0) throw new RangeError("Invalid label-map dimensions");
  const height = labels.length / width;
  const statsByLabel = new Map<number, { count: number; sumX: number; sumY: number }>();
  const edgesByLabel = new Map<number, number[]>();
  const vertexWidth = width + 1;
  for (let index = 0; index < labels.length; index += 1) {
    const label = labels[index];
    if (label === 0) continue;
    const x = index % width;
    const y = Math.floor(index / width);
    const stats = statsByLabel.get(label);
    if (stats) { stats.count += 1; stats.sumX += x + 0.5; stats.sumY += y + 0.5; }
    else statsByLabel.set(label, { count: 1, sumX: x + 0.5, sumY: y + 0.5 });
    const edges = edgesByLabel.get(label) ?? [];
    if (y === 0 || labels[index - width] !== label) edges.push((y * vertexWidth + x) * 4);
    if (x === width - 1 || labels[index + 1] !== label) edges.push((y * vertexWidth + x + 1) * 4 + 1);
    if (y === height - 1 || labels[index + width] !== label) edges.push(((y + 1) * vertexWidth + x + 1) * 4 + 2);
    if (x === 0 || labels[index - 1] !== label) edges.push(((y + 1) * vertexWidth + x) * 4 + 3);
    edgesByLabel.set(label, edges);
  }
  return [...edgesByLabel.entries()]
    .sort(([left], [right]) => left - right)
    .map(([label, edges]) => {
      const stats = statsByLabel.get(label)!;
      const contour = largestBoundaryLoop(edges, vertexWidth);
      if (contour.length < 3) throw new InferenceError("invalid-model-output", `Label ${label} has no closed boundary`, null);
      return {
        id: `model-cell-${label}`,
        centroidPx: { x: stats.sumX / stats.count, y: stats.sumY / stats.count },
        contourPx: contour,
        confidence: 1,
        origin: "model" as const,
      };
    });
}

function labelsFromTensor(tensor: OrtTensorLike, expectedLength: number, modelId: ModelId): Uint32Array {
  if (tensor.data.length !== expectedLength) {
    throw new InferenceError(
      "invalid-model-output",
      `${modelId}: label map has ${tensor.data.length} values, expected ${expectedLength}`,
      modelId,
    );
  }
  const labels = new Uint32Array(expectedLength);
  for (let index = 0; index < expectedLength; index += 1) {
    const value = Number(tensor.data[index]);
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new InferenceError("invalid-model-output", `${modelId}: label map contains an invalid label`, modelId);
    }
    labels[index] = value;
  }
  return labels;
}

export class WebGpuInference implements InferenceEngine {
  private ortPromise: Promise<OrtModuleLike> | null = null;
  private readonly sessions = new ReusableSessionSlot<OrtSessionLike>();

  constructor(private readonly artifactCache: ModelArtifactCache | null = null) {}

  private loadOrt(): Promise<OrtModuleLike> {
    this.ortPromise ??= import("onnxruntime-web/webgpu") as unknown as Promise<OrtModuleLike>;
    return this.ortPromise;
  }

  private async sessionFor(manifest: ModelManifest, signal: AbortSignal | undefined): Promise<{ ort: OrtModuleLike; session: OrtSessionLike }> {
    const key = `${manifest.id}@${manifest.manifestVersion}:${manifest.artifact.sha256}`;
    const ort = await this.loadOrt();
    const session = await this.sessions.acquire(key, async () => {
      const bytes = await fetchArtifact(manifest, this.artifactCache, signal);
      return ort.InferenceSession.create(new Uint8Array(bytes), {
        executionProviders: ["webgpu"],
        graphOptimizationLevel: "all",
        enableCpuMemArena: false,
      });
    });
    return { ort, session };
  }

  async dispose(): Promise<void> {
    await this.sessions.dispose();
  }

  async analyze(request: WebInferenceRequest): Promise<DetectionResultDTO> {
    const modelId = request.parameters.modelId;
    const manifest = getModelManifest(modelId);
    try {
      abortIfNeeded(request.signal, modelId);
      request.onProgress?.({ stage: "environment", completed: 0, total: 1 });
      await assertWebGpuAvailable();
      request.onProgress?.({ stage: "environment", completed: 1, total: 1 });
      abortIfNeeded(request.signal, modelId);

      request.onProgress?.({ stage: "model", completed: 0, total: 1 });
      const { ort, session } = await this.sessionFor(manifest, request.signal);
      request.onProgress?.({ stage: "model", completed: 1, total: 1 });
      abortIfNeeded(request.signal, modelId);

      request.onProgress?.({ stage: "decode", completed: 0, total: 1 });
      const pixels = await decodeImage(request.source);
      request.onProgress?.({ stage: "decode", completed: 1, total: 1 });
      abortIfNeeded(request.signal, modelId);

      {
        const tileSize = manifest.input.tileSize;
        const xOrigins = tileOrigins(pixels.width, tileSize, manifest.input.overlapPx);
        const yOrigins = tileOrigins(pixels.height, tileSize, manifest.input.overlapPx);
        const totalTiles = xOrigins.length * yOrigins.length;
        const stitcher = new IncrementalLabelStitcher(pixels.width, pixels.height);
        let completedTiles = 0;
        request.onProgress?.({ stage: "inference", completed: 0, total: totalTiles });
        for (const originY of yOrigins) {
          for (const originX of xOrigins) {
            abortIfNeeded(request.signal, modelId);
            const input = normalizedTile(pixels, originX, originY, tileSize);
            const tensor = new ort.Tensor("float32", input, [1, 3, tileSize, tileSize]);
            let outputs: Record<string, OrtTensorLike> = {};
            try {
              outputs = await session.run({ [manifest.input.name]: tensor });
              const output = outputs[manifest.output.name];
              if (!output) {
                throw new InferenceError("invalid-model-output", `${modelId}: output ${manifest.output.name} is missing`, modelId);
              }
              stitcher.add({ originX, originY, width: tileSize, height: tileSize, labels: labelsFromTensor(output, tileSize * tileSize, modelId) });
            } finally {
              await disposeTileTensors(tensor, outputs);
            }
            completedTiles += 1;
            request.onProgress?.({ stage: "inference", completed: completedTiles, total: totalTiles });
          }
        }
        abortIfNeeded(request.signal, modelId);
        const labels = stitcher.finish();
        request.onProgress?.({ stage: "postprocess", completed: 0, total: 1 });
        const cells = measureCells(
          labelMapToGeometry(labels, pixels.width),
          request.calibration,
          { widthPx: pixels.width, heightPx: pixels.height },
          request.parameters.sizeThresholdsUm,
        );
        request.onProgress?.({ stage: "postprocess", completed: 1, total: 1 });
        return { imageWidth: pixels.width, imageHeight: pixels.height, cells, imageStats: {} };
      }
    } catch (error) {
      throw normalizeInferenceError(error, modelId);
    }
  }
}
