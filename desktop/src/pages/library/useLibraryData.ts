/**
 * pages/library/useLibraryData.ts — loads everything the Images Library grid
 * renders, through the frozen `PersistencePort` only.
 *
 * Mirrors the data plumbing of the Swift `ImagesLibraryView`:
 *   - `images` = `allImages()` (every imported image, all batches)
 *   - `duplicateGroups()` — SHA-256 duplicate clusters (same `fileHash`),
 *     computed server-side from the whole-file hash stored at import. Per the
 *     feat-library-dedup boundary, hashing lives in the Rust importer
 *     (kernel-persistence) — we NEVER re-hash here, only surface the groups.
 *   - a per-image cell count (from the denormalized `image.cellCount`) + a 5-bin
 *     size mini-distribution returned by the compact `detectionSummaries` query;
 *     full cells/contours never cross IPC for thumbnail rendering.
 *   - `disambiguatedNames` — images that share an original filename get
 *     `_2`, `_3`, … appended so every grid label is unique (Swift
 *     `disambiguatedNames()`).
 *
 * All reads go through `getPort()`; no direct Tauri/SQLite here. Feature-owned
 * by feat-library-dedup. Uses ONLY kernel-persistence + kernel-types (its
 * `uses` set) — the size mini-distribution is a small local 5-bin histogram
 * (exactly what the Swift cell renders), not a call into kernel-calibration
 * (which is not in this task's `uses`).
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { ImageDTO } from "../../kernel/types";
import { getPort } from "../../kernel/persistence";
import { useAppStore } from "../../kernel/store/store";

/** How many size bins the thumbnail mini-distribution renders (Swift: 5). */
export const MINI_DIST_BINS = 5;

/** Per-image detection summary shown on the thumbnail. */
export interface ImageStats {
  /** Number of detected cells (0 when no detection ran). */
  cellCount: number;
  /** Whether a detection exists for this image at all. */
  hasDetection: boolean;
  /**
   * 5-bin size distribution normalised to 0..1 of the tallest bin, or null when
   * there is no detection / no cells. Rendered as the mini-bar.
   */
  distNorm: number[] | null;
}

export interface LibraryData {
  /** Every imported image (unsorted — grid order follows insertion). */
  images: ImageDTO[];
  /**
   * Duplicate clusters: each inner array is ≥2 images sharing one `fileHash`.
   * Empty when no duplicates exist.
   */
  duplicateGroups: ImageDTO[][];
  /** image.id → detection summary (count + mini-distribution). */
  statsById: Map<string, ImageStats>;
  /** image.id → unique display name (Swift `disambiguatedNames`). */
  displayNames: Map<string, string>;
  /** For a hash: the set of image ids that share it (size ≥ 2 ⇒ duplicate). */
  duplicateIds: Set<string>;
  loading: boolean;
  /** Re-read images + duplicate groups + per-image detection summaries. */
  reload: () => Promise<void>;
}

/** Build the disambiguated display-name map (Swift `disambiguatedNames`). */
function disambiguate(images: ImageDTO[]): Map<string, string> {
  const counts = new Map<string, number>();
  for (const img of images) {
    counts.set(img.fileName, (counts.get(img.fileName) ?? 0) + 1);
  }
  const seen = new Map<string, number>();
  const result = new Map<string, string>();
  for (const img of images) {
    const total = counts.get(img.fileName) ?? 0;
    if (total <= 1) {
      result.set(img.id, img.fileName);
      continue;
    }
    const n = (seen.get(img.fileName) ?? 0) + 1;
    seen.set(img.fileName, n);
    if (n === 1) {
      result.set(img.id, img.fileName);
    } else {
      const dot = img.fileName.lastIndexOf(".");
      if (dot > 0) {
        const base = img.fileName.slice(0, dot);
        const ext = img.fileName.slice(dot + 1);
        result.set(img.id, `${base}_${n}.${ext}`);
      } else {
        result.set(img.id, `${img.fileName}_${n}`);
      }
    }
  }
  return result;
}

export function useLibraryData(): LibraryData {
  // The batch thresholds a detection was computed under aren't carried on the
  // ImageDTO, so the mini-distribution uses the live global thresholds — the
  // same fallback the Swift cell uses when `image.batch?.thresholds` is nil.
  const globalThresholds = useAppStore((s) => s.thresholds);

  const [images, setImages] = useState<ImageDTO[]>([]);
  const [duplicateGroups, setDuplicateGroups] = useState<ImageDTO[][]>([]);
  const [statsById, setStatsById] = useState<Map<string, ImageStats>>(
    () => new Map(),
  );
  const [loading, setLoading] = useState(true);

  // Guards against out-of-order async writes when reloads overlap.
  const reqRef = useRef(0);

  const load = useCallback(async () => {
    const req = ++reqRef.current;
    setLoading(true);
    const port = getPort();
    try {
      const [all, groups] = await Promise.all([
        port.allImages(),
        port.duplicateGroups(),
      ]);
      if (req !== reqRef.current) return;
      setImages(all);
      setDuplicateGroups(groups);

      // Per-image detection summary (count + mini-distribution). Rust decodes a
      // diameter-only JSON projection and returns five integers per image; it
      // never materializes or transfers contours for this view.
      const stats = new Map<string, ImageStats>();
      const summaries = await port
        .detectionSummaries(all.map((img) => img.id), globalThresholds)
        .catch(() => []);
      if (req !== reqRef.current) return;
      const summaryByImage = new Map(summaries.map((summary) => [summary.imageId, summary]));

      for (const img of all) {
        const summary = summaryByImage.get(img.id) ?? null;
        if (!summary || summary.cellCount === 0) {
          stats.set(img.id, {
            cellCount: img.cellCount,
            // Keep the denormalized image count as a resilient fallback if a
            // summary row was skipped because its JSON is corrupt/unreadable.
            hasDetection: summary !== null || img.cellCount > 0,
            distNorm: null,
          });
          continue;
        }
        const bins = summary.sizeBins.slice(0, MINI_DIST_BINS);
        while (bins.length < MINI_DIST_BINS) bins.push(0);
        const max = Math.max(...bins);
        const distNorm =
          max > 0 ? bins.map((v) => v / max) : bins.map(() => 0);
        stats.set(img.id, {
          cellCount: summary.cellCount,
          hasDetection: true,
          distNorm,
        });
      }
      if (req !== reqRef.current) return;
      setStatsById(stats);
    } finally {
      if (req === reqRef.current) setLoading(false);
    }
  }, [globalThresholds]);

  useEffect(() => {
    void load();
  }, [load]);

  const displayNames = useMemo(() => disambiguate(images), [images]);

  const duplicateIds = useMemo(() => {
    const ids = new Set<string>();
    for (const group of duplicateGroups) {
      if (group.length < 2) continue;
      for (const img of group) ids.add(img.id);
    }
    return ids;
  }, [duplicateGroups]);

  return {
    images,
    duplicateGroups,
    statsById,
    displayNames,
    duplicateIds,
    loading,
    reload: load,
  };
}
