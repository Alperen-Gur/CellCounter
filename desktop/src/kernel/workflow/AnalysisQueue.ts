import type { DetectionParams, DetectionResultDTO } from "../types";

export type JobStatus = "draft" | "running" | "paused" | "completed" | "failed";
export type ItemStatus = "pending" | "running" | "completed" | "failed";
export type AnalysisTask = "countCells" | "nuclei" | "markerPositive" | "woundClosure";
export interface AnalysisItem {
  imageId: string;
  fileName: string;
  path: string;
  status: ItemStatus;
  error?: string;
  detectionId?: string;
  settingsKey?: string;
}
export interface AnalysisJob {
  id: string;
  batchId: string;
  name: string;
  createdAt: string;
  status: JobStatus;
  task: AnalysisTask;
  calibrationSource: string;
  params: DetectionParams;
  items: AnalysisItem[];
  error?: string;
}
export interface QueueRuntime {
  load(): Promise<AnalysisJob[] | null>;
  save(jobs: readonly AnalysisJob[]): Promise<void>;
  available(modelId: string): Promise<{ installed: boolean; reason?: string }>;
  detect(item: AnalysisItem, params: DetectionParams, signal: AbortSignal): Promise<DetectionResultDTO>;
  commit(item: AnalysisItem, result: DetectionResultDTO, job: AnalysisJob): Promise<string>;
  resultExists(item: AnalysisItem): Promise<boolean>;
}

export function settingsKey(params: DetectionParams): string {
  return JSON.stringify(Object.keys(params).sort().map(key => [key, params[key as keyof DetectionParams]]));
}

