import type { WorkbenchJob, WorkbenchSummary, WorkbenchWorkflow } from "./protocol";
import type { PackageInspection } from "./extensionProtocol";
import type { GraphJobSummary } from "./graphProtocol";

export type DistributionScientificSummary = Partial<WorkbenchSummary> | GraphJobSummary;

export interface DistributionRequirements {
  pluginIds: string[]; modelIds: string[]; requiresExportDestination: boolean;
}
export interface DistributionInput {
  index: number; sourceImageId: string; imageName?: string; target: "plane" | "volume";
  timeIndex?: number; channel?: number;
  nodeCheckpointCount?: number; newImageCount?: number; segmentationBranchCount?: number;
}
export interface DistributionSummary {
  id: string; name: string; createdAt: string; createdRevision: number;
  workflow: Pick<WorkbenchWorkflow, "id" | "name" | "version" | "kind">;
  taskCount: number; collectedCount: number; sourceInputsCurrent: boolean; staleImageIds: string[];
  status: "pending" | "partial" | "collected"; notes: string[];
}
export interface DistributionTask extends DistributionInput {
  id: string; imageId: string; status: "pending" | "bundled" | "collected";
  bundle?: { destination: string; sha256: string; exportedAt: string; revision: number };
  result?: { snapshotHash: string; sourcePackageHash: string; summary: DistributionScientificSummary;
    jobId: string; sourceProjectId: string; collectedAt: string; revision: number; collectionMode: "isolated-project" };
}
export interface Distribution extends DistributionSummary { tasks: DistributionTask[] }
export interface DistributionPreview {
  plan: { workflow: DistributionSummary["workflow"]; taskCount: number; tasks: DistributionInput[];
    nodeCheckpointCount?: number;
    requirements: DistributionRequirements; referenceImageIds: string[]; limits: Record<string, number>; notes: string[] };
}
export interface RestoredDistributedTask {
  id: string; distributionId: string; coordinatorProjectId: string; definitionHash: string;
  workflow: WorkbenchWorkflow; sourceImageId: string; imageId: string;
  target: "plane" | "volume"; timeIndex?: number; channel?: number;
  prepared: boolean; jobId: string | null; job: WorkbenchJob | null;
  requirements: DistributionRequirements;
  runtime: { coordinator: Record<string, unknown>; prepared?: Record<string, unknown>; differences: string[];
    current?: Record<string, unknown>; currentDifferences?: string[] };
}
export interface DistributionResultPreview {
  taskId: string; previewFingerprint: string; collectionMode: "isolated-project";
  package: PackageInspection["package"]; job: WorkbenchJob; summary: DistributionScientificSummary;
  runtimeDifferences: string[]; notes: string[];
}
export type DistributionMutationOperation = "distribution.create" | "distribution.result.collect";
export type DistributionExportRequest =
  { kind: "task-bundle" | "collected-result"; distributionId: string; taskId: string; name: string } |
  { kind: "completed-task"; name: string };
export interface DistributedActions {
  mutate: <T>(operation: DistributionMutationOperation, args: Record<string, unknown>, accepted?: (result: T) => void) => Promise<void>;
  chooseResult: (selected: (path: string) => void) => Promise<void>;
  prepare: (allowRuntimeDifferences: boolean) => Promise<void>;
  exportPackage: (options: DistributionExportRequest) => Promise<void>;
}
