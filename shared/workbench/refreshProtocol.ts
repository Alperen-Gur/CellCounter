export type RefreshKind = "derived-image" | "tracks" | "lineage" | "assay" | "assay-series" | "plugin-measurement" | "statistics";
export type RefreshDependencyMode = "transitive" | "measurements";
export interface RefreshRunRef { kind: RefreshKind; runId: string }
export interface RefreshReason { code: string; message: string; imageId?: string }
export interface RefreshOutput extends RefreshRunRef {
  imageId: string; imageName: string; label: string; target: "plane" | "volume";
  timeIndex?: number; channel?: number; logicalKey: string; latest: boolean;
  createdAt?: string; revision?: number; status: "current" | "stale" | "blocked";
  freshness: "current" | "stale"; recomputable: boolean;
  reasons: RefreshReason[]; blockers: RefreshReason[]; replacementRunId?: string;
}
export interface RefreshInspection {
  outputs: RefreshOutput[];
  dependencyMode?: RefreshDependencyMode;
  unhandled: { kind: string; imageId?: string; status: string; message: string; action?: string }[];
  counts: { current: number; stale: number; blocked: number; total: number };
  limits: { jobs: number; unitsPerJob: number; outputs: number }; notes: string[];
}
export interface RefreshPlanUnit extends Omit<RefreshOutput, "status"> {
  id?: string; dependsOn?: string[];
  status: "ready" | "blocked"; arguments: Record<string, unknown>;
  dependencies: Record<string, unknown>[]; binding: Record<string, unknown>; inputFingerprint: string;
}
export interface RefreshPreview {
  plan: { sourceRevision: number; units: RefreshPlanUnit[]; readyCount: number; blockedCount: number;
    dependencyMode?: RefreshDependencyMode;
    assignmentTransfers?: { imageId: string; specimenId: string; producerUnitId: string }[];
    usesExecutableCode: boolean; notes: string[] };
  previewFingerprint: string;
}
export interface RefreshUnit extends Omit<RefreshPlanUnit, "status"> {
  id: string; status: "pending" | "completed"; resultRunId?: string; resultImageId?: string; resultOutputHash?: string; completedRevision?: number;
}
export interface RefreshJobSummary {
  dependencyMode?: RefreshDependencyMode; inputsCurrent?: boolean;
  imageReplacements?: { previousImageId: string; imageId: string; unitId: string }[];
  runReplacements?: { kind: RefreshKind; previousRunId: string; runId: string; unitId: string }[];
  id: string; name: string; status: "pending" | "running" | "paused" | "blocked" | "failed" | "cancelled" | "completed";
  progress: { completed: number; total: number }; outputsCurrent: boolean; staleUnitIds: string[];
  nextUnit: { unitId: string; kind: RefreshKind; runId: string; imageId: string } | null;
  createdAt: string; createdRevision: number; definitionHash: string; usesExecutableCode: boolean;
  skippedCount: number; error?: { code: string; message: string };
}
export interface RefreshJob extends RefreshJobSummary {
  units: RefreshUnit[]; skipped: RefreshPlanUnit[];
  replacements: { kind: RefreshKind; previousRunId: string; runId: string; imageId?: string; unitId?: string }[];
  assignmentTransfers?: { unitId: string; previous: { imageId: string; specimenId: string }; imageId: string; revision: number }[];
}
export interface RefreshReport {
  schemaVersion: 1; refresh: RefreshJob; sourceRevision: number; complete: boolean; outputsCurrent: boolean;
  notes: string[]; reportEngineVersion: "refresh-reports-1"; executionComplete: boolean; coverageComplete: boolean;
}
export interface RefreshExportFormat {
  id: "results-json" | "results-csv"; name: string; extension: string; mediaType: string; description: string;
}
export interface RefreshExportResult {
  exportId: string; destination: string; sha256: string; format: string; mediaType: string; bytes: number;
  refreshId: string; provenance: Record<string, unknown>; provenanceSha256: string;
}
export type RefreshMutationOperation = "refresh.create" | "refresh.advance" | "refresh.pause" | "refresh.resume" |
  "refresh.retry" | "refresh.cancel" | "refresh.worker.start";
export interface RefreshActions {
  mutate: <T>(operation: RefreshMutationOperation, args: Record<string, unknown>, accepted?: (result: T) => void) => Promise<void>;
  run: (refreshId: string) => Promise<void>; stop: () => void;
  stopWorker: (workerId: string) => Promise<void>;
  exportReport: (format: RefreshExportFormat, refreshId: string, name: string) => Promise<void>;
}
