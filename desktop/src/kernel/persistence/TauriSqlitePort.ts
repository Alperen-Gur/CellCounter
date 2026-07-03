/**
 * kernel/persistence/TauriSqlitePort.ts — desktop `PersistencePort` over rusqlite.
 *
 * Each method is a thin `invoke(...)` against the Rust `#[command]`s registered
 * in `src-tauri/src/lib.rs` (bodies in `db/repo.rs`). Command names are the
 * snake_case Rust fn names; argument keys are passed camelCase — Tauri's
 * `#[command]` macro resolves `imageId` → `image_id`, etc.
 *
 * The three commands that take a whole struct (`record_correction`, `save_roi`,
 * `add_annotation`, `upsert_calibration_preset`) keep the exact Rust parameter
 * name for that struct (`c`, `roi`, `a`, `p`); the struct's own fields are
 * camelCase to match the `#[serde(rename_all = "camelCase")]` Rust DTOs.
 *
 * This is the only persistence file that imports `@tauri-apps`. The interface
 * (`PersistencePort.ts`) stays backend-free so the browser build can supply an
 * IndexedDB / wa-sqlite implementation.
 */

import { invoke } from "@tauri-apps/api/core";

import type {
  PersistencePort,
  RoiDTO,
  ConditionDTO,
  CalibrationPresetDTO,
  BinPresetDTO,
  ImportResult,
} from "./PersistencePort";
import type {
  BatchDTO,
  ImageDTO,
  DetectionDTO,
  GroundTruthDTO,
  CellDTO,
} from "../types";

export class TauriSqlitePort implements PersistencePort {
  // ── batches ──────────────────────────────────────────────────────────
  allBatches(): Promise<BatchDTO[]> {
    return invoke<BatchDTO[]>("all_batches");
  }

  batch(id: string): Promise<BatchDTO | null> {
    return invoke<BatchDTO | null>("batch", { id });
  }

  createBatch(p: {
    displayName: string;
    modelId: string;
    pxPerUm: number;
    thresholds: number[];
    condition?: string;
  }): Promise<BatchDTO> {
    return invoke<BatchDTO>("create_batch", {
      displayName: p.displayName,
      modelId: p.modelId,
      pxPerUm: p.pxPerUm,
      thresholds: p.thresholds,
      condition: p.condition ?? null,
    });
  }

  batchesMatching(condition: string): Promise<BatchDTO[]> {
    return invoke<BatchDTO[]>("batches_matching", { condition });
  }

  deleteBatch(id: string): Promise<void> {
    return invoke<void>("delete_batch", { id });
  }

  cleanupEmptyBatches(): Promise<void> {
    return invoke<void>("cleanup_empty_batches");
  }

  // ── images ───────────────────────────────────────────────────────────
  allImages(): Promise<ImageDTO[]> {
    return invoke<ImageDTO[]>("all_images");
  }

  imageMatchingHash(
    hash: string,
    fileName: string,
    excludingId?: string,
  ): Promise<ImageDTO | null> {
    return invoke<ImageDTO | null>("image_matching_hash", {
      hash,
      fileName,
      excludingId: excludingId ?? null,
    });
  }

  duplicateGroups(): Promise<ImageDTO[][]> {
    return invoke<ImageDTO[][]>("duplicate_groups");
  }

  deleteImage(id: string): Promise<void> {
    return invoke<void>("delete_image", { id });
  }

  attachImageToBatch(imageId: string, batchId: string): Promise<void> {
    return invoke<void>("attach_image_to_batch", { imageId, batchId });
  }

  // ── detections & corrections ─────────────────────────────────────────
  saveDetection(
    imageId: string,
    detectorId: string,
    cells: CellDTO[],
    imageStats?: Record<string, number>,
  ): Promise<DetectionDTO> {
    return invoke<DetectionDTO>("save_detection", {
      imageId,
      detectorId,
      cells,
      imageStats: imageStats ?? null,
    });
  }

  getDetection(imageId: string): Promise<DetectionDTO | null> {
    return invoke<DetectionDTO | null>("get_detection", { imageId });
  }

