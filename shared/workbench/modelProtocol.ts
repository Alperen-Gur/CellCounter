import type { EvaluationMetrics, ParameterSpec, ParameterValue } from "./extensionProtocol";

export type ModelBackend = "cellpose3" | "cellpose4" | "stardist2d" | "omnipose" | "micro-sam";
export interface ModelInferenceSchema {
  properties: Record<string, ParameterSpec & { exclusiveMinimum?: number; exclusiveMaximum?: number }>;
  required: string[];
}
export interface ModelBackendDefinition {
  id: ModelBackend; name: string; dimensions: number[]; supportsTraining: boolean;
  inferenceSchema: ModelInferenceSchema; notes: string[];
  registrationSchema?: ModelInferenceSchema;
  fileInputs?: { key: "configPath" | "thresholdsPath"; name: string; required: boolean }[];
  maxCheckpointBytes?: number;
}
export interface ModelCatalogue { backends: ModelBackendDefinition[]; defaultBackend: ModelBackend }

export interface WorkbenchModel {
  id: string; name: string; backend: ModelBackend; enabled: boolean;
  pythonPath: string; pythonHash: string; checkpointHash: string;
  createdAt: string; registeredRevision: number;
  inferenceSchema?: ModelInferenceSchema; supportsTraining?: boolean; notes?: string[];
  registrationConfig?: Record<string, ParameterValue>; registrationConfigHash?: string; artifactSetHash?: string;
  environmentStatus?: "unrecorded" | "captured" | "binding-changed";
  activeEnvironmentId?: string | null;
  activeEnvironmentHash?: string | null;
  environmentCount?: number;
}
export interface ModelEnvironmentInventory {
  schemaVersion: 1; kind: "python-environment";
  python: { implementation: string; version: string; cacheTag: string | null };
  platform: { system: string; machine: string; byteOrder: string };
  packages: { name: string; version: string }[]; hash: string;
}
export interface ModelEnvironmentRecord {
  id: string; hash: string; pythonPath: string; pythonHash: string;
  capturedAt: string; capturedRevision: number; actor: { kind: string; name: string };
  summary: { hash: string; pythonVersion: string; implementation: string; system: string; machine: string; packageCount: number };
}
export interface ModelEnvironmentInspection {
  modelId: string; activeEnvironmentId: string | null;
  environments: ModelEnvironmentRecord[];
  environment: (ModelEnvironmentRecord & { inventory: ModelEnvironmentInventory }) | null;
}
export function inferenceSchemaFor(model: WorkbenchModel | undefined, catalogue?: ModelCatalogue): ModelInferenceSchema | undefined {
  return model?.inferenceSchema ?? catalogue?.backends.find((backend) => backend.id === model?.backend)?.inferenceSchema;
}
export function modelParameterIssues(schema: ModelInferenceSchema | undefined, values: Record<string, ParameterValue>): string[] {
  if (!schema) return ["The selected model's parameter definition is unavailable."];
  const issues: string[] = [];
  for (const key of schema.required ?? []) {
    if (values[key] === undefined && schema.properties[key]?.default === undefined) issues.push(`${key} is required.`);
  }
  for (const [key, value] of Object.entries(values)) {
    const spec = schema.properties[key];
    if (!spec) { issues.push(`${key} is not supported by this model backend.`); continue; }
    const name = spec.title ?? key;
    if ((spec.type === "boolean" && typeof value !== "boolean") ||
      (spec.type === "string" && typeof value !== "string") ||
      ((spec.type === "number" || spec.type === "integer") && (typeof value !== "number" || !Number.isFinite(value) ||
        (spec.type === "integer" && !Number.isInteger(value)))) || (spec.enum && !spec.enum.includes(value))) {
      issues.push(`${name} has an invalid value.`);
    } else if (typeof value === "number" &&
      ((spec.minimum !== undefined && value < spec.minimum) || (spec.maximum !== undefined && value > spec.maximum) ||
        (spec.exclusiveMinimum !== undefined && value <= spec.exclusiveMinimum) ||
        (spec.exclusiveMaximum !== undefined && value >= spec.exclusiveMaximum))) {
      issues.push(`${name} is outside its allowed range.`);
    }
  }
  return issues;
}
export interface TrainingJob {
  id: string; name: string; datasetId: string; modelId: string;
  status: "queued" | "starting" | "running" | "cancelling" | "cancelled" | "completed" | "failed" | "interrupted" | "collected";
  phase?: string; progress?: Record<string, unknown>; parameters: Record<string, unknown>;
  error?: { code: string; message: string }; resultModelId?: string;
  metrics?: EvaluationMetrics; createdAt: string;
}
