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
 *     size mini-distribution derived from each image's persisted detection,
 *     bulk-loaded in one round-trip via `getDetections` (no per-image N+1).
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

/**
 * Bin index for a diameter given the batch/global thresholds, clamped to the
 * mini-distribution's 5 buckets. Identical semantics to the kernel's `binIndex`
 * (first `i` with `d < thresholds[i]`, else `thresholds.length`) — inlined here
 * because kernel-calibration is out of this task's `uses`, and this is exactly
 * the local 5-bin loop the Swift `ImageThumbCell` renders.
 */
function miniBinIndex(diameterUm: number, thresholds: number[]): number {
  let idx = thresholds.length;
  for (let i = 0; i < thresholds.length; i++) {
    if (diameterUm < thresholds[i]) {
      idx = i;
      break;
    }
  }
  return Math.min(idx, MINI_DIST_BINS - 1);
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

      // Per-image detection summary (count + mini-distribution). The cell COUNT
      // comes from the denormalized `image.cellCount` (no per-image read); the
      // mini-distribution needs per-cell diameters, so we bulk-load detections
      // for images that have any cells in ONE round-trip (get_detections),
      // instead of an N+1 getDetection per image.
      const stats = new Map<string, ImageStats>();
      const withCells = all.filter((img) => img.cellCount > 0);
      const detections = await port
        .getDetections(withCells.map((img) => img.id))
        .catch(() => []);
      if (req !== reqRef.current) return;
      const detByImage = new Map(detections.map((d) => [d.imageId, d]));

      for (const img of all) {
        const det = detByImage.get(img.id) ?? null;
        if (!det || det.cells.length === 0) {
          stats.set(img.id, {
            // A positive cellCount with no returned detection still means a
            // detection exists; only 0 means "none ran".
            cellCount: img.cellCount,
            hasDetection: img.cellCount > 0 || det !== null,
            distNorm: null,
          });
          continue;
        }
        const bins = new Array<number>(MINI_DIST_BINS).fill(0);
        for (const c of det.cells) {
          bins[miniBinIndex(c.diameterUm, globalThresholds)] += 1;
        }
        const max = Math.max(...bins);
        const distNorm =
          max > 0 ? bins.map((v) => v / max) : bins.map(() => 0);
        stats.set(img.id, {
          cellCount: det.cells.length,
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
