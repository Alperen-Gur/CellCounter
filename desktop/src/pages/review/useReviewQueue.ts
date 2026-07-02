/**
 * pages/review/useReviewQueue.ts — builds and drives the low-confidence Review
 * queue, entirely through the frozen `PersistencePort`.
 *
 * Direct port of the data logic in the Swift `ReviewQueueView` (`rebuild` +
 * `applyAction` + `commitEdit`).
 *
 * What qualifies as "needs review" (canonical, and INDEPENDENT of the global
 * `state.confidence` slider — the cutoff is fixed so the sidebar badge and the
 * queue can never drift apart):
 *   1. `cell.confidence < REVIEW_QUEUE_CONFIDENCE_CUTOFF` (0.65), the same
 *      constant `store.refreshLibraryStats` feeds to
 *      `PersistencePort.uncorrectedCellCount(below:)` for the badge, AND
 *   2. no correction row exists for that `cellId` yet (any kind). Triaging once
 *      is forever.
 *
 * Dedup by `image.fileName`: the user often re-imports the same physical file
 * many times, each with its own detection; keep only the most recently imported
 * copy per filename so the queue doesn't resurface the same visual field.
 *
 * What each action writes (mirrors `EditableOverlay → handleEdit`):
 *   - reject → `recordCorrection(kind:"remove")` AND removes the cell from
 *     `detection.cells` (re-saved via `saveDetection`, an upsert). The cell
 *     stops counting toward Totals/bins everywhere downstream.
 *   - keep   → `recordCorrection(kind:"accept")` only (audit trail; the cell
 *     stays in `detection.cells`, unchanged).
 *   - editDiameter → `recordCorrection(kind:"resize")` AND updates the cell's
 *     `diameterUm` + `diameterPx` in `detection.cells` (re-saved), so it re-bins
 *     immediately.
 *   - skip → advances the cursor with no write; the cell reappears next time.
 *
 * Feature-owned by feat-review-queue. Uses ONLY kernel-persistence
 * (`getPort`), kernel-store (`useAppStore` + `REVIEW_QUEUE_CONFIDENCE_CUTOFF`),
 * and kernel-types.
 *
 * KERNEL GAP (worked around here, recorded in the task result): `PersistencePort`
 * exposes no reader for a detection's existing corrections — only the aggregate
 * `uncorrectedCellCount(below:)`. The Swift original read `detection.corrections`
 * directly to satisfy filter (2). To honour "triaged once is forever" for the
 * `keep` action (which leaves `cell` in `detection.cells` with its low
 * confidence) we track cell ids triaged *in this session* and exclude them from
 * the live queue and from `rebuild`. `reject`/`resize` already survive a full
 * rebuild because they mutate the persisted cell (removed, or lifted above the
 * cutoff if resized past it) — but the audit correction is what a future
 * cross-session filter would key on. A `corrections(detectionId)` port method
 * would let a fresh page mount re-derive prior `keep` decisions.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { CellDTO, DetectionDTO, ImageDTO } from "../../kernel/types";
import { getPort } from "../../kernel/persistence";
import {
  useAppStore,
  REVIEW_QUEUE_CONFIDENCE_CUTOFF,
} from "../../kernel/store/store";

/** One card's worth of context: the cell plus where it lives. */
export interface ReviewItem {
  /** Stable queue key (the cell id is unique within a detection). */
  key: string;
  cell: CellDTO;
  image: ImageDTO;
  detection: DetectionDTO;
  /** px/µm of the owning batch (for the fallback circle + diameter⇄px). */
  pxPerUm: number;
  batchName: string;
}

/** The kind string recorded for each triage action (matches CorrectionRecord). */
type CorrectionKind = "remove" | "accept" | "resize";

export interface ReviewQueue {
  /** The full triage queue, ascending by confidence (least confident first). */
  queue: ReviewItem[];
  /** Cursor into `queue`; `>= queue.length` means "done". */
  cursor: number;
  /** The item under the cursor, or null when finished / empty. */
  current: ReviewItem | null;
  /** The next item (for the peek card), or null. */
  next: ReviewItem | null;
  loading: boolean;

