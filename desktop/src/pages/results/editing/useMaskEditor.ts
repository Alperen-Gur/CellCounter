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
 *   - subscribes to `engine.onCommit` and, for every committed `EditEvent`,
 *       (1) persists the full new cell list into the saved detection blob, and
 *       (2) writes one `corrections` row per logical change with the right
 *           `kind` (add|remove|move|resize|manual) — the audit trail that feeds
 *           the future train-from-GUI seam (§3.5),
 *   - keeps React re-rendering by mirroring `engine.cells` into component state.
 *
 * The engine is the source of truth WHILE editing; `saveDetection` persists the
 * result so the sidebar (feat-results-viewer) recomputes stats from the same
 * numbers. The low-confidence display filter is NON-destructive: hidden cells
 * stay in the engine and are round-tripped untouched (mirrors ResultsView,
 * which merges the visible-filtered slice back into the full `liveCells`).
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

  const pxPerUm = useAppStore((s) => s.pxPerUm);
  const manualMarkerDiameterUm = useAppStore((s) => s.manualMarkerDiameterUm);
  const editorMode = useAppStore((s) => s.editorMode);

  const [engine, setEngine] = useState<MaskEditEngine | null>(null);
  const [detectionId, setDetectionId] = useState<string | null>(null);
  const [cells, setCells] = useState<CellDTO[]>([]);
  const [annotations, setAnnotations] = useState<GroundTruthDTO[]>([]);
  const [canUndo, setCanUndo] = useState(false);
  const [canRedo, setCanRedo] = useState(false);
  const [loading, setLoading] = useState(false);

  // The detector id to stamp on the persisted detection blob. We reuse the one
  // already on the loaded detection so an edit never rebrands the detector.
  const detectorIdRef = useRef<string>("cellpose/cp-cyto3");
  // Latest imageStats loaded with the detection, so re-saving edits preserves
  // the QC / colony numbers the sidecar produced.
  const imageStatsRef = useRef<Record<string, number> | undefined>(undefined);
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
        detectorIdRef.current = det?.detectorId ?? "cellpose/cp-cyto3";
        imageStatsRef.current = det?.imageStats;
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
  }, [imageId]);

  // Push calibration / marker-size changes into the live engine without a rebuild.
  useEffect(() => {
    engine?.setContext({ pxPerUm, manualMarkerDiameterUm });
  }, [engine, pxPerUm, manualMarkerDiameterUm]);

  // ── subscribe: persist detection + append corrections on every commit ──
  useEffect(() => {
    if (!engine) return;
    const port = getPort();
    const unsub = engine.onCommit((event, nextCells) => {
      // Mirror engine state into React so the overlay re-renders immediately.
      setCells(nextCells);
      setCanUndo(engine.canUndo);
      setCanRedo(engine.canRedo);

      // No-op merges/splits emit an empty `removed` event — skip persistence.
      if (event.kind === "removed" && event.cells.length === 0) return;

      const imgId = imageId;
      const detId = detectionId;
      if (!imgId) return;

      // (1) Persist the full new cell list back into the detection blob. This
      //     re-saves the SAME 1:1 detection row (unique per image) so the
      //     sidebar recomputes counts/bins from the edited numbers.
      void port
        .saveDetection(imgId, detectorIdRef.current, nextCells, imageStatsRef.current)
        .then((saved) => {
          // First-ever save for an image with no prior detection row: capture the
          // freshly-minted id so subsequent corrections attach to it.
          if (!detId && saved?.id) setDetectionId(saved.id);
          return saved?.id ?? detId;
        })
        .then((idForCorrections) => {
          // (2) Append the correction rows for the audit trail.
          if (!idForCorrections) return;
          const rows = correctionsFor(event, modeRef.current === "manualCount");
          return Promise.all(
            rows.map((r) => port.recordCorrection(idForCorrections, r)),
          );
        })
        .catch((err) => console.warn("[useMaskEditor] persist failed:", err));
    });
    return unsub;
  }, [engine, imageId, detectionId]);

  // ── mutations (thin wrappers — the engine.onCommit subscription persists) ──

  const addAt = useCallback((pt: Pt) => engine?.addAt(pt), [engine]);
  const addFromContour = useCallback(
    (path: Pt[]) => engine?.addFromContour(path),
    [engine],
  );
  const remove = useCallback((ids: string[]) => engine?.remove(ids), [engine]);
  const merge = useCallback(
    (aId: string, bId: string) => engine?.merge(aId, bId),
    [engine],
  );
  const split = useCallback(
    (id: string, stroke: Pt[]) => engine?.split(id, stroke),
    [engine],
  );
  const resize = useCallback(
    (id: string, newDiameterPx: number) => engine?.resize(id, newDiameterPx),
    [engine],
  );
  const undo = useCallback(() => engine?.undo(), [engine]);
  const redo = useCallback(() => engine?.redo(), [engine]);

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
      if (!imageId) return;
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
    [imageId],
  );

  const removeAnnotation = useCallback((id: string) => {
    const port = getPort();
    setAnnotations((prev) => prev.filter((a) => a.id !== id));
    void port
      .deleteAnnotation(id)
      .catch((err) => console.warn("[useMaskEditor] deleteAnnotation failed:", err));
  }, []);

  return useMemo<MaskEditorApi>(
    () => ({
      cells,
      annotations,
      engine,
      detectionId,
      canUndo,
      canRedo,
      loading,
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
      cells,
      annotations,
      engine,
      detectionId,
      canUndo,
      canRedo,
      loading,
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
