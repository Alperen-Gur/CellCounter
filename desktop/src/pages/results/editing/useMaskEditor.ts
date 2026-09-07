/**
 * pages/results/editing/useMaskEditor.ts — the React⇄engine bridge for
 * mask editing (feature task `feat-mask-editing`).
 *
 * Owns a single `MaskEditEngine` instance for the current image's detection and
 * exposes its live state to the editing surface + toolbar. This is where the
 * FRAMEWORK-FREE engine (kernel-overlay-engine) meets React state and the
 * persistence port:
 *
 *   - loads the detection's cells (+ its `detectionId`) and the ground-truth
 *     annotations for the current image,
 *   - constructs the engine with the current calibration context,
 *   - subscribes to `engine.onCommit` and serializes each `EditEvent` through a
 *     small promise queue into one atomic backend commit: the final cell list
 *     is written once and all audit rows are inserted in the same transaction,
 *   - keeps React re-rendering by mirroring `engine.cells` into component state.
 *
 * The engine is the source of truth WHILE editing; the atomic edit commit
 * persists its snapshots so the sidebar recomputes stats from the same numbers.
 * The low-confidence display filter is NON-destructive: hidden cells stay in
 * the engine and are round-tripped untouched (mirrors ResultsView, which merges
 * the visible-filtered slice back into the full `liveCells`).
 *
 * We do NOT re-implement any engine logic here — every mutation goes through the
 * `MaskEditEngine` public API. This hook only wires it to React + the ports.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { CellDTO, GroundTruthDTO } from "../../../kernel/types";
import {
  MaskEditEngine,
  type EditContext,
  type EditEvent,
  type Pt,
  type Rect,
} from "../../../kernel/overlay/MaskEditEngine";
import { getPort } from "../../../kernel/persistence";
import { useAppStore } from "../../../kernel/store/store";
import { assertReviewImageWritable, isReviewImageBusy } from "../reviewWriteGuard";
import { DETECTION_UPDATED_EVENT } from "../events";

// ---------------------------------------------------------------------------
// Correction-kind mapping (port of ResultsView.handleEdit, §3.8 kinds)
// ---------------------------------------------------------------------------

/**
 * A single `corrections` row to append for a committed edit. `kind ∈
 * {add,remove,move,resize,accept,manual}` (§3.8). The engine never emits
 * `accept`/`move` (those come from the Review queue / drag-move flows), so this
 * mapping only produces add/remove/resize/manual — exactly the Swift host.
 */
interface CorrectionRow {
  kind: string;
  cellId: string;
  cx: number;
  cy: number;
  diameter: number;
}

/**
 * Translate an `EditEvent` into the correction rows to persist. `manualMode`
 * distinguishes a manual-count placement ("manual") from an add-mode placement
 * ("add") for the audit trail — the only place mode leaks into persistence.
 *
 * - added   → one row, kind = manual|add (by mode)
 * - removed → one row per removed cell, kind = remove
 * - merged  → one remove per original + one add for the merged result
 * - split   → one remove for the original + one add per child (mirrors merge)
 * - resized → one row, kind = resize
 */
function correctionsFor(event: EditEvent, manualMode: boolean): CorrectionRow[] {
  switch (event.kind) {
    case "added":
      return [
        {
          kind: manualMode ? "manual" : "add",
          cellId: event.cell.id,
          cx: event.cell.cx,
          cy: event.cell.cy,
          diameter: event.cell.diameterUm,
        },
      ];
    case "removed":
      return event.cells.map((c) => ({
        kind: "remove",
        cellId: c.id,
        cx: c.cx,
        cy: c.cy,
        diameter: c.diameterUm,
      }));
    case "merged": {
      const rows: CorrectionRow[] = event.removed.map((c) => ({
        kind: "remove",
        cellId: c.id,
        cx: c.cx,
        cy: c.cy,
        diameter: c.diameterUm,
      }));
      rows.push({
        kind: "add",
        cellId: event.added.id,
        cx: event.added.cx,
        cy: event.added.cy,
        diameter: event.added.diameterUm,
      });
      return rows;
    }
    case "split": {
      const rows: CorrectionRow[] = [
        {
          kind: "remove",
          cellId: event.removed.id,
          cx: event.removed.cx,
          cy: event.removed.cy,
          diameter: event.removed.diameterUm,
        },
      ];
      for (const c of event.added) {
        rows.push({
          kind: "add",
          cellId: c.id,
          cx: c.cx,
          cy: c.cy,
          diameter: c.diameterUm,
        });
      }
      return rows;
    }
    case "resized":
      return [
        {
          kind: "resize",
          cellId: event.cell.id,
          cx: event.cell.cx,
          cy: event.cell.cy,
          diameter: event.cell.diameterUm,
        },
      ];
  }
}

