import type { ParameterSpec, ParameterValue } from "./extensionProtocol";
import type { PreprocessingRecipeStep } from "./preprocessingProtocol";
import type { WorkbenchWorkflow, WorkflowSourceSelection } from "./protocol";

export type GraphNodeType = "preprocessing" | "analysis" | "volume-analysis" | "model-segmentation" |
  "plugin-segmentation" | "measurements" | "assay" | "plugin-measurement" | "review" | "mask-merge" | "summary" | "export";
export type GraphOutputKind = "raw" | "raw-measured" | "analyzed" | "summary" | "export";
export interface WorkflowGraphNode {
  id: string; name?: string; type: GraphNodeType; input?: string; inputs?: string[];
  sourceChannel?: number; nuclearInput?: string; somaInput?: string; prompt?: string; requireHuman?: boolean;
  mode?: "union" | "intersection"; connectivity?: "faces" | "full";
  parameters?: Record<string, ParameterValue>; recipe?: PreprocessingRecipeStep[];
  modelId?: string; modelParameters?: Record<string, ParameterValue>;
  pluginId?: string; pluginParameters?: Record<string, ParameterValue>;
  assay?: string; assayParameters?: Record<string, ParameterValue>;
  sourceParameters?: Record<string, ParameterValue>; channel?: number; target?: "plane" | "volume";
  destination?: string; engineVersion?: string; packageHash?: string; backend?: string;
  inferenceSchemaHash?: string;
  checkpointHash?: string; pythonHash?: string; pythonPath?: string; environmentHash?: string;
  assayDefinitionHash?: string; usesExecutableCode?: boolean;
}
export interface WorkflowGraph {
  schemaVersion: 1; target: "plane" | "volume";
  sourceParameters?: { channel: number; zProjection: "max" | "mean" | "middle" };
  channel?: number; nodes: WorkflowGraphNode[];
}
export interface GraphObjectSchema {
  type?: string; properties?: Record<string, ParameterSpec | GraphObjectSchema>;
  required?: string[]; [key: string]: unknown;
}
export interface GraphCatalogue {
  nodeTypes: { type: GraphNodeType; name: string; inputKinds: GraphOutputKind[];
    outputKind: GraphOutputKind | "input-dependent"; schema: GraphObjectSchema; previewSupported?: boolean }[];
  assayPorts?: { assay: string; requiresAnalysis: boolean; pairedPort: "nuclearInput" | "somaInput" | null }[];
  graphSchema: GraphObjectSchema; limits: Record<string, number>; notes: string[];
}
export interface GraphPreview {
  graph: WorkflowGraph; order: string[];
  nodeOutputs: { nodeId: string; outputKind: GraphOutputKind; processed?: boolean;
    selection?: { target: "plane" | "volume"; channel: number; zProjection?: string; timeIndex?: number } }[];
  plan?: { sourceCount: number; checkpointCount: number; nodeCheckpointCount: number;
    newImageCount: number; segmentationBranchCount: number };
  limits: Record<string, number>; notes: string[];
}
export interface GraphBinding {
  imageId?: string; workingImageId?: string; selection?: WorkflowSourceSelection;
  sourceHash?: string;
  target?: "plane" | "volume"; timeIndex?: number; channel?: number;
  [key: string]: unknown;
}
export interface GraphNodeCheckpoint {
  nodeId: string; status: string; inputBinding?: GraphBinding; outputBinding?: GraphBinding;
  stepResults?: unknown; completedRevision?: number;
  reusedFrom?: unknown; correctionOrigin?: unknown; review?: unknown;
}
export interface GraphReview {
  jobId: string; checkpointIndex: number; nodeId: string; prompt: string; requireHuman: boolean;
  inputBinding: GraphBinding; inputFingerprint: string; inputsCurrent: boolean;
  recommendations: { id: string; recommendation: string; reason: string; at: string; actor: { kind: string; name: string } }[];
  decisions: { id: string; decision: string; reason: string; at: string; reviewerKind: string; actor: { kind: string; name: string } }[];
  decision: GraphReview["decisions"][number] | null; nextActions: string[]; identityNote: string;
}
export interface GraphContinuation {
  plan: { sourceJobId: string; checkpointIndex: number; sourceImageId: string; sourceSelection: WorkflowSourceSelection;
    corrections: { nodeId: string; imageId: string; inputBinding: GraphBinding }[];
    reusedNodeIds: string[]; resetNodeIds: string[]; newImageCount: number; notes: string[] };
  previewFingerprint: string;
}
export interface GraphControlActions {
  run: (action: () => Promise<void>) => Promise<void>;
  mutate: (operation: "job.graph.review.recommend" | "job.graph.review.decide" | "job.graph.continue.run", args: Record<string, unknown>, expectedRevision: number) => Promise<void>;
  chooseExport: (accepted: (path: string) => void) => Promise<void>;
  openInput: (binding: GraphBinding) => Promise<void>;
}
export interface GraphJobSummary {
  kind: "dag"; scope: "separate-technical-branches"; sourceImageIds: string[]; notes: string[];
  branches: { nodeId: string; nodeName?: string; records: { sourceImageId: string; sourceSelection: WorkflowSourceSelection;
    imageId: string; selection: WorkflowSourceSelection; summary: Record<string, unknown>; stepResults?: unknown }[] }[];
}
export interface GraphNodePreview {
  nodeId: string; checkpointIndex: number; sourceImageId: string; sourceSelection: WorkflowSourceSelection;
  inputBinding: GraphBinding; operation: string; mode: "fresh-calculation" | "retained-measurements";
  inputsCurrent: boolean; dependencyReasons: unknown[]; notes: string[];
  preview: Record<string, unknown>;
}
export type PreviewGraphNode = (args: { jobId: string; checkpointIndex: number; nodeId: string; maxSize?: number },
  accepted: (result: GraphNodePreview) => void) => Promise<void>;
export type SaveWorkflow = (operation: "workflow.save" | "workflow.graph.save", args: Record<string, unknown>,
  accepted: (workflow: WorkbenchWorkflow) => void) => Promise<void>;
export type CreateWorkflowJob = (workflow: WorkbenchWorkflow, imageIds: string[], timeIndices?: number[]) => Promise<void>;

export const isGraphWorkflow = (workflow?: WorkbenchWorkflow) => workflow?.kind === "dag";
export const workflowHasExport = (workflow: WorkbenchWorkflow) => isGraphWorkflow(workflow)
  ? workflow.graph?.nodes.some((node) => node.type === "export") === true
  : workflow.steps.some((step) => step.type === "export");
