/**
 * pages/home/useRecents.ts — the Home "Recent" list, sourced from the ports.
 *
 * Port of `HomeView.RecentsSection`: derives recent-batch rows from the store's
 * `recentBatchIds` (kept fresh by `refreshLibraryStats`) and resolves each to a
 * `BatchDTO` + a first-image thumbnail via the PersistencePort. Reading through
 * the store id list means the list re-renders live as batches are added/deleted.
 *
 * All data crosses the IPC boundary through PersistencePort — no page talks to
 * SQLite directly.
 */

import { useCallback, useEffect, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";

import { getPort } from "../../kernel/persistence";
import { useAppStore } from "../../kernel/store/store";
import type { BatchDTO, ImageDTO } from "../../kernel/types";

/** A resolved recent-batch row for the Home list. */
export interface RecentRow {
  batch: BatchDTO;
  /** Total cells across the batch's saved detections. */
  cellCount: number;
  imageCount: number;
  /** Convertible src for the first image's thumbnail, or undefined. */
  thumbSrc?: string;
}

/**
 * Resolve the store's `recentBatchIds` into displayable rows. Recomputes
 * whenever the id list changes (mutations call `refreshLibraryStats`). Empty
 * batches are dropped — a 0-image batch is a transient artefact.
 */
export function useRecents(): {
  rows: RecentRow[];
  loading: boolean;
  reload: () => void;
} {
  const recentBatchIds = useAppStore((s) => s.recentBatchIds);
  const [rows, setRows] = useState<RecentRow[]>([]);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    const port = getPort();
    setLoading(true);
    try {
      // Resolve each id → BatchDTO (skip any that vanished).
      const batches = await Promise.all(
        recentBatchIds.map((id) => port.batch(id).catch(() => null)),
      );
      // Fetch the image table once, not once per batch, and index by id so
      // each batch's first-image thumbnail is a cheap lookup.
      const allImages = await port.allImages().catch(() => [] as ImageDTO[]);
      const imagesById = new Map(allImages.map((i) => [i.id, i]));

      const resolved: RecentRow[] = [];
      for (const batch of batches) {
        if (!batch || batch.imageIds.length === 0) continue; // skip empties
        const { cellCount, thumbSrc } = await summarizeBatch(batch, imagesById);
        resolved.push({
          batch,
          cellCount,
          imageCount: batch.imageIds.length,
          thumbSrc,
        });
      }
      setRows(resolved);
    } finally {
      setLoading(false);
    }
  }, [recentBatchIds]);

  useEffect(() => {
    let alive = true;
    void (async () => {
      await load();
      if (!alive) return;
    })();
    return () => {
      alive = false;
    };
  }, [load]);

  return { rows, loading, reload: () => void load() };
}

/**
 * Compute a batch's total cell count (summing each image's saved detection) and
 * resolve its first image's thumbnail. Best-effort: missing detections count as
 * zero and a missing thumbnail is simply absent. `imagesById` is the pre-fetched
 * image index so this does no extra full-table read per batch.
 */
async function summarizeBatch(
  batch: BatchDTO,
  imagesById: Map<string, ImageDTO>,
): Promise<{ cellCount: number; thumbSrc?: string }> {
  const port = getPort();

  // First image = earliest imported among the batch's images.
  const images = batch.imageIds
    .map((id) => imagesById.get(id))
    .filter((i): i is ImageDTO => i != null)
    .sort((a, b) => a.importedAt.localeCompare(b.importedAt));

  let cellCount = 0;
  await Promise.all(
    batch.imageIds.map(async (id) => {
      const det = await port.getDetection(id).catch(() => null);
      if (det) cellCount += det.cells.length;
    }),
  );

  const first = images[0];
  const thumbSrc = first?.thumbPath ? safeConvert(first.thumbPath) : undefined;
  return { cellCount, thumbSrc };
}

/** convertFileSrc, guarded so a browser preview doesn't throw. */
function safeConvert(path: string): string | undefined {
  try {
    return convertFileSrc(path);
  } catch {
    return undefined;
  }
}

/** "Just now" / "N minutes ago" / "Today, HH:mm" — mirrors RelativeDateFormatter. */
export function relativeDate(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const now = new Date();
  const secs = (now.getTime() - date.getTime()) / 1000;

  if (secs < 60) return "Just now";
  if (secs < 3600) {
    const m = Math.floor(secs / 60);
    return `${m} minute${m === 1 ? "" : "s"} ago`;
  }
  if (secs < 3600 * 6) {
    const h = Math.floor(secs / 3600);
    return `${h} hour${h === 1 ? "" : "s"} ago`;
  }
  const hh = String(date.getHours()).padStart(2, "0");
  const mm = String(date.getMinutes()).padStart(2, "0");
  const sameDay =
    date.getFullYear() === now.getFullYear() &&
    date.getMonth() === now.getMonth() &&
    date.getDate() === now.getDate();
  if (sameDay) return `Today, ${hh}:${mm}`;

  const yest = new Date(now);
  yest.setDate(now.getDate() - 1);
  const isYesterday =
    date.getFullYear() === yest.getFullYear() &&
    date.getMonth() === yest.getMonth() &&
    date.getDate() === yest.getDate();
  if (isYesterday) return `Yesterday, ${hh}:${mm}`;

  const months = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
  ];
  const sameYear = date.getFullYear() === now.getFullYear();
  return sameYear
    ? `${months[date.getMonth()]} ${date.getDate()}`
    : `${months[date.getMonth()]} ${date.getDate()}, ${date.getFullYear()}`;
}
