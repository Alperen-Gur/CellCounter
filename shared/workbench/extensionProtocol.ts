export type ParameterValue = string | number | boolean;
export interface ParameterSpec {
  type: "string" | "number" | "integer" | "boolean";
  title?: string; description?: string; minimum?: number; maximum?: number;
  maxLength?: number; enum?: ParameterValue[]; default?: ParameterValue;
}
export interface WorkbenchPlugin {
  pluginId: string; enabled: boolean; packageHash: string; available?: boolean;
  manifest: { id: string; name: string; version: string; description?: string;
    kind: "segmentation" | "measurement" | "reader" | "exporter"; supportedDimensions: number[];
    parameters: { properties: Record<string, ParameterSpec>; required: string[] } };
}
export interface EvaluationMetrics {
  ap50: number; f1: number; precision: number; recall: number; meanDiamError: number;
  testImages: number; truePositives: number; falsePositives: number; falseNegatives: number;
}
export interface AdaptationEvaluation {
  id: string; baseline: EvaluationMetrics; candidate: EvaluationMetrics; evaluationNumber: number;
  biologicalTestN: number; notes: string[];
}
export interface AdaptationDataset {
  id: string; name: string; counts: { train: number; validation: number; test: number };
  samples: { imageId: string; name: string; specimenId: string; partition: string; currentReference: boolean }[];
  evaluations: AdaptationEvaluation[];
}
export interface PackageInspection {
  package: { format?: 1 | 2; artifactCount?: number; bytes?: number; shardCount?: number; path: string; sha256: string; name: string; projectId: string; sourceRevision: number;
    imageCount: number; volumeFrameCount?: number; files?: number; uncompressedBytes?: number };
  dependencies: { canReexecute: boolean; warnings: string[];
    runtime: { name: string; status: string; requiredVersion?: string; installedVersion?: string }[];
    plugins: unknown[] };
  integrity?: { verified: boolean; fileCount: number };
  verification?: { snapshotVerified: boolean; artifactBytesVerified: boolean; artifactVerification: string };
}
