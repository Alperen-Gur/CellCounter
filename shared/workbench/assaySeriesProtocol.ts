import type { ParameterValue } from "./extensionProtocol";
import type { ExperimentRecordActions } from "./experimentProtocol";
export type AssaySeriesMetric = "rates.gapAreaPx.slopePerSecond" | "rates.gapAreaUm2.slopePerSecond" | "rates.closureFraction.slopePerSecond";
export interface AssaySeriesRun { runId: string; name: string; frameCount: number; measuredCount: number; baselineIndex: number;
  outputsCurrent: boolean; createdAt: string; revision: number; predecessorRunId?: string; replacementRunId?: string; imageIds?: string[] }
export interface AssaySeriesFrame { index: number; timeSeconds: number | null; status: string; missingReason?: string; name?: string; imageId?: string;
  sourceParameters?: { channel: number; zProjection: string }; timeIndex?: number; region?: Record<string, number>; measuredSourceRegion?: Record<string, number>;
  commonSamples?: number; excludedAcquiredSamples?: number; measuredFractionOfRequestedROI?: number;
  gapAreaPx: number | null; gapAreaUm2: number | null; gapFractionPct: number | null; closureFraction: number | null; gapAreaChangePx: number | null; gapAreaChangeUm2: number | null }
export interface AssaySeriesRate { usedIndices: number[]; omitted: { index: number; reason: string }[]; slopePerSecond: number | null;
  intercept: number | null; timeOriginSeconds: number | null; rSquared: number | null; intervals: Record<string, unknown>[] }
export interface AssaySeriesOutput { assay: "scratch_wound"; name: string; parameters: Record<string, ParameterValue>; baselineIndex: number;
  frames: AssaySeriesFrame[]; commonSupport: { shape: number[]; samples: number; selectedSamples: number; fraction: number; sourceRegion: Record<string, number>; sha256: string; areaUm2: number | null };
  baseline: { index: number; status: string; gapAreaPx: number | null; gapAreaUm2: number | null; timeSeconds: number | null };
  rates: { gapAreaPx: AssaySeriesRate; gapAreaUm2: AssaySeriesRate; closureFraction: AssaySeriesRate; units: Record<string, string>; method: string };
  specimen: { status: string; inferentiallyEligible: boolean; biologicalN: number | null; specimen?: { id: string; name: string } | null; assignments: unknown[] };
  inputFingerprint: string; previewFingerprint: string; notes: string[]; dependencies: unknown[] }
export interface AssaySeriesExportFormat { id: "results-json" | "observations-csv"; name: string; extension: string; mediaType: string; description: string }
export interface AssaySeriesActions extends ExperimentRecordActions { exportReport: (format: AssaySeriesExportFormat, run: AssaySeriesRun) => Promise<void> }
