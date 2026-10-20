import type { VolumePlane } from "./volumeProtocol";
export type AnnotationPoint = [number, number];
export type AnnotationKind = "point" | "line" | "polyline" | "polygon";
export interface AnnotationGeometry { type: AnnotationKind; points: AnnotationPoint[] }
export interface AnnotationSelection {
  sourceParameters?: { channel: number; zProjection: "max" | "mean" | "middle" };
  timeIndex?: number; channel?: number; plane?: VolumePlane; index?: number;
}
export interface AnnotationRecord {
  id: string | null; imageId: string; name: string; notes: string; geometry: AnnotationGeometry;
  target: "plane" | "volume"; selection: AnnotationSelection; sourceHash: string; sourceCurrent: boolean;
  geometryRevision: number | null; deleted: boolean; undoAvailable: boolean;
  createdAt?: string; updatedAt?: string;
  history?: { revision: number; operation: string; at: string; actor: { kind: string; name: string }; reason?: string }[];
}
export interface AnnotationListItem extends Omit<AnnotationRecord, "geometry" | "history"> {
  geometry: { type: AnnotationKind; pointCount: number; bounds: { x: number; y: number; width: number; height: number } };
}
export interface AnnotationProfile {
  sampleCount: number; positionsPx: number[]; positionsUm: (number | null)[];
  coordinates: AnnotationPoint[]; values: (number | null)[]; interpolation: "bilinear";
}
export interface AnnotationMeasurement {
  annotation: AnnotationRecord;
  measurement: {
    sourceRevision: number; geometryRevision: number | null; sourceHash: string; measurementChannel: number;
    selection: AnnotationSelection; axes: string[]; pixelSpacingUm: { u: number | null; v: number | null };
    geometry: { lengthPx: number | null; perimeterPx: number | null; areaPx2: number | null;
      lengthUm: number | null; perimeterUm: number | null; areaUm2: number | null };
    intensity: { units: "raw-source" | "processed-source"; sampling: "bilinear" | "acquisition-centres";
      validSamples: number; missingSamples: number; mean: number | null; min: number | null;
      max: number | null; sd: number | null; sum: number | null };
    profile: AnnotationProfile | null; validSupport: Record<string, unknown>; notes: string[];
  };
  dataUrl: string; overlayDataUrl: string; width: number; height: number; previewWidth: number; previewHeight: number;
}
export type AnnotationExportFormatId = "geometry-json" | "measurements-csv" | "profile-csv";
export interface AnnotationExportFormat {
  id: AnnotationExportFormatId; name: string; extension: string; mediaType: string; description: string;
}
export interface AnnotationExportArguments {
  imageId: string; annotationId: string; format: AnnotationExportFormatId;
  measurementChannel?: number; profileSamples?: number;
}
export interface AnnotationExportResult {
  exportId: string; destination: string; sha256: string; format: AnnotationExportFormatId;
  mediaType: string; bytes: number; imageId: string; annotationId: string;
  geometryRevision: number; provenance: Record<string, unknown>;
}
export interface AnnotationImportSource {
  name: string; sha256: string; bytes: number; format: "cellcounter-annotation";
}
export interface AnnotationImportPreview {
  imageId: string; source: AnnotationImportSource;
  annotation: Pick<AnnotationRecord, "name" | "notes" | "geometry" | "target" | "selection">;
  compatibility: { sourceMatches: boolean; calibrationMatches: boolean };
  previewFingerprint: string; notes: string[];
}
export interface AnnotationImportArguments { imageId: string; path: string; previewFingerprint: string }
export interface AnnotationImportResult { annotation: AnnotationRecord; source: AnnotationImportSource; importId: string }
