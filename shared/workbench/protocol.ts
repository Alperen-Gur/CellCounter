/** Shared wire types. Scientific behavior lives in shared/python. */
import type { VolumeParameters, VoxelSize } from "./volumeProtocol";
import type { AdaptationDataset, ParameterValue, WorkbenchPlugin } from "./extensionProtocol";
import type { ModelBackend, TrainingJob, WorkbenchModel } from "./modelProtocol";
import type { ReviewSession } from "./reviewProtocol";
import type { LargeSource } from "./sourceProtocol";
import type { AssayRun } from "./assayProtocol";
import type { JobWorker } from "./workerProtocol";
import type { PreprocessingRecipeStep } from "./preprocessingProtocol";
import type { SweepSummary } from "./sweepProtocol";
import type { DistributionSummary, RestoredDistributedTask } from "./distributionProtocol";
import type { DisplayPresetSummary } from "./displayPresetProtocol";
import type { RefreshJobSummary } from "./refreshProtocol";
import type { LibraryMigration } from "./migrationProtocol";
export interface AnalysisParameters {
  method: "otsu" | "triangle" | "li" | "yen" | "mean" | "adaptive" | "manual";
  threshold?: number;
  polarity: "bright" | "dark" | "auto";
  fillHoles?: boolean;
  adaptiveBlockSize?: number;
  adaptiveOffsetMode?: "auto" | "manual";
  adaptiveOffset?: number;
  minAreaPx: number;
  minDistancePx: number;
  channel: number;
  zProjection: "max" | "mean" | "middle";
}
export interface WorkbenchImage {
  id: string;
  name: string;
  notes?: string; tags?: string[]; channelNames?: string[]; archived?: boolean; metadataRevision?: number;
  width: number;
  height: number;
  channels: number;
  zCount: number;
  timeCount: number;
  voxelSizeUm?: VoxelSize;
  timeStepSeconds?: number | null;
  volumeFrameCount?: number;
  annotationCount?: number;
  referenceCurrent?: boolean;
  preferredSourceParameters?: Pick<AnalysisParameters, "channel" | "zProjection">;
  preferredVolumeSelection?: { timeIndex: number; channel: number };
  intensityUnits?: "raw-source" | "processed-source";
  validSupport?: {
    present: boolean; validPixelCount: number; invalidPixelCount: number;
    totalSampleCount: number; fraction: number; shape: number[];
    areaUm2: number | null; volumeUm3: number | null; notes: string[];
  };
  variantOf?: string;
  pxPerUm: number | null;
  sourceHash: string;
  analysisRevision?: number;
  measurementRevision?: number;
  inputFingerprint?: string;
  cellCount?: number;
  status: string;
  parameters?: AnalysisParameters;
}
export interface WorkbenchCell {
  labelId: number;
  cx: number;
  cy: number;
  areaPx: number;
  areaUm2: number | null;
  diameterUm: number | null;
  meanIntensity: number;
  contourPx?: [number, number][];
  contoursPx?: [number, number][][];
}
export interface ProjectSnapshot {
  cataloguePages?: Partial<Record<import("./catalogueProtocol").CatalogueKey, import("./catalogueProtocol").CataloguePageInfo>>;
  selectedCatalogueEntries?: import("./catalogueProtocol").CataloguePin[];
  activeJobWorkers?: JobWorker[];
  activeTrainingJobs?: TrainingJob[];
  activeWorkerCount?: number;
  activeTrainingJobCount?: number;
  assaySeriesRuns?: import("./assaySeriesProtocol").AssaySeriesRun[];
  experimentLayouts?: import("./experimentProtocol").ExperimentLayoutSummary[];
  experimentApplications?: import("./experimentProtocol").ExperimentApplicationSummary[];
  acquisitionSessions?: import("./experimentProtocol").AcquisitionSessionSummary[];
  experimentExclusions?: import("./experimentProtocol").EffectiveExperimentExclusions;
  collections?: import("./libraryProtocol").ImageCollection[];
  statisticsDesigns?: import("./statisticsProtocol").StatisticalDesign[];
  statisticsRuns?: import("./statisticsProtocol").StatisticalRun[];
  zarrSources?: import("./storageProtocol").ZarrSource[];
  tiledAnalyses?: import("./storageProtocol").TiledAnalysis[];
  workspaces?: import("./workspaceProtocol").WorkspaceDescriptor[];
  project: { id: string; name: string; revision: number };
  images: WorkbenchImage[];
  imageCount?: number; imagePageRequired?: boolean;
  storage?: { format: 1 | 2; imageCount: number; historyCount: number; limits?: Record<string, number> };
  history?: { operation: string; revision: number; actor?: { kind: string; name: string } }[];
  experimentalDesign?: ExperimentalDesign;
  jobs?: WorkbenchJob[];
  workflows?: WorkbenchWorkflow[];
  plugins?: WorkbenchPlugin[];
  adaptationDatasets?: AdaptationDataset[];
  models?: WorkbenchModel[];
  trainingJobs?: TrainingJob[];
  reviewSessions?: ReviewSession[];
  largeSources?: LargeSource[];
  assayRuns?: AssayRun[];
  jobWorkers?: JobWorker[];
  sweeps?: SweepSummary[];
  distributions?: DistributionSummary[];
  distributedTask?: RestoredDistributedTask | null;
  displayPresets?: DisplayPresetSummary[];
  refreshJobs?: RefreshJobSummary[];
  migration?: LibraryMigration | null;
}
export interface WorkbenchSummary {
  sourceRevision: number;
  imageCount: number;
  analyzedImageCount: number;
  cellCount: number;
  images: { imageId: string; name: string; cellCount: number | null;
    totalAreaPx: number | null; totalAreaUm2: number | null; meanCellIntensity: number | null }[];
  volumes?: { frameCount: number; cellCount: number; aggregation: string;
    frames: { imageId: string; name: string; timeIndex: number; channel: number; cellCount: number;
      voxelCount: number; volumeUm3: number | null }[] };
}
export interface Specimen {
  id: string; name: string; experiment: string; condition: string;
  role: "control" | "treatment" | "other";
}
export interface Plate { id: string; name: string; rows: number; columns: number }
export interface ImageAssignment {
  imageId: string; specimenId: string; plateId?: string;
  wellRow?: number; wellColumn?: number; field?: string;
}
export interface ExperimentalDesign {
  specimens: Specimen[]; plates: Plate[]; assignments: ImageAssignment[];
}
export interface ExperimentSummary {
  sourceRevision: number; unassignedImageCount: number; notes: string[];
  specimens: (Specimen & { imageCount: number; analyzedImageCount: number;
    objectCount: number; complete: boolean; meanObjectsPerImage: number | null })[];
  conditions: { experiment: string; condition: string; biologicalN: number;
    excludedIncompleteSpecimens: number; meanObjectsPerImage: number | null;
    sdObjectsPerImage: number | null; physicalBiologicalN: number; meanObjectAreaUm2: number | null }[];
}
export type WorkflowSegmentationStep =
  { type: "analysis"; parameters: AnalysisParameters } |
    { type: "volume-analysis"; parameters: VolumeParameters; channel: number } |
    { type: "plugin-segmentation"; pluginId: string; pluginParameters?: Record<string, ParameterValue>;
      target: "plane" | "volume"; sourceParameters?: AnalysisParameters; channel?: number; packageHash?: string } |
    { type: "model-segmentation"; modelId: string; modelParameters?: Record<string, ParameterValue>; sourceParameters?: AnalysisParameters;
      backend?: ModelBackend; inferenceSchemaHash?: string };
