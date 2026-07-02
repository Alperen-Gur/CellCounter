/**
 * pages/batch/useBatchData.ts — headless loader for the Batch screen (feature
 * `feat-batch`).
 *
 * Resolves the *current* batch (from the FROZEN store's `currentBatchId`), its
 * images, and each image's saved detection via `PersistencePort`, then derives
 * the per-image rows + batch aggregates (in `batchStats.ts`). It does NOT run
 * detection — Home dispatches that; this page only reads saved results and
 * reflects live status.
 *
 * Status resolution:
 *   - `error`   → this image is the batch's current image and the store holds a
 *                  detection error (`lastDetectionError`).
 *   - `running` → this image is the batch's current image and processing is
 *                  active (progress in (0,1) / a live stage line) with no error.
 *   - `done`    → a detection exists for the image.
 *   - `queued`  → no detection yet and not currently running.
 *
 * Reloads whenever the current batch changes or processing settles (so rows
 * flip queued→running→done as Home works through the batch).
 */

import { useCallback, useEffect, useMemo, useState } from "react";

import type { BatchDTO, DetectionDTO, ImageDTO } from "../../kernel/types";
import { getPort } from "../../kernel/persistence";
import { useAppStore } from "../../kernel/store/store";
import {
  aggregatesFor,
  rowFor,
  type BatchAggregates,
  type BatchRow,
  type BatchRowStatus,
} from "./batchStats";

export interface BatchData {
  /** The resolved current batch, or null when none is open. */
  batch: BatchDTO | null;
  /** Images in the batch, ordered per `batch.imageIds`. */
  images: ImageDTO[];
  /** One derived row per image (filename/status/counts/size-dist). */
  rows: BatchRow[];
  /** Batch-level aggregates over analyzed images. */
  aggregates: BatchAggregates | null;
  loading: boolean;
  error: string | null;
  /** Force a reload (e.g. after returning from processing). */
  reload(): void;
}

/** Order `images` to follow the batch's declared `imageIds` order. */
function orderImages(images: ImageDTO[], imageIds: string[]): ImageDTO[] {
  const byId = new Map(images.map((i) => [i.id, i]));
  const ordered: ImageDTO[] = [];
  for (const id of imageIds) {
    const img = byId.get(id);
    if (img) ordered.push(img);
  }
  // Include any batch images not present in imageIds (defensive) at the end.
  if (ordered.length !== images.length) {
    const seen = new Set(ordered.map((i) => i.id));
    for (const img of images) if (!seen.has(img.id)) ordered.push(img);
  }
  return ordered;
}

export function useBatchData(): BatchData {
  const currentBatchId = useAppStore((s) => s.currentBatchId);
  const currentImageIdx = useAppStore((s) => s.currentImageIdx);

  // Live processing signals used to flip the current image to running/error.
  const progress = useAppStore((s) => s.progress);
  const stageLine = useAppStore((s) => s.stageLine);
  const lastDetectionError = useAppStore((s) => s.lastDetectionError);
  const showDetectionError = useAppStore((s) => s.showDetectionError);

  const [batch, setBatch] = useState<BatchDTO | null>(null);
  const [images, setImages] = useState<ImageDTO[]>([]);
  const [detectionByImage, setDetectionByImage] = useState<
    Map<string, DetectionDTO | null>
  >(new Map());
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [reloadNonce, setReloadNonce] = useState(0);

  const reload = useCallback(() => setReloadNonce((n) => n + 1), []);

  // Re-read saved detections when processing *settles* (progress at an end),
  // not on every progress tick — a mid-run tick means "still running", and
  // reloading allImages + N detections on each increment would be wasteful.
  const processingSettled = progress <= 0 || progress >= 1;

  useEffect(() => {
    let cancelled = false;

    if (!currentBatchId) {
      setBatch(null);
      setImages([]);
      setDetectionByImage(new Map());
      setError(null);
      setLoading(false);
      return;
    }

    setLoading(true);
    setError(null);

    (async () => {
      try {
        const port = getPort();
        const b = await port.batch(currentBatchId);
        if (cancelled) return;
        if (!b) {
          setBatch(null);
          setImages([]);
          setDetectionByImage(new Map());
          setLoading(false);
          return;
        }

        // Load all images once, then narrow to this batch's ids (the port has
        // no per-batch image query; allImages + filter is the ported behavior).
        const all = await port.allImages();
        if (cancelled) return;
        const idSet = new Set(b.imageIds);
        const mine = orderImages(
          all.filter((i) => idSet.has(i.id)),
          b.imageIds,
        );

        // Fetch each image's saved detection (null when not yet run).
        const detections = await Promise.all(
          mine.map((img) =>
            port.getDetection(img.id).catch(() => null),
          ),
        );
        if (cancelled) return;

        const map = new Map<string, DetectionDTO | null>();
        mine.forEach((img, i) => map.set(img.id, detections[i] ?? null));

        setBatch(b);
        setImages(mine);
        setDetectionByImage(map);
        setLoading(false);
      } catch (e) {
        if (cancelled) return;
        setError(e instanceof Error ? e.message : String(e));
        setLoading(false);
      }
    })();

    return () => {
      cancelled = true;
    };
    // Reload on batch change, on explicit reload, and when processing settles
    // (an end-of-run boundary signals newly-saved detections worth re-reading).
  }, [currentBatchId, reloadNonce, processingSettled]);

  // Derive status per image from detection presence + live processing state.
  const rows = useMemo<BatchRow[]>(() => {
    if (!batch) return [];
    const thresholds = batch.thresholds;
    const currentImageId =
      currentImageIdx >= 0 && currentImageIdx < images.length
        ? images[currentImageIdx].id
        : undefined;
    const processingActive =
      (progress > 0 && progress < 1) || stageLine.trim().length > 0;

    return images.map((img) => {
      const det = detectionByImage.get(img.id) ?? null;
      let status: BatchRowStatus;
      const isCurrent = img.id === currentImageId;
      if (isCurrent && showDetectionError && lastDetectionError) {
        status = "error";
      } else if (isCurrent && processingActive && !det) {
        status = "running";
      } else if (det) {
        status = "done";
      } else {
        status = "queued";
      }
      return rowFor(img, det, status, thresholds);
    });
  }, [
    batch,
    images,
    detectionByImage,
    currentImageIdx,
    progress,
    stageLine,
    lastDetectionError,
    showDetectionError,
  ]);

  const aggregates = useMemo<BatchAggregates | null>(() => {
    if (!batch) return null;
    return aggregatesFor(images, detectionByImage);
  }, [batch, images, detectionByImage]);

  return { batch, images, rows, aggregates, loading, error, reload };
}