/** Durable metadata only: contours stay in the image database, never in the job list. */
export class AnalysisQueue {
  private jobs: AnalysisJob[] = [];
  private listeners = new Set<() => void>();
  private writes: Promise<void> = Promise.resolve();
  private initialized?: Promise<void>;
  private active?: { jobId: string; pause: boolean; controller: AbortController };
  private runtime: QueueRuntime;
  constructor(runtime: QueueRuntime) { this.runtime = runtime; }
  getSnapshot = (): readonly AnalysisJob[] => this.jobs;
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  };
  private emit() { for (const listener of this.listeners) listener(); }
  initialize(): Promise<void> {
    return this.initialized ??= (async () => {
      const saved = await this.runtime.load() ?? [];
      if (!Array.isArray(saved) || saved.some(job => !job.id || !job.params || !Array.isArray(job.items))) {
        throw new Error("Saved processing jobs could not be read. Your image library has not been changed.");
      }
      this.jobs = saved.map(job => ({ ...job,
        status: job.status === "running" ? "paused" : job.status,
        items: job.items.map(item => ({ ...item, status: item.status === "running" ? "pending" : item.status })),
      }));
      await this.runtime.save(this.jobs);
      this.emit();
    })().catch(error => { this.initialized = undefined; throw error; });
  }
  private change(edit: (jobs: AnalysisJob[]) => void): Promise<void> {
    const write = this.writes.then(async () => {
      const next = structuredClone(this.jobs);
      edit(next);
      await this.runtime.save(next);
      this.jobs = next;
      this.emit();
    });
    this.writes = write.catch(() => {});
    return write;
  }
  async create(job: Omit<AnalysisJob, "id" | "createdAt" | "status">): Promise<string> {
    await this.initialize();
    const id = crypto.randomUUID();
    await this.change(jobs => jobs.unshift({ ...structuredClone(job), id, createdAt: new Date().toISOString(), status: "draft" }));
    return id;
  }
  async update(id: string, params: DetectionParams, task: AnalysisTask, calibrationSource: string): Promise<void> {
    if (this.active?.jobId === id) throw new Error("Pause processing before changing this setup.");
    if ((params.segmentChannel != null && (!Number.isInteger(params.segmentChannel) || params.segmentChannel < 0)) || (params.zProjection !== undefined && !["max", "mean", "sum", "none"].includes(params.zProjection)) || !Number.isFinite(params.pxPerUm) || params.pxPerUm <= 0 || !Number.isFinite(params.confidenceThreshold) || params.confidenceThreshold < 0 || params.confidenceThreshold > 1 || !Number.isFinite(params.expectedDiameterUm) || params.expectedDiameterUm < 0) {
      throw new Error("Enter a positive pixel scale, confidence between 0 and 1, and a non-negative diameter.");
    }
    await this.change(jobs => {
      const job = jobs.find(job => job.id === id);
      if (!job) throw new Error("This processing job no longer exists.");
      const changed = settingsKey(job.params) !== settingsKey(params);
      Object.assign(job, { params: structuredClone(params), task, calibrationSource, status: "draft", error: undefined });
      if (changed) for (const item of job.items) Object.assign(item, { status: "pending", error: undefined });
    });
  }
  pause(id: string) {
    if (this.active?.jobId === id) { this.active.pause = true; this.jobs = [...this.jobs]; this.emit(); }
  }
  isPausing(id: string) { return this.active?.jobId === id && this.active.pause; }
  isActive() { return this.active !== undefined; }
  cancel(id: string) {
    if (this.active?.jobId === id) { this.active.pause = true; this.active.controller.abort(); }
  }
  async remove(id: string): Promise<void> {
    if (this.active?.jobId === id) throw new Error("Pause this job before removing it.");
    await this.change(jobs => { const index = jobs.findIndex(job => job.id === id); if (index >= 0) jobs.splice(index, 1); });
  }
  async clear(): Promise<void> {
    if (this.active) throw new Error("Wait for processing to stop before resetting data.");
    await this.change(jobs => jobs.splice(0));
  }
  async run(id: string, previewImageId?: string): Promise<void> {
    await this.initialize();
    if (this.active) throw new Error("Another analysis is running. Pause it before starting this job.");
    const source = this.jobs.find(job => job.id === id);
    if (!source) throw new Error("This job no longer exists.");
    if (previewImageId && !source.items.some(item => item.imageId === previewImageId)) throw new Error("Choose an image from this job.");
    const job = structuredClone(source);
    const token = { jobId: id, pause: false, controller: new AbortController() };
    this.active = token;
    const patch = (edit: (job: AnalysisJob) => void) => this.change(jobs => {
      const current = jobs.find(job => job.id === id);
      if (!current) throw new Error("This job no longer exists.");
      edit(current);
    });
    try {
      await patch(job => { job.status = "running"; job.error = undefined; });
      const availability = await this.runtime.available(job.params.modelId);
      if (!availability.installed) throw new Error(availability.reason ?? "Install this model from Models, then resume this job.");
      const key = settingsKey(job.params);
      for (const item of job.items) {
        if (token.pause) break;
        if (previewImageId && item.imageId !== previewImageId) continue;
        if (item.status === "completed" && item.settingsKey === key && await this.runtime.resultExists(item)) continue;
        await patch(current => { Object.assign(current.items.find(row => row.imageId === item.imageId)!, { status: "running", error: undefined }); });
        try {
          const result = await this.runtime.detect(item, job.params, token.controller.signal);
          if (token.controller.signal.aborted) throw new Error("Analysis cancelled.");
          const detectionId = await this.runtime.commit(item, result, job);
          await patch(current => { Object.assign(current.items.find(row => row.imageId === item.imageId)!, { status: "completed", detectionId, settingsKey: key, error: undefined }); });
        } catch (error) {
          await patch(current => { Object.assign(current.items.find(row => row.imageId === item.imageId)!, {
            status: token.controller.signal.aborted ? "pending" : "failed",
            error: token.controller.signal.aborted ? undefined : error instanceof Error ? error.message : String(error),
          }); });
          if (token.controller.signal.aborted) break;
        }
      }
      await patch(current => {
        current.status = token.pause ? "paused" : previewImageId ? "draft" : current.items.some(item => item.status === "failed") ? "failed" : "completed";
      });
    } catch (error) {
      await patch(current => {
        current.status = token.controller.signal.aborted ? "paused" : "failed";
        current.error = error instanceof Error ? error.message : String(error);
      });
      throw error;
    } finally { this.active = undefined; this.emit(); }
  }
}