export type WorkflowMeasurementStep =
  { type: "plugin-measurement"; pluginId: string; pluginParameters?: Record<string, ParameterValue>; packageHash?: string } |
  { type: "assay"; assay: string; assayParameters?: Record<string, ParameterValue> };
export type WorkflowStep = WorkflowSegmentationStep | WorkflowMeasurementStep |
  { type: "preprocessing"; recipe: PreprocessingRecipeStep[]; engineVersion?: string } | { type: "measurements" | "summary" } |
  { type: "export"; destination?: string };
export interface WorkbenchWorkflow {
  id: string; name: string; version: number;
  steps: WorkflowStep[];
  kind?: "linear" | "dag";
  graph?: import("./graphProtocol").WorkflowGraph;
}
export type WorkflowSourceSelection = { target: "plane"; channel: number; zProjection: "max" | "mean" | "middle" } |
  { target: "volume"; timeIndex: number; channel: number };
export interface WorkbenchJob {
  id: string; name: string;
  kind?: "linear" | "dag";
  status: "pending" | "running" | "paused" | "blocked" | "failed" | "completed" | "cancelled" | "awaiting-review";
  workflow: WorkbenchWorkflow; imageIds: string[];
  workingImageIds?: string[];
  pendingReview?: import("./graphProtocol").GraphReview | null;
  continuation?: { sourceJobId: string; checkpointIndex: number; corrections: unknown[]; reusedNodeIds: string[]; reason: string };
  progress: { completed: number; total: number };
  nextUnit: { type: "preprocessing" | "image" | "volume" | "plugin" | "assay" | "summary" | "export" | "graph-node";
    imageId?: string; timeIndex?: number; channel?: number; stepIndex?: number;
    nodeId?: string; nodeType?: import("./graphProtocol").GraphNodeType; checkpointIndex?: number; nodeIndex?: number;
    workingImageId?: string; workingSelection?: WorkflowSourceSelection } | null;
  checkpoints: { imageId: string; status: string; cellCount?: number; timeIndex?: number; channel?: number;
    workingImageId?: string; derivedImageId?: string; sourceSelection?: WorkflowSourceSelection;
    workingSelection?: WorkflowSourceSelection; sourceFingerprint?: string;
    nodes?: import("./graphProtocol").GraphNodeCheckpoint[] }[];
  nodeProgress?: { nodeId: string; type: import("./graphProtocol").GraphNodeType; completed: number; total: number }[];
  staleNodeIds?: (string | { checkpointIndex: number; nodeId: string; imageId: string })[];
  summary?: import("./graphProtocol").GraphJobSummary | WorkbenchSummary;
  notes?: string[];
  error?: { code: string; message: string; details?: { nodeId?: string; [key: string]: unknown } };
  outputsCurrent?: boolean;
  staleImageIds?: string[];
}
export interface OperationRequest {
  schemaVersion: 1;
  operation: string;
  requestId: string;
  projectPath?: string;
  expectedRevision?: number;
  actor: { kind: "human" | "agent" | "cli"; name: string };
  arguments: Record<string, unknown>;
}
export type OperationResponse<T> =
  | { schemaVersion: 1; ok: true; requestId: string; operation: string; revision?: number; result: T }
  | { schemaVersion: 1; ok: false; requestId: string; operation: string; error: { code: string; message: string; details?: Record<string, unknown> } };

export const DEFAULT_ANALYSIS: AnalysisParameters = {
  method: "otsu", polarity: "bright", minAreaPx: 16, minDistancePx: 8,
  channel: 0, zProjection: "max",
};
export function updateAnalysisParameters(previous: AnalysisParameters, update: Partial<AnalysisParameters>): AnalysisParameters {
  const next = { ...previous, ...update };
  if (next.method !== "manual") delete next.threshold;
  else next.threshold ??= 0;
  if (next.method !== "adaptive") {
    delete next.adaptiveBlockSize; delete next.adaptiveOffsetMode; delete next.adaptiveOffset;
  } else {
    next.adaptiveBlockSize ??= 51; next.adaptiveOffsetMode ??= "auto";
    if (next.adaptiveOffsetMode === "manual") next.adaptiveOffset ??= 0;
    else delete next.adaptiveOffset;
  }
  return next;
}