  /** Reject the current cell: records "remove" + drops it from the detection. */
  reject(): Promise<void>;
  /** Keep the current cell: records "accept" (no data change). */
  keep(): Promise<void>;
  /** Resize the current cell to `diameterUm`: records "resize" + updates it. */
  editDiameter(diameterUm: number): Promise<void>;
  /** Skip: advance the cursor with no write (the cell reappears later). */
  skip(): void;
}

/**
 * Load every batch's images + detections and flatten to the ordered triage
 * queue. Best-effort per image (a decode/read failure just omits that image).
 */
async function buildQueue(
  sessionTriaged: ReadonlySet<string>,
): Promise<ReviewItem[]> {
  const port = getPort();
  const cutoff = REVIEW_QUEUE_CONFIDENCE_CUTOFF;

  const [batches, allImages] = await Promise.all([
    port.allBatches(),
    port.allImages(),
  ]);
  const imageById = new Map(allImages.map((im) => [im.id, im]));

  // Dedup by fileName → keep the most recently imported copy (Swift Pass-16).
  interface Pref {
    image: ImageDTO;
    pxPerUm: number;
    batchName: string;
  }
  const preferredByFile = new Map<string, Pref>();
  for (const batch of batches) {
    for (const imageId of batch.imageIds) {
      const image = imageById.get(imageId);
      if (!image) continue;
      const prior = preferredByFile.get(image.fileName);
      if (!prior || image.importedAt > prior.image.importedAt) {
        preferredByFile.set(image.fileName, {
          image,
          pxPerUm: batch.pxPerUm,
          batchName: batch.displayName,
        });
      }
    }
  }

  // For each preferred image, load its detection and collect qualifying cells.
  const prefs = Array.from(preferredByFile.values());
  const perImage = await Promise.all(
    prefs.map(async (pref) => {
      const detection = await port
        .getDetection(pref.image.id)
        .catch(() => null);
      if (!detection) return [] as ReviewItem[];
      const items: ReviewItem[] = [];
      for (const cell of detection.cells) {
        if (cell.confidence >= cutoff) continue;
        if (sessionTriaged.has(cell.id)) continue;
        items.push({
          key: `${detection.id}:${cell.id}`,
          cell,
          image: pref.image,
          detection,
          pxPerUm: pref.pxPerUm,
          batchName: pref.batchName,
        });
      }
      return items;
    }),
  );

  const items = perImage.flat();
  items.sort((a, b) => a.cell.confidence - b.cell.confidence);
  return items;
}

