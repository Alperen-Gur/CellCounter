export type StatisticalMetric = "count" | "meanAreaPx" | "meanAreaUm2" | "meanVolumeVox" | "meanVolumeUm3" | "meanIntensity";
export type StatisticalOutcome = { kind: "measurement"; metric: StatisticalMetric; target: "plane" | "volume"; timeIndex?: number; channel?: number }
  | { kind: "assay"; runId: string; metricPath: string }
  | { kind: "assay-series"; runId: string; metricPath: import("./assaySeriesProtocol").AssaySeriesMetric };
export interface StatisticalFactor { id: string; name: string; kind: "categorical" | "numeric"; levels?: string[]; referenceLevel?: string; unit?: string }
export interface StatisticalRow { specimenId: string; subjectId?: string; blockId?: string; values: Record<string, string | number> }
export interface StatisticalDefinition { name: string; outcome: StatisticalOutcome; factors: StatisticalFactor[]; rows: StatisticalRow[]; exclusions?: { specimenId: string; reason: string }[] }
export interface StatisticalBlocker { code: string; message: string; imageId?: string; specimenId?: string; details?: unknown }
export interface StatisticalInputRow extends StatisticalRow { name: string; imageIds: string[]; included: boolean; value: number | null; reason?: string }
export interface StatisticalInputTable {
  definition: StatisticalDefinition; rows: StatisticalInputRow[]; imageRows: { imageId: string; name?: string; specimenId?: string; value: number | null; status: string; reason?: string }[];
  blockers: StatisticalBlocker[]; ready: boolean; units: unknown; notes: string[]; inputFingerprint: string; previewFingerprint: string;
}
export interface StatisticalDesign {
  id: string; name: string; version: number; latestVersion: number; inputFingerprint: string; inputsCurrent: boolean;
  rowCount: number; includedCount: number; definition: StatisticalDefinition; createdAt: string; inputTable?: StatisticalInputTable;
  inputStatus?: "draft" | "ready"; blockerCount?: number;
}
export interface StatisticalContrast { id: string; factorId: string; reference: string; comparison: string }
export interface StatisticalAnalysis {
  method: "welch-t" | "paired-t" | "linear-model"; contrasts: StatisticalContrast[]; terms?: string[]; interactions?: [string, string][];
  blocking: "none" | "subject" | "block"; covariance: "classical" | "HC3"; confidenceLevel: number; multiplicity: "none" | "holm" | "benjamini-hochberg";
}
export interface StatisticalEffect {
  id: string; estimate: number; standardError: number; degreesOfFreedom: number; confidenceLevel: number;
  confidenceInterval: [number, number] | null; pValue: number | null; adjustedPValue: number | null;
  status: string; multiplicity?: string; familySize?: number;
}
export interface StatisticalResult {
  status: "ready" | "blocked"; modelStatus: { status: string; [key: string]: unknown }; results: StatisticalEffect[];
  coefficients: Record<string, unknown>[]; plotTable: Record<string, unknown>[]; fittedTable: Record<string, unknown>[];
  notes: string[]; blockers: StatisticalBlocker[]; inputFingerprint: string; previewFingerprint: string;
  analysis: StatisticalAnalysis; designId: string; designVersion: number; units: unknown; biologicalN: number;
}
export interface StatisticalRun {
  id: string; designId: string; designVersion: number; name: string; method: StatisticalAnalysis["method"];
  modelStatus: StatisticalResult["modelStatus"]; outputsCurrent: boolean; createdAt: string; predecessorRunId?: string; replacementRunId?: string;
  result?: StatisticalResult; inputTable?: StatisticalInputTable;
}
export interface StatisticsCatalogue {
  seriesOutcomes?: { metricPath: import("./assaySeriesProtocol").AssaySeriesMetric; units: string }[];
  outcomes: { id: StatisticalMetric; units: string; targets: ("plane" | "volume")[] }[];
  methods: { id: StatisticalAnalysis["method"]; name: string; assumptions: string[] }[];
  limits: Record<string, number>; notes: string[];
}
export interface StatisticsExportFormat { id: "results-json" | "inputs-csv" | "results-csv" | "effects-svg"; name: string; extension: string; mediaType: string; requires?: string }
export interface StatisticsActions {
  run: (action: () => Promise<void>) => Promise<void>;
  mutate: <T>(operation: "statistics.design.save" | "statistics.run" | "statistics.recompute.run", args: Record<string, unknown>, accepted: (result: T) => void) => Promise<void>;
  exportReport: (format: StatisticsExportFormat, run: StatisticalRun) => Promise<void>;
}
