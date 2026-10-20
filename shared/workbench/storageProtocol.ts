export interface ZarrArray {
  path: string; name: string; multiscaleIndex: number; level: number;
  shape: number[]; axes: { name: string; type: string; unit?: string }[];
  chunks: number[]; dtype: string; scale: number[]; translation: number[];
  voxelSizeUm: { x: number | null; y: number | null; z: number | null }; timeStepSeconds: number | null; codecs: string[];
}
export interface ZarrSource {
  id: string; name: string; path: string; ngffVersion: "0.4" | "0.5"; zarrFormat: 2 | 3;
  metadataHash: string; arrays: ZarrArray[]; available: boolean; readIdentityCount: number;
  sourceInputsCurrent: null; availabilityScope: string; notes: string[];
}
export interface StorageSelection { sourceId: string; arrayPath: string; timeIndex: number; channel: number; zIndex: number }
export interface StorageRegion { x: number; y: number; width: number; height: number }
export interface TiledParameters { method: "manual" | "otsu"; threshold?: number; polarity: "bright" | "dark"; connectivity: 4 | 8; minAreaPx: number }
export interface TiledPlan {
  sourceId: string; sourceName: string; metadataHash: string; array: ZarrArray; selection: Omit<StorageSelection, "sourceId">;
  region: StorageRegion; tileSize: number; halo: number; grid: { columns: number; rows: number };
  tileCount: number; checkpointCount: number; estimatedMaximumWorkingBytes: number; parameters: TiledParameters;
  limits: Record<string, number>; notes: string[];
}
export interface TiledAnalysis extends Omit<TiledPlan, "array" | "checkpointCount" | "limits"> {
  id: string; name: string; status: "pending" | "running" | "paused" | "failed" | "cancelled" | "completed";
  phase: string; progress: { completed: number; total: number }; threshold?: number; objectCount?: number;
  retainedBytes: number; createdRevision: number; createdAt: string; updatedAt?: string; sourceVerifiedAt?: string;
  sourceInputsCurrent: null | false; sourceCurrentness: "not-rechecked" | "changed"; outputsRetained: boolean;
  nextUnit: { type: string; tileIndex: number | null } | null; error?: { code: string; message: string };
}
export interface TiledObject { id: number; areaPx: number; centroidX: number; centroidY: number; meanIntensity: number; areaUm2: number | null; minX: number; minY: number; maxX: number; maxY: number }
export interface StorageExportFormat { id: "labels-ngff-zip" | "objects-csv"; name: string; extension: string; mediaType: string; description: string }
export interface StorageActions {
  run: (action: () => Promise<void>) => Promise<void>;
  mutate: <T>(operation: string, args: Record<string, unknown>, accepted?: (result: T) => void) => Promise<void>;
  chooseDirectory: (operation: "zarr.import" | "zarr.rebind", sourceId?: string, accepted?: (source: ZarrSource) => void) => Promise<void>;
  exportResults: (analysis: TiledAnalysis, format: StorageExportFormat) => Promise<void>;
  stopWorker: (workerId: string) => Promise<void>;
}
