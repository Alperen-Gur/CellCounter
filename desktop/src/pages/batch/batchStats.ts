/**
 * pages/batch/batchStats.ts — pure math for the Batch table (feature `feat-batch`).
 *
 * Kept framework-free (no React, no ports) so the numeric derivations are
 * trivially testable and match the Swift `BatchView` / `ExportService` summary
 * math. All size-binning delegates to `kernel/calibration` (binIndex /
 * binsFromThresholds) — the batch page never re-implements binning.
 *
 * Coordinate/units note: cell geometry is source-pixel, but the batch table
 * reports diameters in **micrometers** (`CellDTO.diameterUm`), the same unit the
 * size thresholds are expressed in.
 */

import type { BatchDTO, CellDTO, DetectionDTO, ImageDTO } from "../../kernel/types";
import { binIndex, binsFromThresholds } from "../../kernel/calibration/calibration";
import { mean, stdDev } from "../../kernel/stats/stats";

// ---------------------------------------------------------------------------
// Per-image status
// ---------------------------------------------------------------------------

/**
 * Lifecycle of one image in the batch, mirroring the states the spec calls out
 * (done / queued / running / error). Detection *presence* drives done/queued;
 * the live processing state (owned by Home's dispatch, surfaced via the store)
 * drives running/error for the image currently being detected.
 */
export type BatchRowStatus = "done" | "queued" | "running" | "error";

// ---------------------------------------------------------------------------
// Row + aggregate shapes
// ---------------------------------------------------------------------------

/** One rendered table row: filename + status + counts + size-class mini-dist. */
export interface BatchRow {
  imageId: string;
  fileName: string;
  status: BatchRowStatus;
  /** Number of detected cells (null until a detection exists). */
  cellCount: number | null;
  /** Mean cell diameter in µm (null when no cells / no detection). */
  meanDiameterUm: number | null;
  /**
   * Cell counts per size bin, aligned 1:1 with `binsFromThresholds(thresholds)`.
   * Empty array when the image has no detection yet.
   */
  binCounts: number[];
}

/** Batch-level aggregates, computed across images that have a saved detection. */
export interface BatchAggregates {
  /** Images in the batch that have completed detection. */
  analyzedImages: number;
  /** Total images in the batch (regardless of status). */
  totalImages: number;
  /** Total cells across all analyzed images. */
  totalCells: number;
  /** Mean cells per analyzed image. */
  meanCellsPerImage: number;
  /** Population σ of cells per analyzed image. */
  sdCellsPerImage: number;
  /** Mean cell diameter (µm) pooled across every cell in the batch. */
  meanDiameterUm: number;
  /** Population σ of cell diameter (µm) pooled across every cell in the batch. */
  sdDiameterUm: number;
}

// Descriptive statistics (population mean / σ) live in `kernel/stats/stats.ts`
// — the single owner shared with the Compare view, so the two views can never
// report mismatched summary numbers. Imported above as `mean` / `stdDev`.

// ---------------------------------------------------------------------------
// Row derivation
// ---------------------------------------------------------------------------

/** Tally each cell into its size bin using the batch thresholds. */
export function binCountsFor(cells: CellDTO[], thresholds: number[]): number[] {
  const bins = binsFromThresholds(thresholds);
  const counts = new Array(bins.length).fill(0) as number[];
  for (const c of cells) {
    const idx = binIndex(c.diameterUm, thresholds);
    // binIndex returns 0..thresholds.length, which is exactly the bin array's
    // valid index range (interior bins + open top bin). Guard defensively.
    if (idx >= 0 && idx < counts.length) counts[idx] += 1;
  }
  return counts;
}

/**
 * Build one table row for `image`. `detection` is the saved detection for that
 * image (or null if none yet). `status` is resolved by the caller from the
 * detection presence + live processing state.
 */
export function rowFor(
  image: ImageDTO,
  detection: DetectionDTO | null,
  status: BatchRowStatus,
  thresholds: number[],
): BatchRow {
  if (!detection) {
    return {
      imageId: image.id,
      fileName: image.fileName,
      status,
      cellCount: null,
      meanDiameterUm: null,
      binCounts: [],
    };
  }
  const cells = detection.cells;
  const diameters = cells.map((c) => c.diameterUm);
  return {
    imageId: image.id,
    fileName: image.fileName,
    status,
    cellCount: cells.length,
    meanDiameterUm: cells.length > 0 ? mean(diameters) : null,
    binCounts: binCountsFor(cells, thresholds),
  };
}

// ---------------------------------------------------------------------------
// Aggregates
// ---------------------------------------------------------------------------

/**
 * Compute batch aggregates from the loaded images + their detections. Only
 * images with a saved detection contribute (spec: "computed from saved
 * detections"). `cells-per-image` σ is over the analyzed images; diameter
 * mean/σ pool every cell across the batch.
 */
export function aggregatesFor(
  images: ImageDTO[],
  detectionByImage: Map<string, DetectionDTO | null>,
): BatchAggregates {
  const perImageCounts: number[] = [];
  const allDiameters: number[] = [];

  for (const img of images) {
    const det = detectionByImage.get(img.id) ?? null;
    if (!det) continue; // only analyzed images count toward aggregates
    perImageCounts.push(det.cells.length);
    for (const c of det.cells) allDiameters.push(c.diameterUm);
  }

  const totalCells = perImageCounts.reduce((a, b) => a + b, 0);

  return {
    analyzedImages: perImageCounts.length,
    totalImages: images.length,
    totalCells,
    meanCellsPerImage: mean(perImageCounts),
    sdCellsPerImage: stdDev(perImageCounts),
    meanDiameterUm: mean(allDiameters),
    sdDiameterUm: stdDev(allDiameters),
  };
}

// ---------------------------------------------------------------------------
// Formatting helpers (shared by the table + header)
// ---------------------------------------------------------------------------

/** `mean ± sd` with one decimal (e.g. "42.0 ± 7.3"). */
export function meanPmSd(m: number, sd: number, digits = 1): string {
  return `${m.toFixed(digits)} ± ${sd.toFixed(digits)}`;
}

/** Human label for a batch (falls back to the id when unnamed). */
export function batchLabel(batch: BatchDTO): string {
  const name = batch.displayName.trim();
  return name.length > 0 ? name : batch.id;
}
