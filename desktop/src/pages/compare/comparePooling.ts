/**
 * pages/compare/comparePooling.ts — pool cells per experimental condition
 * (feature `feat-compare`).
 *
 * Ported from `PanelsScroll.pooled` / `MannWhitneyPanel.groups` in
 * `Views/Compare/CompareView.swift`:
 *
 *     let batches = state.repos.batches(matching: cond.name)
 *     for b in batches { for img in b.images { cells += img.detection?.cells ?? [] } }
 *
 * Adapted to the port boundary. `PersistencePort` has no "images of a batch" nor
 * "cells of a batch" query, so we do exactly what the Batch page does: load
 * `allImages()` once, index by id, and read each image's saved detection via
 * `getDetection(imageId)`. Cells are pooled across every image of every batch
 * that carries the condition.
 *
 * Headless: this module only touches `PersistencePort` + pure math; it renders
 * nothing and holds no React state. The page's loader (`useCompareData`) calls
 * `poolConditions` and feeds the result to the presentational components.
 */

import type { BatchDTO, CellDTO, ImageDTO } from "../../kernel/types";
import { getPort } from "../../kernel/persistence";

/** All cells pooled for one condition, plus the batches they came from. */
export interface PooledCondition {
  /** The condition name (matches `ConditionDTO.name`). */
  condition: string;
  /** Hex color for this condition (from `ConditionDTO.color`). */
  color: string;
  /** Batches carrying this condition (via `batchesMatching`). */
  batches: BatchDTO[];
  /** Every detected cell across every image of every matching batch. */
  cells: CellDTO[];
}

/** Arithmetic mean of a sample; 0 for an empty list. */
export function mean(xs: number[]): number {
  if (xs.length === 0) return 0;
  let s = 0;
  for (const x of xs) s += x;
  return s / xs.length;
}

/**
 * Population standard deviation (÷N), matching the σ the Swift ConditionPanel
 * shows (`variance = Σ(x−mean)² / n`). Returns 0 for an empty sample.
 */
export function stdDev(xs: number[]): number {
  if (xs.length === 0) return 0;
  const m = mean(xs);
  let acc = 0;
  for (const x of xs) {
    const d = x - m;
    acc += d * d;
  }
  return Math.sqrt(acc / xs.length);
}

/** Diameters (µm) of a pooled condition — the vector Mann–Whitney runs on. */
export function diametersOf(pool: PooledCondition): number[] {
  return pool.cells.map((c) => c.diameterUm);
}

/**
 * Pool cells for a set of conditions.
 *
 * `colorFor` maps a condition name to its plot color (the page passes a lookup
 * built from `PersistencePort.conditions()`); a missing color falls back to a
 * neutral gray so a panel still renders.
 *
 * All images are loaded ONCE and shared across the conditions (the ported
 * behavior loads batches per condition, but images come from one store); each
 * image's detection is fetched at most once and memoised in `detCache`.
 */
export async function poolConditions(
  conditions: string[],
  colorFor: (name: string) => string,
): Promise<PooledCondition[]> {
  const port = getPort();

  // One image fetch for the whole comparison; index by id for O(1) lookup.
  const allImages = await port.allImages();
  const imageById = new Map<string, ImageDTO>(
    allImages.map((img) => [img.id, img]),
  );

  // Memoise detection reads: the same image can belong to only one batch, but
  // guarding is cheap and avoids a duplicate IPC round-trip if ids repeat.
  const detCache = new Map<string, CellDTO[]>();
  const cellsForImage = async (imageId: string): Promise<CellDTO[]> => {
    const cached = detCache.get(imageId);
    if (cached) return cached;
    // Only fetch detections for images we actually know about.
    if (!imageById.has(imageId)) {
      detCache.set(imageId, []);
      return [];
    }
    let cells: CellDTO[] = [];
    try {
      const det = await port.getDetection(imageId);
      cells = det?.cells ?? [];
    } catch {
      cells = [];
    }
    detCache.set(imageId, cells);
    return cells;
  };

  const pools: PooledCondition[] = [];
  for (const condition of conditions) {
    const batches = await port.batchesMatching(condition);
    const cells: CellDTO[] = [];
    for (const b of batches) {
      for (const imageId of b.imageIds) {
        const imgCells = await cellsForImage(imageId);
        if (imgCells.length > 0) cells.push(...imgCells);
      }
    }
    pools.push({ condition, color: colorFor(condition), batches, cells });
  }
  return pools;
}
