import type { ParameterValue } from "./extensionProtocol";
export interface AssayRun {
  runId: string; assay: string; imageId: string; stale: boolean; revision: number;
  target: "plane" | "volume"; parameters: Record<string, ParameterValue>;
}
export interface AssayMetrics {
  runId: string; assay: string; current: boolean; parameters: Record<string, ParameterValue>;
  metrics: { path: string; value: number }[]; notes: string[];
}
export interface AssayExperimentSummary {
  assay: string; parameters: Record<string, ParameterValue>; metricPath: string; sourceRevision: number;
  selection: { target: "plane" | "volume"; timeIndex?: number; channel?: number };
  comparison?: {
    units: Record<string, unknown>;
    processing: Record<string, unknown>;
    sourceProjection?: string;
  };
  images: { imageId: string; name: string; specimenId?: string; value: number | null;
    status: string; reason?: string; assignmentStatus?: string }[];
  specimens: { id: string; name: string; experiment: string; condition: string; role: string;
    imageCount: number; measuredImageCount: number; complete: boolean; mean: number | null }[];
  conditions: { experiment: string; condition: string; biologicalN: number;
    excludedIncompleteSpecimens: number; mean: number | null; sd: number | null }[];
  notes: string[];
}
