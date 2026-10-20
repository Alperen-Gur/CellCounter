import type { AnalysisParameters } from "./protocol";
import type { VolumeDisplay, VolumePlane, VoxelSize } from "./volumeProtocol";
import type { DisplayPresetRef } from "./displayPresetProtocol";

export type CompositeSelection =
  | { target: "plane"; sourceParameters: Pick<AnalysisParameters, "zProjection"> }
  | { target: "volume"; timeIndex: number; plane: VolumePlane; index: number };
export interface CompositeChannel {
  channel: number; color: string; enabled: boolean; lower?: number; upper?: number; gamma: number; opacity: number;
}
export interface CompositeEffectiveChannel extends Omit<CompositeChannel, "lower" | "upper"> {
  lower: number | null; upper: number | null; windowMode: "auto" | "manual";
  constantRange: boolean; sourceRange: [number | null, number | null]; supportedSamples: number;
}
export type CompositeArguments = CompositeSelection & { imageId: string; channels: CompositeChannel[]; maxSize: number; presetRef?: DisplayPresetRef };
export interface CompositePreview {
  imageId: string; target: "plane" | "volume"; selection: Record<string, unknown>;
  channels: CompositeEffectiveChannel[];
  dataUrl: string; width: number; height: number; previewWidth: number; previewHeight: number;
  sourceHash: string; sourceAxes: string | string[]; sourceShape: number[]; voxelSizeUm: VoxelSize;
  spacingUm: { x: number | null; y: number | null }; validSupport: Record<string, unknown>;
  displayTransform: { scale: [number, number]; offset: [number, number]; coordinateConvention: "pixel-edges" };
  plane?: VolumePlane; index?: number; sliceCount?: number; notes: string[];
  intensityUnits: "raw-source" | "processed-source"; engineVersion: string;
}
export interface CompositeCatalogue { engineVersion: string; argumentSchema: Record<string, unknown>; volumeArgumentSchema?: Record<string, unknown>;
  defaultColors: string[]; limits: Record<string, number>; notes: string[] }
export interface CompositeVolumeArguments {
  imageId: string; timeIndex: number; channels: CompositeChannel[]; maxDimension: number; labelChannel: number;
  presetRef?: DisplayPresetRef;
}
export interface CompositeVolumeDisplay extends VolumeDisplay {
  displayKind: "composite"; components: 4; componentOrder: "rgba"; displayUnits: "normalized-display";
  engineVersion: string; labelChannel: number | null; labelStatus: "not-requested" | "absent" | "current";
  labelSource?: { channel: number; timeIndex: number; labelsHash: string; analysisRevision: number;
    measurementRevision: number; inputFingerprint: string };
  channels: CompositeEffectiveChannel[]; sourceHash: string; sourceAxes: string | string[];
  sourceShape: number[]; sourceDtype: string; intensityUnits: "raw-source" | "processed-source";
  validSupport: Record<string, unknown>; notes: string[];
}
export interface CompositeExportFormat {
  id: "composite-png"; name: string; extension: string; mediaType: string; description: string;
}
export type CompositeExportArguments = CompositeArguments & { format: "composite-png" };
export interface CompositeExportResult {
  exportId: string; destination: string; sha256: string; format: "composite-png";
  mediaType: string; bytes: number; imageId: string; provenance: Record<string, unknown>;
}
