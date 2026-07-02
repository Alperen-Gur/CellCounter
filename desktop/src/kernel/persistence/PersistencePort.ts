/**
 * kernel/persistence/PersistencePort.ts — the data-access seam (ARCHITECTURE.md
 * §3.8).
 *
 * Ported from `Persistence/Repositories.swift`. Every method maps 1:1 to a Rust
 * `#[tauri::command]` in `src-tauri/src/db/repo.rs`. All methods are async —
 * they cross the IPC boundary.
 *
 * ┌──────────────────────────────────────────────────────────────────────┐
 * │  FROZEN CONTRACT (§6.3) — method signatures + the SQLite DDL. Any      │
 * │  feature that reads/writes data binds to this. The browser build       │
 * │  supplies an `IndexedDbPort` / `wa-sqlite` implementation of the same   │
 * │  interface; this file stays backend-free (types only).                 │
 * └──────────────────────────────────────────────────────────────────────┘
 *
 * The domain DTOs (`BatchDTO`, `ImageDTO`, `DetectionDTO`, `GroundTruthDTO`,
 * `CellDTO`) live in `kernel/types.ts`. The records that are persistence-only
 * (ROI, Condition, presets) are declared here — they are not part of the
 * detection/domain vocabulary but every port + the DB layer share them.
 */

import type {
  BatchDTO,
  ImageDTO,
  DetectionDTO,
  GroundTruthDTO,
  CellDTO,
  CalibrationDTO,
} from "../types";

// ---------------------------------------------------------------------------
// Persistence-only DTOs (mirror the matching Rust structs in db/models.rs)
// ---------------------------------------------------------------------------

/** A region-of-interest that includes/excludes cells from counts. Source-px. */
export interface RoiDTO {
  id: string;
  imageId: string;
  /** "include" | "exclude" */
  kind: string;
  /** "rect" | "ellipse" */
  shape: string;
  x: number;
  y: number;
  width: number;
  height: number;
  createdAt: string;
  name?: string;
}

/** A reusable experimental-condition label (Compare pooling). */
export interface ConditionDTO {
  id: string;
  name: string;
  /** hex like "#4db3a8" — drives plot color in Compare. */
  color: string;
  createdAt: string;
  order: number;
}

/** A saved px/µm calibration preset. */
export interface CalibrationPresetDTO {
  id: string;
  name: string;
  pxPerUm: number;
  isDefault: boolean;
}

/** A saved size-bin threshold preset. */
export interface BinPresetDTO {
  id: string;
  name: string;
  thresholds: number[];
}

/**
 * Result of the separate `import_image` command (needs raw bytes, so it lives
 * outside `PersistencePort` proper — see §3.8). `calibration` is `null` when no
 * embedded metadata is recognized.
 */
export interface ImportResult {
  image: ImageDTO;
  calibration: CalibrationDTO | null;
}

// ---------------------------------------------------------------------------
// PersistencePort — the frozen data-access interface (§3.8)
// ---------------------------------------------------------------------------

export interface PersistencePort {
  // batches
  allBatches(): Promise<BatchDTO[]>;
  batch(id: string): Promise<BatchDTO | null>;
  createBatch(p: {
    displayName: string;
    modelId: string;
    pxPerUm: number;
    thresholds: number[];
    condition?: string;
  }): Promise<BatchDTO>;
  batchesMatching(condition: string): Promise<BatchDTO[]>;
  deleteBatch(id: string): Promise<void>;
  cleanupEmptyBatches(): Promise<void>;

  // images
  allImages(): Promise<ImageDTO[]>;
  imageMatchingHash(
    hash: string,
    fileName: string,
    excludingId?: string,
  ): Promise<ImageDTO | null>;
  duplicateGroups(): Promise<ImageDTO[][]>;
  deleteImage(id: string): Promise<void>;
  attachImageToBatch(imageId: string, batchId: string): Promise<void>;

  // detections & corrections
  saveDetection(
    imageId: string,
    detectorId: string,
    cells: CellDTO[],
    imageStats?: Record<string, number>,
  ): Promise<DetectionDTO>;
  getDetection(imageId: string): Promise<DetectionDTO | null>;
  recordCorrection(
    detectionId: string,
    c: { kind: string; cellId: string; cx: number; cy: number; diameter: number },
  ): Promise<void>;

  // rois / annotations / conditions
  rois(imageId: string): Promise<RoiDTO[]>;
  saveRoi(imageId: string, roi: RoiDTO): Promise<void>;
  deleteRoi(id: string): Promise<void>;
  annotations(imageId: string): Promise<GroundTruthDTO[]>;
  addAnnotation(a: GroundTruthDTO): Promise<void>;
  deleteAnnotation(id: string): Promise<void>;
  deleteAllAnnotations(imageId: string): Promise<void>;
  conditions(): Promise<ConditionDTO[]>;
  createCondition(name: string, color: string): Promise<ConditionDTO>;
  renameCondition(id: string, name: string): Promise<void>;
  reorderConditions(orderedIds: string[]): Promise<void>;
  deleteCondition(id: string): Promise<void>;

  // presets & counts & review
  calibrationPresets(): Promise<CalibrationPresetDTO[]>;
  upsertCalibrationPreset(p: CalibrationPresetDTO): Promise<void>;
  deleteCalibrationPreset(id: string): Promise<void>;
  binPresets(): Promise<BinPresetDTO[]>;
  totalImageCount(): Promise<number>;
  totalBatchCount(): Promise<number>;
  /** review-queue badge: count of low-confidence, uncorrected cells. */
  uncorrectedCellCount(belowConfidence: number): Promise<number>;
  wipeAllUserData(): Promise<void>;
}
