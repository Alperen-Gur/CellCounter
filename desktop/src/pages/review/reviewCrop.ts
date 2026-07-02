/**
 * pages/review/reviewCrop.ts — pure geometry + size-bin helpers for the Review
 * card. No React, no I/O.
 *
 * Ported from the crop math in the Swift `ReviewQueueView` (`computeCropRect`)
 * plus the `BinMath` label/index helpers from `Domain/SizeBin.swift`.
 *
 * Why the bin math is inlined here rather than imported from
 * `kernel/calibration`: this feature's `uses` set (docs/tasks.json
 * feat-review-queue) is kernel-persistence + kernel-store + kernel-types only —
 * calibration is out of scope. The Review card needs just the bin *label* for a
 * single cell, so we mirror the tiny `binIndex` / `bins(from:)` loop exactly
 * (byte-for-byte identical semantics to `kernel/calibration.binIndex` /
 * `binsFromThresholds`). The same inlining precedent is set by
 * `pages/library/useLibraryData.miniBinIndex`. If calibration ever lands in the
 * `uses` set, this collapses to a re-export.
 *
 * All geometry is in SOURCE-PIXEL space (matching CellDTO.cx/cy/contourPx and
 * ImageDTO.widthPx/heightPx). The card converts source-px → canvas-px with the
 * uniform `scale` returned by {@link cropTransform}.
 */

import type { CellDTO } from "../../kernel/types";

/** An axis-aligned rectangle in source-pixel space. */
export interface CropRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

// ── size-bin math (mirror BinMath / kernel-calibration) ────────────────────

/** Format a threshold the way the Swift `BinMath.fmt` does (int when whole). */
function fmtThreshold(v: number): string {
  return v % 1 === 0 ? String(Math.trunc(v)) : v.toFixed(1);
}

/**
 * Index of the bin a diameter falls in: first `i` with `d < thresholds[i]`,
 * else `thresholds.length` (the open top bin). Identical to
 * `kernel/calibration.binIndex` and Swift `BinMath.binIndex`.
 */
export function reviewBinIndex(diameterUm: number, thresholds: number[]): number {
  for (let i = 0; i < thresholds.length; i++) {
    if (diameterUm < thresholds[i]) return i;
  }
  return thresholds.length;
}

/**
 * Human bin label for a diameter (e.g. "< 20 µm", "20–30 µm", "> 30 µm").
 * Mirrors `BinMath.bins(from:)[binIndex].label`; returns "—" when there are no
 * thresholds (so the card degrades gracefully).
 */
export function reviewBinLabel(diameterUm: number, thresholds: number[]): string {
  if (thresholds.length === 0) return "—";
  const first = thresholds[0];
  const last = thresholds[thresholds.length - 1];
  const idx = reviewBinIndex(diameterUm, thresholds);
  if (idx <= 0) return `< ${fmtThreshold(first)} µm`;
  if (idx >= thresholds.length) return `> ${fmtThreshold(last)} µm`;
  const a = thresholds[idx - 1];
  const b = thresholds[idx];
  return `${fmtThreshold(a)}–${fmtThreshold(b)} µm`;
}

// ── crop window (mirror Swift computeCropRect) ─────────────────────────────

/** ~5× the cell diameter of context on the short axis (Swift `contextFactor`). */
const CONTEXT_FACTOR = 5.0;
/** Minimum window size so tiny cells still render legibly (Swift `minWindowPx`). */
const MIN_WINDOW_PX = 240;

/**
 * A window centred on the cell, big enough (~5× diameter on the short axis, at
 * least 240 px) to give context, shaped to the canvas aspect so aspect-fit
 * doesn't waste the card on letterboxing. If the cell is near an image edge the
 * window slides so the cell stays visible (never padded with empty space).
 *
 * All math in source-pixel space. Direct port of Swift `computeCropRect`.
 */
export function computeCropRect(
  widthPx: number,
  heightPx: number,
  cell: CellDTO,
  canvasWidth: number,
  canvasHeight: number,
): CropRect {
  const shortPx = Math.max(cell.diameterPx * CONTEXT_FACTOR, MIN_WINDOW_PX);

  const canvasAspect =
    canvasWidth > 0 && canvasHeight > 0 ? canvasWidth / canvasHeight : 1.0;

  let w: number;
  let h: number;
  if (canvasAspect >= 1) {
    h = shortPx;
    w = shortPx * canvasAspect;
  } else {
    w = shortPx;
    h = shortPx / canvasAspect;
  }
  // Don't ask for a window larger than the source image.
  w = Math.min(w, widthPx);
  h = Math.min(h, heightPx);

  // Centre on the cell, then slide so the rect stays inside the image.
  let x = cell.cx - w / 2;
  let y = cell.cy - h / 2;
  x = Math.max(0, Math.min(x, widthPx - w));
  y = Math.max(0, Math.min(y, heightPx - h));
  return { x, y, width: w, height: h };
}

/** Uniform source-px → canvas-px scale for a crop rect aspect-fit into a canvas. */
export function cropScale(
  crop: CropRect,
  canvasWidth: number,
  canvasHeight: number,
): number {
  if (crop.width <= 0 || crop.height <= 0) return 1;
  return Math.min(canvasWidth / crop.width, canvasHeight / crop.height);
}

/**
 * Does a cell's bounding box overlap the crop window? Used to skip drawing
 * neighbours entirely outside the visible crop (Swift `cellIntersectsCropRect`).
 */
export function cellIntersectsCrop(cell: CellDTO, crop: CropRect): boolean {
  const r = cell.diameterPx / 2;
  const bbLeft = cell.cx - r;
  const bbTop = cell.cy - r;
  const bbRight = cell.cx + r;
  const bbBottom = cell.cy + r;
  return (
    bbLeft < crop.x + crop.width &&
    bbRight > crop.x &&
    bbTop < crop.y + crop.height &&
    bbBottom > crop.y
  );
}
