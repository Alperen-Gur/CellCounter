import type { WorkbenchCell, WorkbenchImage } from "./protocol";
import type { VolumeCell } from "./volumeProtocol";

export interface ImagePageFilters {
  query?: string; tags?: string[]; collectionId?: string;
  archiveScope?: "active" | "archived" | "all";
  sourceHash?: string; analysisTarget?: "plane" | "volume"; referenceCurrent?: boolean;
}
export interface ImagePage {
  images: WorkbenchImage[]; total: number; nextCursor: string | null; sourceRevision: number;
}
export interface MeasurementPage<T = WorkbenchCell | VolumeCell> {
  imageId: string; target: "plane" | "volume"; selection: Record<string, unknown>;
  total: number; cells: T[]; nextCursor: string | null; sourceRevision: number;
  analysisRevision: number; measurementRevision: number; coordinateSpace: string; intensityUnits: string;
}
export interface HistoryPage {
  history: { operation: string; revision: number; actor?: { kind: string; name: string }; at?: string }[];
  total: number; nextCursor: string | null; sourceRevision: number;
}

export interface StorageUpgradePreview {
  plan: { fromFormat: number; toFormat: number; imageCount: number; historyCount: number;
    measurementRows: number; sourceStateHash: string; sourceRevision: number; notes: string[] };
  previewFingerprint: string;
}
export interface StorageUpgradeResult {
  storage: { format: number; imageCount: number; historyCount: number };
  recoveryPath: string;
  migration: { fromFormat: number; sourceRevision: number; recoveryRelativePath: string; recoverySha256: string; recoveryScope: string };
}
export interface PackageRestoreCheckpoint {
  id: string; status: "pending" | "running" | "cancelled" | "completed"; restoreRevision: number;
  packagePath: string; packageHash: string; sourceProjectId: string; sourceRevision: number; name: string;
  nextShard: number; createdAt: string; progress: { completed: number; total: number }; imageCount: number;
  artifactCount: number; nextUnit: { type: "restore-shard" | "restore-metadata"; shardIndex: number | null } | null; notes: string[];
}
export interface PackageRestoreResult {
  restore: PackageRestoreCheckpoint;
  project?: { id: string; name: string; revision: number };
  imageCount?: number; imagePageRequired?: boolean; storage?: { format: number };
}