// ---------------------------------------------------------------------------
// Hook surface
// ---------------------------------------------------------------------------

export interface UseMaskEditorArgs {
  /** The image being edited. Cells load from its detection; annotations from it. */
  imageId?: string;
  readOnly?: boolean;
  /** Source-pixel image size — only used for defaults/guards, not required. */
  sourceWidth?: number;
  sourceHeight?: number;
}

export interface MaskEditorApi {
  /** Live cells (mirror of `engine.cells`); drive the overlay renderer. */
  cells: CellDTO[];
  /** Ground-truth annotations on the current image (annotate mode). */
  annotations: GroundTruthDTO[];
  /** The engine instance (stable across renders for the current image). */
  engine: MaskEditEngine | null;
  /** `detections.id` for the current image (needed to write corrections). */
  detectionId: string | null;

  canUndo: boolean;
  canRedo: boolean;
  loading: boolean;
  saving: boolean;
  saveError: string | null;
  loadError: string | null;
  flush(): Promise<void>;
  reload(): void;

  // mutations (all go through the engine; each persists + records corrections)
  addAt(pt: Pt): void;
  addFromContour(path: Pt[]): void;
  remove(ids: string[]): void;
  merge(aId: string, bId: string): void;
  split(id: string, stroke: Pt[]): void;
  resize(id: string, newDiameterPx: number): void;
  undo(): void;
  redo(): void;

  // queries (delegate to the engine, no persistence side effects)
  hitTest(pt: Pt): CellDTO | undefined;
  cellsInRect(rect: Rect): CellDTO[];
  cellsInPath(path: Pt[]): CellDTO[];

  // annotations (annotate / ground-truth mode) — persisted via the port
  addAnnotation(pt: Pt): void;
  removeAnnotation(id: string): void;
}

/**
 * Bridge the pure `MaskEditEngine` to React + the persistence port for the
 * current image. Returns a stable API the editing surface + toolbar consume.
 */
