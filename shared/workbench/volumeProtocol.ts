export type Vec3 = [number, number, number];
export type VolumePlane = "xy" | "xz" | "yz";
export interface VoxelSize { x: number | null; y: number | null; z: number | null }
export interface VolumeParameters {
  method: "otsu" | "manual"; threshold?: number; polarity: "bright" | "dark";
  minVolumeVox: number; minDistanceVox: number;
}
export interface VolumeWorkflowConfiguration {
  imageId: string; parameters: VolumeParameters; channel: number; timeIndex: number;
  plane?: VolumePlane; index?: number;
}
export const DEFAULT_VOLUME_PARAMETERS: VolumeParameters = {
  method: "otsu", polarity: "bright", minVolumeVox: 8, minDistanceVox: 3,
};
export interface VolumeDisplay {
  imageId: string; timeIndex: number; channel: number;
  displayKind?: "intensity" | "composite"; components?: 1 | 4; componentOrder?: "rgba";
  dataBase64: string; encoding: "base64"; dtype: "uint8"; order: "zyx";
  dimensions: Vec3; originalDimensions: Vec3; voxelSizeUm: VoxelSize;
  displayRange: [number, number]; transform: { scale: Vec3; offset: Vec3 };
  labelDataBase64?: string; labelDtype?: "uint32-le"; analysisRevision?: number;
}
export interface VolumeInspection {
  imageId: string; dimensions: Vec3; timeCount: number; channels: number;
  voxelSizeUm: VoxelSize; timeStepSeconds: number | null;
  frames: { timeIndex: number; channel: number; cellCount: number; analysisRevision: number;
    measurementRevision: number; parameters: VolumeParameters; inputFingerprint: string }[];
  tracks: { status: "none" | "current" | "stale" };
}
export interface VolumeSlice {
  imageId: string; timeIndex: number; channel: number; plane: VolumePlane; index: number;
  dataUrl: string; width: number; height: number; previewWidth: number; previewHeight: number;
  displayRange: [number, number]; voxelSizeUm: VoxelSize;
  contours: { labelId: number; contoursPx: [number, number][][] }[];
  analysisRevision?: number;
}
export interface VolumeCell {
  labelId: number; cx: number; cy: number; cz: number; voxelCount: number;
  volumeUm3: number | null; equivalentDiameterUm: number | null;
  centroidUm: { x: number; y: number; z: number } | null;
  meanIntensity: number; bbox: { min: Vec3; max: Vec3 };
}
export interface VolumeMeasurements {
  imageId: string; timeIndex: number; channel: number; cells: VolumeCell[]; cellCount: number;
  dimensions: Vec3; voxelSizeUm: VoxelSize; parameters: VolumeParameters;
  inputFingerprint: string; analysisRevision?: number; measurementRevision?: number;
  display?: VolumeDisplay; overlayDataUrl?: string;
}
export interface VolumeTracks {
  imageId: string; channel: number; status: "none" | "current" | "stale";
  tracks: { trackId: number | string; observations: { timeIndex: number; labelId: number; cx: number; cy: number; cz: number }[] }[];
  edges: { sourceTimeIndex: number; sourceLabelId: number; targetTimeIndex: number; targetLabelId: number;
    distance: number; units: string; origin: "automatic" | "manual" }[];
}
