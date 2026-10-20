import type { ParameterSpec, ParameterValue } from "./extensionProtocol";
import type { WorkbenchJob, WorkbenchWorkflow, WorkflowStep, WorkflowSourceSelection } from "./protocol";
import type { WorkflowGraph } from "./graphProtocol";

export type SweepScalar = ParameterValue | null;
export type SweepAddress = { stepIndex: number; nodeId?: never } | { nodeId: string; stepIndex?: never };
export type SweepAxis = SweepAddress & { path: string; values: SweepScalar[] };
export type SweepParameter = SweepAddress & {
  path: string; label: string; nodeName?: string;
  schema: ParameterSpec & { exclusiveMinimum?: number };
  currentValue?: SweepScalar; present: boolean; canOmit: boolean;
};
export interface SweepParameters {
  workflow: Pick<WorkbenchWorkflow, "id" | "name" | "version" | "kind">;
  candidatePaths: SweepParameter[]; limits: Record<string, number>; notes: string[];
}
export type SweepValue = SweepAddress & { path: string; value: SweepScalar; nodeName?: string };
export interface SweepPreview {
  combinationCount: number; requiredVariantCount: number; requiredProcessedCount: number; requiredImageCount: number;
  checkpointCount?: number;
  requiredBranchImageCount?: number; nodeCheckpointCount?: number;
  combinations: { index: number; values: SweepValue[]; steps: WorkflowStep[]; graph?: WorkflowGraph;
    checkpointCount?: number; target?: "plane" | "volume" }[];
  candidatePaths: SweepParameter[]; requiresExportDirectory: boolean;
  limits: Record<string, number>; notes: string[];
}
export interface SweepSummary {
  id: string; name: string; status: WorkbenchJob["status"]; progress: { completed: number; total: number };
  combinationCount?: number; completedCombinations?: number;
  nextJobId?: string | null; outputsCurrent: boolean; sourceInputsCurrent: boolean;
}
export interface WorkbenchSweep extends SweepSummary {
  baseWorkflow: WorkbenchWorkflow; imageIds: string[]; axes: SweepAxis[];
  combinations: {
    index: number; values: SweepValue[]; jobId: string; workflowId: string; workflowVersion: number;
    variants: { sourceImageId: string; imageId: string }[]; graph?: WorkflowGraph;
  }[];
  jobs?: WorkbenchJob[]; notes: string[];
}
export interface SweepResultCombination {
  index: number; jobId: string; status: WorkbenchJob["status"]; values: SweepValue[];
  totalInputs: number; currentInputs: number; pendingInputs: number; staleInputs: number;
  objectObservations: number | null; availableObjectObservations: number | null; comparisonComplete: boolean;
  branchResults?: { nodeId: string; nodeName: string; totalInputs: number; currentInputs: number; pendingInputs: number;
    staleInputs: number; objectObservations: number | null; availableObjectObservations: number | null; comparisonComplete: boolean; objectsAvailable?: boolean }[];
}
export interface SweepResultRow {
  combinationIndex: number; jobId: string; sourceImageId: string; sourceName: string;
  nodeId?: string; nodeName?: string;
  objectsAvailable?: boolean; assayRunId?: string;
  assayMetrics?: { fields: Record<string, number | null>; units: unknown; notes: string[]; truncated: boolean };
  variantImageId: string; workingImageId: string | null; target: "plane" | "volume";
  sourceSelection: WorkflowSourceSelection; selection: WorkflowSourceSelection;
  checkpointStatus: string; status: "current" | "pending" | "incomplete" | "stale" | "unavailable";
  reason: string | null; analysisRevision: number | null; measurementRevision: number | null;
  labelsSha256: string | null; intensityUnits: string | null;
  sourceHash?: string | null; voxelSizeUm?: { x: number | null; y: number | null; z: number | null } | null;
  metrics: null | {
    objectCount: number | null; foregroundSamples: number | null; meanObjectSizeSamples: number | null;
    totalPhysicalSize: number | null; meanObjectPhysicalSize: number | null;
    physicalSizeUnit: "um2" | "um3" | null; meanObjectIntensity: number | null;
  };
}
export function sweepAddressLabel(value: { nodeId?: string; nodeName?: string; stepIndex?: number }): string {
  return value.nodeId ? `Node ${value.nodeName || value.nodeId}` : `Step ${(value.stepIndex ?? 0) + 1}`;
}
export interface SweepResults {
  sweepId: string; name: string; sourceRevision: number; definitionHash: string;
  sourceInputsCurrent: boolean; complete: boolean; combinations: SweepResultCombination[];
  baseWorkflow?: WorkbenchWorkflow;
  rows: SweepResultRow[]; pagination: { offset: number; limit: number; total: number; nextOffset: number | null };
  notes: string[];
}
export type SweepExportFormatId = "results-json" | "results-csv";
export interface SweepExportFormat {
  id: SweepExportFormatId; name: string; extension: string; mediaType: string; description: string;
}
export interface SweepExportArguments { sweepId: string; format: SweepExportFormatId }
export interface SweepExportResult {
  exportId: string; destination: string; sha256: string; format: SweepExportFormatId;
  mediaType: string; bytes: number; sweepId: string; provenance: Record<string, unknown>;
}
