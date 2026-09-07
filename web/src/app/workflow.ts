import { measureCells } from "../domain/measurements";
import type { AnalysisParameters, Calibration, ImageAnalysis, ModelProvenance } from "../domain/types";

export interface RunSnapshot {
  readonly parameters: AnalysisParameters;
  readonly model: ModelProvenance;
  readonly calibration: Calibration;
}
export interface QueueItem {
  readonly imageId: string;
  readonly fileName: string;
  readonly sourceSha256: string;
  readonly calibration: Calibration;
  readonly state: "pending" | "running" | "complete" | "failed";
  readonly error?: string;
  readonly durationMs?: number;
  readonly reusedPreview?: boolean;
}
export interface AnalysisJob {
  readonly id: string;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly state: "running" | "paused" | "complete" | "failed";
  readonly settings: RunSnapshot;
  readonly items: readonly QueueItem[];
}
export interface AnalysisPreview {
  readonly id: string;
  readonly imageId: string;
  readonly key: string;
  readonly analysis: ImageAnalysis;
}
export interface MaskVariant { readonly id: string; readonly imageId: string; readonly name: string; readonly createdAt: string; readonly analysis: ImageAnalysis; }

function sorted(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, entry]) => [key, sorted(entry)]));
  return value;
}
/** Includes source bytes, all preprocessing, calibration and exact model identity. */
export function previewKey(sourceSha256: string, settings: RunSnapshot): string {
  if (!/^[a-f\d]{64}$/i.test(sourceSha256)) throw new Error("A verified source digest is required before preview or processing.");
  return JSON.stringify(sorted({ sourceSha256, ...settings }));
}
export function recoverJob(job: AnalysisJob): AnalysisJob {
  if (job.state !== "running" && !job.items.some((item) => item.state === "running")) return job;
  return { ...job, state: "paused", updatedAt: new Date().toISOString(), items: job.items.map((item) => item.state === "running" ? { ...item, state: "pending", error: "Interrupted. Resume to retry this image." } : item) };
}
export function retryJob(job: AnalysisJob): AnalysisJob {
  return { ...job, state: "paused", updatedAt: new Date().toISOString(), items: job.items.map((item) => item.state === "failed" ? { ...item, state: "pending", error: undefined } : item) };
}
export function estimatedRemainingMs(job: AnalysisJob): number | null {
  const completed = job.items.filter((item) => item.state === "complete" && !item.reusedPreview && item.durationMs !== undefined);
  return completed.length ? completed.reduce((sum, item) => sum + item.durationMs!, 0) / completed.length * job.items.filter((item) => item.state === "pending" || item.state === "running").length : null;
}
export interface QueueExecutor {
  persist(job: AnalysisJob): Promise<void>;
  process(item: QueueItem, settings: RunSnapshot, signal: AbortSignal): Promise<{ reusedPreview: boolean }>;
  changed(job: AnalysisJob): void;
}
/** A single serial runner. Writes each transition before work; pause finishes the current image. */
export class DurableQueueRunner {
  private pauseRequested = false;
  private running = false;
  private controller?: AbortController;
  constructor(private readonly executor: QueueExecutor) {}
  pause() { this.pauseRequested = true; }
  cancel() { this.pauseRequested = true; this.controller?.abort(); }
  async run(initial: AnalysisJob): Promise<AnalysisJob> {
    if (this.running) throw new Error("A processing job is already running.");
    this.running = true; this.pauseRequested = false;
    let job = { ...initial, state: "running" as AnalysisJob["state"] };
    const save = async () => { job = { ...job, updatedAt: new Date().toISOString() }; await this.executor.persist(job); this.executor.changed(job); };
    try {
      await save();
      for (let index = 0; index < job.items.length; index++) {
        if (this.pauseRequested) break;
        if (job.items[index].state !== "pending") continue;
        job = { ...job, items: job.items.map((item, at) => at === index ? { ...item, state: "running", error: undefined } : item) };
        await save();
        const started = performance.now();
        this.controller = new AbortController();
        try {
          const result = await this.executor.process(job.items[index], job.settings, this.controller.signal);
          if (this.controller.signal.aborted) throw new DOMException("Cancelled", "AbortError");
          job = { ...job, items: job.items.map((item, at) => at === index ? { ...item, state: "complete", durationMs: performance.now() - started, reusedPreview: result.reusedPreview } : item) };
        } catch (error) {
          const interrupted = this.controller.signal.aborted;
          job = { ...job, items: job.items.map((item, at) => at === index ? { ...item, state: interrupted ? "pending" : "failed", error: error instanceof Error ? error.message : String(error) } : item) };
          if (interrupted) this.pauseRequested = true;
        }
        await save();
      }
      job = { ...job, state: job.items.some((item) => item.state === "pending" || item.state === "running") ? "paused" : job.items.some((item) => item.state === "failed") ? "failed" : "complete" };
      await save();
      return job;
    } finally { this.running = false; this.controller = undefined; }
  }
}

export function restoreVariant(variant: MaskVariant, current: Calibration): ImageAnalysis {
  const analysis = variant.analysis;
  return { ...analysis, calibration: current, workflow: { ...analysis.workflow, runCalibration: analysis.workflow?.runCalibration ?? analysis.calibration }, cells: measureCells(analysis.cells, current, { widthPx: analysis.image.widthPx, heightPx: analysis.image.heightPx }, analysis.parameters.sizeThresholdsUm) };
}

export function compareMaskVariants(current: ImageAnalysis, alternative: ImageAnalysis): { added: number; removed: number; changed: number; unchanged: number } {
  const unused = new Set(alternative.cells.map((_, index) => index));
  let removed = 0; let changed = 0; let unchanged = 0;
  let bucketSize = 1;
  for (const cell of [...current.cells, ...alternative.cells]) bucketSize = Math.max(bucketSize, cell.equivalentDiameterPx);
  const buckets = new Map<string, number[]>();
  alternative.cells.forEach((cell, index) => { const key = `${Math.floor(cell.centroidPx.x / bucketSize)}:${Math.floor(cell.centroidPx.y / bucketSize)}`; const bucket = buckets.get(key) ?? []; bucket.push(index); buckets.set(key, bucket); });
  for (const cell of current.cells) {
    let best = -1; let distance = Infinity;
    const bx = Math.floor(cell.centroidPx.x / bucketSize); const by = Math.floor(cell.centroidPx.y / bucketSize);
    const candidates: number[] = [];
    for (let y = by - 1; y <= by + 1; y++) for (let x = bx - 1; x <= bx + 1; x++) candidates.push(...(buckets.get(`${x}:${y}`) ?? []));
    for (const index of candidates) {
      if (!unused.has(index)) continue;
      const next = alternative.cells[index];
      const separation = Math.hypot(cell.centroidPx.x - next.centroidPx.x, cell.centroidPx.y - next.centroidPx.y);
      if (separation <= Math.max(cell.equivalentDiameterPx, next.equivalentDiameterPx) / 2 && separation < distance) { best = index; distance = separation; }
    }
    if (best < 0) { removed++; continue; }
    unused.delete(best);
    const next = alternative.cells[best];
    const same = distance < .01 && Math.abs(cell.areaPx2 - next.areaPx2) < .01 && JSON.stringify(cell.contourPx) === JSON.stringify(next.contourPx);
    if (same) unchanged++; else changed++;
  }
  return { added: unused.size, removed, changed, unchanged };
}
