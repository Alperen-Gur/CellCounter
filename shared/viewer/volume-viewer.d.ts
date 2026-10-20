export type XYZ = [number, number, number];
export type Plane = "xy" | "xz" | "yz";
export interface VolumeDescriptor {
  imageId: string; timeIndex: number; channel: number;
  dtype: "uint8"; encoding?: "base64"; order: "zyx";
  displayKind?: "intensity" | "composite"; components?: 1 | 4;
  componentOrder?: "rgba"; displayUnits?: "normalized-display";
  sourceHash?: string;
  channels?: { channel: number; enabled: boolean; opacity: number }[];
  dimensions: XYZ; originalDimensions: XYZ;
  dataBase64?: string; data?: Uint8Array;
  voxelSizeUm: { x: number | null; y: number | null; z: number | null };
  displayRange: [number, number];
  transform: { scale: XYZ; offset: XYZ };
  labelDataBase64?: string; labelDtype?: "uint32-le"; labelData?: Uint32Array;
  analysisRevision?: number;
  labelChannel?: number | null; labelStatus?: "not-requested" | "absent" | "current";
}
export interface VolumeStatus {
  mode: "empty" | "gpu" | "slices" | "error";
  message: string;
  dimensions?: XYZ;
  calibrated?: boolean;
}
export interface PlanePointer {
  plane: Plane; voxel: XYZ; displayVoxel: XYZ;
  role: "click"; sampled: true; editable: false;
}
export interface VolumeCallbacks {
  onCrosshair?: (voxel: XYZ) => void;
  onPlanePointer?: (event: PlanePointer) => void;
  onStatus?: (status: VolumeStatus) => void;
}
export interface VolumeViewer {
  setVolume: (descriptor: VolumeDescriptor) => void;
  setCrosshair: (voxel: XYZ) => void;
  dispose: () => void;
}
export function createVolumeViewer(container: HTMLElement, callbacks?: VolumeCallbacks): VolumeViewer;
