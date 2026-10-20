export interface MigrationImagePlan {
  legacyImageId: string; name: string; status: "importable" | "archived-only" | "missing";
  sourceRole: string; reason?: string; geometryKind: "legacy-contours-and-centres"; exactMask: false;
}
export interface MigrationCounts {
  selectedImages: number; archivedImages?: number; importableImages: number; archivedOnlyImages: number; missingImages: number;
  files: number; missingFiles: number;
}
export interface MigrationPlan {
  previewFingerprint: string; platform: "windows" | "macos"; sourceDirectory: string;
  selectedImageIds: string[]; images: MigrationImagePlan[]; counts: MigrationCounts; totalBytes: number; notes: string[];
}
export interface MigrationCapture {
  archivePath: string; archiveHash: string; platform: "windows" | "macos"; imageCount: number; recordCount: number;
}
export interface LibraryMigration {
  id: string; platform: "windows" | "macos"; status: "pending" | "running" | "paused" | "failed" | "cancelled" | "completed";
  counts: MigrationCounts; archiveHash: string; evidenceComplete: boolean; scientificImportComplete: boolean;
  progress: { completed: number; total: number }; nextUnit: { type: "file" | "image"; name: string; legacyImageId?: string; path?: string; missing?: boolean } | null;
  imageMappings: { legacyImageId: string; imageId: string | null; status: string }[];
  imagePlans: (Omit<MigrationImagePlan, "geometryKind" | "exactMask"> & { checkpointStatus?: string; errorCode?: string })[];
  entities: { name: string; recordCount: number }[];
  missingFiles: { name: string; role: string; legacyImageId?: string; originalPath: string }[];
  missingFilesTruncated: boolean;
  error?: { code: string; message: string }; notes?: string[];
}
export interface MigrationGeometry {
  legacyImageId: string; imageId: string | null; geometryKind: "legacy-contours-and-centres"; exactMask: false;
  cells: unknown[]; total: number; offset: number; nextOffset: number | null;
  recordId: string | null; archiveHash: string; notes: string[];
}
export interface MigrationEvidencePage {
  records?: unknown[]; files?: unknown[]; total: number; offset: number; nextOffset: number | null; archiveHash: string;
}
export type MigrationControl = "migration.library.advance" | "migration.library.pause" | "migration.library.resume" | "migration.library.cancel";
export interface MigrationActions {
  useExistingLibrary: (selected: (sourceDirectory: string) => void) => Promise<void>;
  chooseLibrary: (selected: (sourceDirectory: string) => void) => Promise<void>;
  capture: (sourceDirectory: string, accepted: (result: MigrationCapture) => void) => Promise<void>;
  chooseArchive: (selected: (path: string) => void) => Promise<void>;
  create: (path: string, plan: MigrationPlan, name: string) => Promise<void>;
  control: (operation: MigrationControl) => Promise<void>;
  runRemaining: () => Promise<void>; stopAfterCheckpoint: () => void;
}
