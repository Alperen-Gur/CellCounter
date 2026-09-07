export const ANALYSIS_SCHEMA_VERSION = 1 as const;

export type LearnedModelId = "cpsam_v2" | "cp-cyto3" | "sd-fluo";
export type ModelId = LearnedModelId | "classical";

export interface SourcePointPx {
  readonly x: number;
  readonly y: number;
}

export interface SourceRectPx extends SourcePointPx {
  readonly width: number;
  readonly height: number;
}

export type SourcePolygonPx = readonly SourcePointPx[];

export interface BrowserImageSource {
  readonly id: string;
  readonly fileName: string;
  readonly mediaType: string;
  readonly byteLength: number;
  readonly lastModified: number | null;
  readonly blob: Blob;
}

export type CalibrationSource =
  | "ome-xml"
  | "tiff-baseline"
  | "imagej"
  | "zeiss"
  | "olympus"
  | "preset"
  | "manual"
  | "protocol"
  | "default";

export interface Calibration {
  /** Pixels per micrometre. Geometry itself always remains in source pixels. */
  readonly pxPerUm: number;
  readonly source: CalibrationSource;
  readonly confidence: "high" | "medium" | "low";
}

export interface ImageDescriptor {
  readonly id: string;
  readonly fileName: string;
  readonly mediaType: string;
  readonly byteLength: number;
  readonly sha256: string;
  readonly widthPx: number;
  readonly heightPx: number;
  readonly importedAt: string;
}

export interface AnalysisParameters {
  readonly modelId: ModelId;
  readonly confidenceThreshold: number;
  readonly expectedDiameterUm: number | null;
  readonly channels: readonly [number, number];
  readonly sourceChannel?: number;
  readonly projection?: "first" | "max" | "mean" | "sum";
  readonly thresholdMethod?: "otsu" | "triangle" | "adaptive" | "manual";
  readonly manualThreshold?: number;
  readonly invert?: boolean;
  readonly minimumAreaPx?: number;
  readonly backgroundSubtract: boolean;
  readonly rollingBallRadiusPx: number;
  readonly watershedSplit: boolean;
  readonly watershedMinDistanceUm: number;
  readonly sizeThresholdsUm: readonly number[];
}

export interface CellGeometry {
  readonly id: string;
  readonly centroidPx: SourcePointPx;
  readonly contourPx: SourcePolygonPx;
  readonly confidence: number;
  readonly origin: "model" | "manual";
  readonly reviewed?: boolean;
}

export interface CellMeasurement extends CellGeometry {
  readonly bboxPx: SourceRectPx;
  readonly areaPx2: number;
  readonly areaUm2: number;
  readonly perimeterPx: number;
  readonly perimeterUm: number;
  readonly equivalentDiameterPx: number;
  readonly equivalentDiameterUm: number;
  readonly circularity: number;
  readonly eccentricity: number;
  readonly aspectRatio: number;
  readonly solidity: number;
  readonly centroidUm: SourcePointPx;
  readonly edgeTouching: boolean;
  readonly sizeClass: string;
}

export interface ModelProvenance {
  readonly id: ModelId;
  readonly displayName: string;
  readonly manifestVersion: string;
  readonly artifactSha256: string;
  readonly runtime: "onnxruntime-web/webgpu" | "browser/classical";
  readonly runtimeVersion: string;
}

export interface AnalysisProvenance {
  readonly appVersion: string;
  readonly appBuild: string;
  readonly buildSha: string | null;
  readonly exportedAt: string;
  readonly imageSha256: string;
  readonly model: ModelProvenance;
  readonly calibration: Calibration;
  readonly parameters: AnalysisParameters;
}

export interface ImageAnalysis {
  readonly schemaVersion: typeof ANALYSIS_SCHEMA_VERSION;
  readonly id: string;
  readonly image: ImageDescriptor;
  readonly calibration: Calibration;
  readonly parameters: AnalysisParameters;
  readonly model: ModelProvenance;
  readonly ranAt: string;
  readonly cells: readonly CellMeasurement[];
  readonly correctionLog: readonly CorrectionRecord[];
  readonly imageStats: Readonly<Record<string, number>>;
  readonly workflow?: { readonly jobId?: string; readonly previewKey?: string; readonly reusedPreview?: boolean; readonly runCalibration?: Calibration };
  /** Local display of the exact channel/projection used; excluded from JSON exports. */
  readonly displayPlane?: Blob;
  readonly originalSource?: {
    readonly fileName: string;
    readonly mediaType: string;
    readonly byteLength: number;
    readonly sha256: string;
    readonly analysisTransform: "identity" | "tiff-first-plane-rgb8-preview" | "source-channel-projection";
    readonly planeCount: number;
    readonly bitsPerSample: number;
    readonly samplesPerPixel: number;
  };
}

export interface CorrectionRecord {
  readonly id: string;
  readonly appliedAt: string;
  readonly kind: "add" | "remove" | "resize" | "merge" | "split";
  readonly removedCellIds: readonly string[];
  readonly addedCellIds: readonly string[];
}

export interface BatchAnalysis {
  readonly id: string;
  readonly name: string;
  readonly condition: string;
  readonly analyses: readonly ImageAnalysis[];
}

export interface BatchSummary {
  readonly batchId: string;
  readonly condition: string;
  readonly imageCount: number;
  readonly cellCount: number;
  readonly meanDiameterUm: number;
  readonly medianDiameterUm: number;
  readonly standardDeviationUm: number;
  readonly meanAreaUm2: number;
  readonly binCounts: readonly number[];
}

export interface ComparisonResult {
  readonly groups: readonly BatchSummary[];
  readonly mannWhitney: null | {
    readonly u: number;
    readonly z: number;
    readonly pValue: number;
    readonly medianDifferenceUm: number;
    readonly rankBiserial: number;
  };
}

// Stable names shared with the desktop shell.
export type CellDTO = CellMeasurement;
export type DetectionParams = AnalysisParameters;
export interface DetectionResultDTO {
  readonly displayPlane?: Blob;
  readonly imageWidth: number;
  readonly imageHeight: number;
  readonly cells: readonly CellDTO[];
  readonly imageStats: Readonly<Record<string, number>>;
}
export type Provenance = AnalysisProvenance;

export function assertCalibration(value: Calibration): void {
  if (!Number.isFinite(value.pxPerUm) || value.pxPerUm <= 0) {
    throw new RangeError("Calibration pxPerUm must be a finite positive number");
  }
}

export function assertSourcePoint(point: SourcePointPx): void {
  if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) {
    throw new RangeError("Source-pixel coordinates must be finite");
  }
}