  getDetections(imageIds: string[]): Promise<DetectionDTO[]> {
    return invoke<DetectionDTO[]>("get_detections", { imageIds });
  }

  recordCorrection(
    detectionId: string,
    c: { kind: string; cellId: string; cx: number; cy: number; diameter: number },
  ): Promise<void> {
    // Rust: `record_correction(detection_id, c: CorrectionInput)`.
    return invoke<void>("record_correction", { detectionId, c });
  }

  // ── rois ─────────────────────────────────────────────────────────────
  rois(imageId: string): Promise<RoiDTO[]> {
    return invoke<RoiDTO[]>("rois", { imageId });
  }

  saveRoi(imageId: string, roi: RoiDTO): Promise<void> {
    // Rust: `save_roi(image_id, roi: RoiDto)`.
    return invoke<void>("save_roi", { imageId, roi });
  }

  deleteRoi(id: string): Promise<void> {
    return invoke<void>("delete_roi", { id });
  }

  // ── ground-truth annotations ─────────────────────────────────────────
  annotations(imageId: string): Promise<GroundTruthDTO[]> {
    return invoke<GroundTruthDTO[]>("annotations", { imageId });
  }

  addAnnotation(a: GroundTruthDTO): Promise<void> {
    // Rust: `add_annotation(a: GroundTruthDto)`.
    return invoke<void>("add_annotation", { a });
  }

  deleteAnnotation(id: string): Promise<void> {
    return invoke<void>("delete_annotation", { id });
  }

  deleteAllAnnotations(imageId: string): Promise<void> {
    return invoke<void>("delete_all_annotations", { imageId });
  }

  // ── conditions ───────────────────────────────────────────────────────
  conditions(): Promise<ConditionDTO[]> {
    return invoke<ConditionDTO[]>("conditions");
  }

  createCondition(name: string, color: string): Promise<ConditionDTO> {
    return invoke<ConditionDTO>("create_condition", { name, color });
  }

  renameCondition(id: string, name: string): Promise<void> {
    return invoke<void>("rename_condition", { id, name });
  }

  reorderConditions(orderedIds: string[]): Promise<void> {
    return invoke<void>("reorder_conditions", { orderedIds });
  }

  deleteCondition(id: string): Promise<void> {
    return invoke<void>("delete_condition", { id });
  }

  // ── presets & counts & review ────────────────────────────────────────
  calibrationPresets(): Promise<CalibrationPresetDTO[]> {
    return invoke<CalibrationPresetDTO[]>("calibration_presets");
  }

  upsertCalibrationPreset(p: CalibrationPresetDTO): Promise<void> {
    // Rust: `upsert_calibration_preset(p: CalibrationPresetDto)`.
    return invoke<void>("upsert_calibration_preset", { p });
  }

  deleteCalibrationPreset(id: string): Promise<void> {
    return invoke<void>("delete_calibration_preset", { id });
  }

  binPresets(): Promise<BinPresetDTO[]> {
    return invoke<BinPresetDTO[]>("bin_presets");
  }

  totalImageCount(): Promise<number> {
    return invoke<number>("total_image_count");
  }

  totalBatchCount(): Promise<number> {
    return invoke<number>("total_batch_count");
  }

  uncorrectedCellCount(belowConfidence: number): Promise<number> {
    return invoke<number>("uncorrected_cell_count", { belowConfidence });
  }

  wipeAllUserData(): Promise<void> {
    return invoke<void>("wipe_all_user_data");
  }

  // ── image import (separate command; see §3.8) ────────────────────────
  /**
   * Decode + hash + thumbnail + EXIF-probe a user-dropped file. Not part of the
   * `PersistencePort` interface (it needs raw bytes and returns calibration),
   * but exposed here since it also crosses the Rust IPC boundary.
   * Rust: `import_image(source_path)` → `{ image, calibration }`.
   */
  importImage(sourcePath: string): Promise<ImportResult> {
    return invoke<ImportResult>("import_image", { sourcePath });
  }
}