export function useReviewQueue(): ReviewQueue {
  const refreshLibraryStats = useAppStore((s) => s.refreshLibraryStats);

  const [queue, setQueue] = useState<ReviewItem[]>([]);
  const [cursor, setCursor] = useState(0);
  const [loading, setLoading] = useState(true);

  // Cells triaged in this session (any action). Filter (2) equivalent for the
  // `keep` path — see the KERNEL GAP note in the file header. A ref so the
  // rebuild closure always sees the latest set without re-subscribing.
  const triagedRef = useRef<Set<string>>(new Set());

  // Guards against out-of-order async writes when rebuilds overlap.
  const reqRef = useRef(0);

  // Live per-detection working copy of `cells`, keyed by detection id. Two
  // low-confidence cells can share one detection; each reject/resize must build
  // its next cell list from the ALREADY-mutated copy, not the queue-build
  // snapshot — otherwise the second write, derived from the stale snapshot,
  // would clobber the first (resurrecting the earlier-triaged cell). The Swift
  // view got this for free because `detection.cells` was one shared mutable
  // reference; we reproduce that with this map. Seeded lazily from the item's
  // snapshot on first mutation; cleared on every rebuild.
  const workingCellsRef = useRef<Map<string, CellDTO[]>>(new Map());

  const rebuild = useCallback(async () => {
    const req = ++reqRef.current;
    setLoading(true);
    try {
      const items = await buildQueue(triagedRef.current);
      if (req !== reqRef.current) return;
      // Fresh snapshots come with this queue — drop any stale working copies.
      workingCellsRef.current = new Map();
      setQueue(items);
      setCursor(0);
    } finally {
      if (req === reqRef.current) setLoading(false);
    }
  }, []);

  /** The live cell list for an item's detection (seeded from its snapshot). */
  const liveCells = useCallback((item: ReviewItem): CellDTO[] => {
    const existing = workingCellsRef.current.get(item.detection.id);
    if (existing) return existing;
    const seeded = item.detection.cells.slice();
    workingCellsRef.current.set(item.detection.id, seeded);
    return seeded;
  }, []);

  // Build once on mount. The queue cutoff is fixed (independent of the global
  // confidence slider), so — exactly like the Swift view — changing that slider
  // must NOT rebuild (it would reset the cursor and bounce the user out of
  // position for no logical reason).
  useEffect(() => {
    void rebuild();
  }, [rebuild]);

  const current =
    cursor >= 0 && cursor < queue.length ? queue[cursor] : null;
  const next =
    cursor + 1 >= 0 && cursor + 1 < queue.length ? queue[cursor + 1] : null;

  /** Advance the cursor past the current card (no persistence). */
  const advance = useCallback(() => {
    setCursor((c) => c + 1);
  }, []);

  /**
   * Record a correction for `item.cell`, optionally replacing the detection's
   * cell list (reject removes; resize updates). Marks the cell triaged, then
   * advances + refreshes the sidebar badge. Optimistic + best-effort: a failed
   * write is swallowed so the user is never stuck on a card (matches the Swift
   * `try?` semantics).
   */
  const applyCorrection = useCallback(
    async (
      item: ReviewItem,
      kind: CorrectionKind,
      diameter: number,
      nextCells: CellDTO[] | null,
    ) => {
      // Mark triaged + advance up front so the UI moves immediately and the
      // rebuild (via refreshLibraryStats' consumers) won't resurface this cell.
      triagedRef.current.add(item.cell.id);
      advance();

      const port = getPort();
      try {
        await port.recordCorrection(item.detection.id, {
          kind,
          cellId: item.cell.id,
          cx: item.cell.cx,
          cy: item.cell.cy,
          diameter,
        });
        // reject / resize also mutate the persisted cell list (upsert).
        if (nextCells) {
          await port.saveDetection(
            item.detection.imageId,
            item.detection.detectorId,
            nextCells,
            item.detection.imageStats,
          );
        }
      } catch {
        /* best-effort: keep the user moving even if the write failed */
      }
      // Keep the sidebar Review badge in sync (mirrors the Swift
      // ccCorrectionsChanged → refreshLibraryStats round-trip).
      await refreshLibraryStats().catch(() => {});
    },
    [advance, refreshLibraryStats],
  );

  const reject = useCallback(async () => {
    if (!current) return;
    // Remove the cell from the detection's LIVE list so it stops counting
    // downstream, then persist that same list for later same-detection edits.
    const nextCells = liveCells(current).filter((c) => c.id !== current.cell.id);
    workingCellsRef.current.set(current.detection.id, nextCells);
    await applyCorrection(current, "remove", current.cell.diameterUm, nextCells);
  }, [current, liveCells, applyCorrection]);

  const keep = useCallback(async () => {
    if (!current) return;
    // Audit only — the cell stays in the detection unchanged (no cell write).
    await applyCorrection(current, "accept", current.cell.diameterUm, null);
  }, [current, applyCorrection]);

  const editDiameter = useCallback(
    async (diameterUm: number) => {
      if (!current) return;
      const newDiamPx =
        current.pxPerUm > 0
          ? diameterUm * current.pxPerUm
          : current.cell.diameterPx;
      // Update BOTH diameterUm and diameterPx on the cell so it re-bins and its
      // measurements/exports use the corrected size (Swift `commitEdit`). Derive
      // from + write back to the live list so a sibling edit isn't clobbered.
      const nextCells = liveCells(current).map((c) =>
        c.id === current.cell.id
          ? { ...c, diameterUm, diameterPx: newDiamPx }
          : c,
      );
      workingCellsRef.current.set(current.detection.id, nextCells);
      await applyCorrection(current, "resize", diameterUm, nextCells);
    },
    [current, liveCells, applyCorrection],
  );

  const skip = useCallback(() => {
    if (!current) return;
    advance();
  }, [current, advance]);

  return useMemo(
    () => ({
      queue,
      cursor,
      current,
      next,
      loading,
      reject,
      keep,
      editDiameter,
      skip,
    }),
    [queue, cursor, current, next, loading, reject, keep, editDiameter, skip],
  );
}