export function useMaskEditor(args: UseMaskEditorArgs): MaskEditorApi {
  const { imageId } = args;
  const readOnlyRef = useRef(args.readOnly);
  readOnlyRef.current = args.readOnly;
  const commitQueueRef = useRef<Promise<void>>(Promise.resolve());
  const saveErrorRef = useRef<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [loadRevision, setLoadRevision] = useState(0);
  const reload = useCallback(() => setLoadRevision(value => value + 1), []);
  const flush = useCallback(async () => {
    await commitQueueRef.current;
    if (saveErrorRef.current) throw new Error(saveErrorRef.current);
  }, []);

  const pxPerUm = useAppStore((s) => s.pxPerUm);
  const manualMarkerDiameterUm = useAppStore((s) => s.manualMarkerDiameterUm);
  const editorMode = useAppStore((s) => s.editorMode);

  const [loadedImageId, setLoadedImageId] = useState<string | undefined>(undefined);
  const [engine, setEngine] = useState<MaskEditEngine | null>(null);
  const [detectionId, setDetectionId] = useState<string | null>(null);
  const [cells, setCells] = useState<CellDTO[]>([]);
  const [annotations, setAnnotations] = useState<GroundTruthDTO[]>([]);
  const [canUndo, setCanUndo] = useState(false);
  const [canRedo, setCanRedo] = useState(false);
  const [loading, setLoading] = useState(false);

  // The detector id to stamp on the persisted detection blob. We reuse the one
  // already on the loaded detection so an edit never rebrands the detector;
  // A from-scratch manual session has no model provenance.
  const detectorIdRef = useRef<string>("manual");
  // Latest imageStats loaded with the detection, so re-saving edits preserves
  // the QC / colony numbers the sidecar produced.
  const imageStatsRef = useRef<Record<string, number> | undefined>(undefined);
  const activeImageIdRef = useRef(imageId);
  activeImageIdRef.current = imageId;
  // Read editor-mode inside the (stable) onCommit callback without re-subscribing.
  const modeRef = useRef(editorMode);
  useEffect(() => {
    modeRef.current = editorMode;
  }, [editorMode]);

  // ── load detection + annotations for the current image, build the engine ──
  useEffect(() => {
    let cancelled = false;
    if (!imageId) {
      setEngine(null);
      setDetectionId(null);
      setCells([]);
      setAnnotations([]);
      setCanUndo(false);
      setCanRedo(false);
      return;
    }
    const port = getPort();
    setLoading(true);
    setEngine(null);
    setCells([]);
    setSaving(false);
    setLoadError(null);
    setSaveError(null);
    saveErrorRef.current = null;
    void (async () => {
      try {
        const [det, anns] = await Promise.all([
          port.getDetection(imageId),
          port.annotations(imageId),
        ]);
        if (cancelled) return;
        const ctx: EditContext = { pxPerUm, manualMarkerDiameterUm };
        const initialCells = det?.cells ?? [];
        const eng = new MaskEditEngine(initialCells, ctx);
        detectorIdRef.current = det?.detectorId ?? "manual";
        imageStatsRef.current = det?.imageStats;
        setLoadedImageId(imageId);
        setEngine(eng);
        setDetectionId(det?.id ?? null);
        setCells(eng.cells);
        setAnnotations(anns);
        setCanUndo(eng.canUndo);
        setCanRedo(eng.canRedo);
      } catch (err) {
        if (!cancelled) {
          console.warn("[useMaskEditor] load failed:", err);
          setEngine(null);
          setDetectionId(null);
          setCells([]);
          setAnnotations([]);
          setLoadedImageId(imageId);
          setLoadError(err instanceof Error ? err.message : String(err));
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
    // Rebuild only when the image changes. Calibration/marker changes are pushed
    // via engine.setContext below without discarding the undo history.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [imageId, loadRevision]);

  useEffect(() => {
    const updated = (event: Event) => {
      if ((event as CustomEvent<{ imageId?: string }>).detail?.imageId === imageId) reload();
    };
    window.addEventListener(DETECTION_UPDATED_EVENT, updated);
    return () => window.removeEventListener(DETECTION_UPDATED_EVENT, updated);
  }, [imageId, reload]);

  // Push calibration / marker-size changes into the live engine without a rebuild.
  useEffect(() => {
    engine?.setContext({ pxPerUm, manualMarkerDiameterUm });
  }, [engine, pxPerUm, manualMarkerDiameterUm]);

  // ── subscribe: ordered, atomic detection + corrections commits ──
  useEffect(() => {
    if (!engine) return;
    const port = getPort();
    // The engine may emit another edit (especially rapid undo/redo) before the
    // prior IPC finishes. Serialize those snapshots so an older write can never
    // land after a newer one. A rejected item is caught on the chain so later
    // edits can still repair persistence with their complete final snapshot.
    let pending = 0;
    let carriedCorrections: CorrectionRow[] = [];
    const unsub = engine.onCommit((event, nextCells) => {
      // Mirror engine state into React so the overlay re-renders immediately.
      setCells(nextCells);
      setCanUndo(engine.canUndo);
      setCanRedo(engine.canRedo);

      // No-op merges/splits emit an empty `removed` event — skip persistence.
      if (event.kind === "removed" && event.cells.length === 0) return;

      const imgId = imageId;
      if (!imgId) return;
      const detectorId = detectorIdRef.current;
      const imageStats = imageStatsRef.current;
      const rows = correctionsFor(event, modeRef.current === "manualCount");
      pending += 1;
      setSaving(true);
      commitQueueRef.current = commitQueueRef.current
        .then(async () => {
          assertReviewImageWritable(imgId);
          const corrections = [...carriedCorrections, ...rows];
          const savedId = await port.commitCellEdit(
            imgId,
            detectorId,
            nextCells,
            imageStats,
            corrections,
          );
          carriedCorrections = [];
          if (activeImageIdRef.current === imgId) {
            saveErrorRef.current = null;
            setSaveError(null);
          }
          // Don't let an old image's delayed commit overwrite the id shown for
          // a newly-selected image. The persistence write itself remains valid.
          if (activeImageIdRef.current === imgId) setDetectionId(savedId);
        })
        .catch((err) => {
          // Preserve audit rows across a recoverable local IPC/SQLite failure.
          // The next complete snapshot retries them in the same atomic commit.
          carriedCorrections = [...carriedCorrections, ...rows];
          if (activeImageIdRef.current === imgId) {
            saveErrorRef.current = err instanceof Error ? err.message : String(err);
            setSaveError(saveErrorRef.current);
          }
          console.warn("[useMaskEditor] persist failed:", err);
        }).finally(() => {
          pending -= 1;
          if (activeImageIdRef.current === imgId && pending === 0) setSaving(false);
        });
    });
    return unsub;
  }, [engine, imageId]);

  // ── mutations (thin wrappers — the engine.onCommit subscription persists) ──
  const canWrite = useCallback(() => !!imageId && loadedImageId === imageId && !readOnlyRef.current && !isReviewImageBusy(imageId), [imageId, loadedImageId]);

  const addAt = useCallback((pt: Pt) => { if (canWrite()) engine?.addAt(pt); }, [engine, canWrite]);
  const addFromContour = useCallback(
    (path: Pt[]) => { if (canWrite()) engine?.addFromContour(path); },
    [engine, canWrite],
  );
  const remove = useCallback((ids: string[]) => { if (canWrite()) engine?.remove(ids); }, [engine, canWrite]);
  const merge = useCallback(
    (aId: string, bId: string) => { if (canWrite()) engine?.merge(aId, bId); },
    [engine, canWrite],
  );
  const split = useCallback(
    (id: string, stroke: Pt[]) => { if (canWrite()) engine?.split(id, stroke); },
    [engine, canWrite],
  );
  const resize = useCallback(
    (id: string, newDiameterPx: number) => { if (canWrite()) engine?.resize(id, newDiameterPx); },
    [engine, canWrite],
  );
  const undo = useCallback(() => { if (canWrite()) engine?.undo(); }, [engine, canWrite]);
  const redo = useCallback(() => { if (canWrite()) engine?.redo(); }, [engine, canWrite]);

  // ── queries (delegate to the engine; safe no-op fallbacks) ──

  const hitTest = useCallback(
    (pt: Pt) => engine?.hitTest(pt),
    [engine],
  );
  const cellsInRect = useCallback(
    (rect: Rect) => engine?.cellsInRect(rect) ?? [],
    [engine],
  );
  const cellsInPath = useCallback(
    (path: Pt[]) => engine?.cellsInPath(path) ?? [],
    [engine],
  );

  // ── annotations (ground-truth) — persisted directly via the port ──

  const addAnnotation = useCallback(
    (pt: Pt) => {
      if (!imageId || !canWrite()) return;
      const ann: GroundTruthDTO = {
        id:
          typeof crypto !== "undefined" && "randomUUID" in crypto
            ? crypto.randomUUID()
            : `gt-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`,
        imageId,
        cx: pt.x,
        cy: pt.y,
        createdAt: new Date().toISOString(),
      };
      const port = getPort();
      // Optimistic: show the crosshair immediately, then persist.
      setAnnotations((prev) => [...prev, ann]);
      void port
        .addAnnotation(ann)
        .catch((err) => console.warn("[useMaskEditor] addAnnotation failed:", err));
    },
    [imageId, canWrite],
  );

  const removeAnnotation = useCallback((id: string) => {
    if (!canWrite()) return;
    const port = getPort();
    setAnnotations((prev) => prev.filter((a) => a.id !== id));
    void port
      .deleteAnnotation(id)
      .catch((err) => console.warn("[useMaskEditor] deleteAnnotation failed:", err));
  }, [canWrite]);

  return useMemo<MaskEditorApi>(
    () => ({
      cells: loadedImageId === imageId ? cells : [],
      annotations: loadedImageId === imageId ? annotations : [],
      engine: loadedImageId === imageId ? engine : null,
      detectionId: loadedImageId === imageId ? detectionId : null,
      canUndo: loadedImageId === imageId && canUndo,
      canRedo: loadedImageId === imageId && canRedo,
      loading: loading || !!imageId && loadedImageId !== imageId,
      saving, saveError, loadError, flush, reload,
      addAt,
      addFromContour,
      remove,
      merge,
      split,
      resize,
      undo,
      redo,
      hitTest,
      cellsInRect,
      cellsInPath,
      addAnnotation,
      removeAnnotation,
    }),
    [
      loadedImageId, imageId,
      cells,
      annotations,
      engine,
      detectionId,
      canUndo,
      canRedo,
      loading,
      saving, saveError, loadError, flush, reload,
      addAt,
      addFromContour,
      remove,
      merge,
      split,
      resize,
      undo,
      redo,
      hitTest,
      cellsInRect,
      cellsInPath,
      addAnnotation,
      removeAnnotation,
    ],
  );
}

export default useMaskEditor;
