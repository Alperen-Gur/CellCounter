export interface JobWorker {
  workerId: string; jobId?: string; sweepId?: string; refreshId?: string; analysisId?: string; targetKind?: "job" | "sweep" | "refresh" | "tiled-analysis"; targetId?: string;
  status: string; createdAt: string; heartbeatAt?: string;
  targetStatus?: string; jobStatus?: string; sweepStatus?: string; refreshStatus?: string; analysisStatus?: string;
  progress?: { completed: number; total: number }; sweepDefinitionHash?: string; refreshDefinitionHash?: string; analysisDefinitionHash?: string;
  lastRevision?: number; lastRequestId?: string; lastUnit?: unknown;
  stopRequested?: boolean; reason?: string; error?: { code: string; message: string };
}
export const activeJobWorker = (worker: JobWorker) => ["queued", "starting", "running", "stopping"].includes(worker.status);
export const workerTargetKind = (worker: JobWorker): "job" | "sweep" | "refresh" | "tiled-analysis" => worker.targetKind ?? (worker.analysisId ? "tiled-analysis" : worker.refreshId ? "refresh" : worker.sweepId ? "sweep" : "job");
export const workerTargetId = (worker: JobWorker): string => worker.targetId ?? worker.analysisId ?? worker.refreshId ?? worker.sweepId ?? worker.jobId ?? worker.workerId;
