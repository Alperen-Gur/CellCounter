/**
 * pages/results/editing/EditingSurface.tsx — the interactive pointer layer
 * (feature task `feat-mask-editing`).
 *
 * A transparent SVG that sits ON TOP of the read-only `MaskOverlay`, INSIDE the
 * `<Viewport>` so it consumes the same `ViewportTransformContext` — every
 * gesture is mapped to SOURCE-PIXEL space via `viewToSource` before it touches
 * the engine. Ported from the interactive half of
 * `Views/Results/EditableOverlay.swift` (modes, click-vs-drag thresholds, lasso,
 * bulk-delete rect, right-drag freeform, resize handles, merge/split staging).
 *
 * It renders only *transient* affordances (drag rectangles, freeform stroke,
 * split stroke, resize handles, delete floater); the persistent cell drawing is
 * the sibling `MaskOverlay` (kernel-overlay-engine). All mutation goes through
 * `MaskEditEngine` via the `useMaskEditor` bridge — no engine logic is
 * re-implemented here.
 *
 * Modes (store.editorMode / EditorMode):
 *   view        — select (click / cmd-toggle / shift-range / lasso-rect); drag = lasso
 *   add         — click empty = default cell; drag = new box; right-drag = freeform mask
 *   remove      — click a cell = delete; drag = bulk-delete rectangle
 *   merge       — click first then second cell = merge
 *   split       — click a cell to stage, then drag a stroke across it to cut
 *   manualCount — click = numbered pin; click existing pin = remove
 *   annotate    — click empty = ground-truth point; click a point = remove it
 *
 * Coordinate space: pointer client coords → container-local (via bounding rect)
 * → source-px (via `viewToSource`). Distances that must match the Swift
 * thresholds (4 / 5 / 6 px) are compared in VIEW space, exactly as the host did.
 */

import {
  useCallback,
  useContext,
  useMemo,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
} from "react";

import type { CellDTO } from "../../../kernel/types";
import type { Pt, Rect } from "../../../kernel/overlay/MaskEditEngine";
import { ViewportTransformContext } from "../../../kernel/viewport/Viewport";
import { useAppStore } from "../../../kernel/store/store";
import type { MaskEditorApi } from "./useMaskEditor";

// Swift thresholds (compared in VIEW-px, matching EditableOverlay).
const CLICK_MAX_DIST = 5; // < 5px translation ⇒ treat as click (handleDragEnded)
const DRAG_MIN_DIST = 6; // >= 6px ⇒ start a rectangle/lasso drag (handleDragChanged)
const NEWBOX_MIN_DIST = 4; // > 4px ⇒ begin a new-box drag in add mode
const HANDLE_SIZE = 8; // resize-handle square side (view-px)
const MIN_RESIZE_RADIUS_PX = 4; // radius floor (source-px), matches Swift max(4, …)

type Corner = "tl" | "tr" | "bl" | "br";

interface DragState {
  pointerId: number;
  /** view-px start (container-local) — for the click/drag distance test. */
  startViewX: number;
  startViewY: number;
  /** source-px start/current. */
  startSrc: Pt;
  currentSrc: Pt;
  /** which interaction the drag became (decided lazily once it exceeds a floor). */
  kind:
    | { t: "idle" }
    | { t: "pan"; startPanX: number; startPanY: number } // view mode, empty canvas
    | { t: "lasso"; extend: boolean; baseline: Set<string> } // view mode
    | { t: "removeRect" } // remove mode
    | { t: "newBox" } // add mode
    | { t: "freeform"; path: Pt[] } // add mode, right button
    | { t: "resize"; cellId: string; corner: Corner; liveDiameterPx: number }
    | { t: "splitStroke"; cellId: string; path: Pt[] };
}

export interface EditingSurfaceProps {
  /** The editor bridge for the current image (from useMaskEditor). */
  editor: MaskEditorApi;
}

/** Normalise two source-px points into a Rect (non-negative w/h). */
function rectFrom(a: Pt, b: Pt): Rect {
  return {
    x: Math.min(a.x, b.x),
    y: Math.min(a.y, b.y),
    width: Math.abs(b.x - a.x),
    height: Math.abs(b.y - a.y),
  };
}

export function EditingSurface({ editor }: EditingSurfaceProps) {
  const t = useContext(ViewportTransformContext);
  const { viewScale, sourceToView, viewToSource } = t;

  const editorMode = useAppStore((s) => s.editorMode);
  const selectedCellIds = useAppStore((s) => s.selectedCellIds);
  const setSelectedCellIds = useAppStore((s) => s.setSelectedCellIds);
  const setPan = useAppStore((s) => s.setPan);

  const svgRef = useRef<SVGSVGElement>(null);

  // Merge / split staging + shift-range anchor (kept in refs + state as needed).
  const [mergeFirstId, setMergeFirstId] = useState<string | undefined>(undefined);
  const [splitStagedId, setSplitStagedId] = useState<string | undefined>(undefined);
  const selectionAnchorRef = useRef<number | null>(null);

  // Live drag session (also mirrored to state so previews re-render).
  const dragRef = useRef<DragState | null>(null);
  const [, force] = useState(0);
  const rerender = useCallback(() => force((n) => n + 1), []);

  // Map a pointer event to container-local view-px + source-px.
  const locate = useCallback(
    (e: ReactPointerEvent): { view: Pt; src: Pt } => {
      const el = svgRef.current;
      const rect = el?.getBoundingClientRect();
      const view: Pt = {
        x: e.clientX - (rect?.left ?? 0),
        y: e.clientY - (rect?.top ?? 0),
      };
      return { view, src: viewToSource(view) };
    },
    [viewToSource],
  );

  // ── selection helpers (port of handleViewClick) ──

  const applyViewClick = useCallback(
    (hit: CellDTO | undefined, cmd: boolean, shift: boolean) => {
      if (!hit) {
        setSelectedCellIds(new Set());
        selectionAnchorRef.current = null;
        return;
      }
      const cells = editor.cells;
      const idx = cells.findIndex((c) => c.id === hit.id);
      const next = new Set(selectedCellIds);
      if (cmd && !shift) {
        if (next.has(hit.id)) next.delete(hit.id);
        else next.add(hit.id);
        selectionAnchorRef.current = idx;
      } else if (shift && idx >= 0) {
        const anchor = selectionAnchorRef.current ?? idx;
        const lo = Math.min(anchor, idx);
        const hi = Math.max(anchor, idx);
        for (let i = lo; i <= hi; i++) {
          if (i >= 0 && i < cells.length) next.add(cells[i].id);
        }
      } else {
        next.clear();
        next.add(hit.id);
        selectionAnchorRef.current = idx;
      }
      setSelectedCellIds(next);
    },
    [editor, selectedCellIds, setSelectedCellIds],
  );

  // ── click dispatch (port of handleClick) ──

  const handleClick = useCallback(
    (src: Pt, cmd: boolean, shift: boolean) => {
      const hit = editor.hitTest(src);
      switch (editorMode) {
        case "view":
          applyViewClick(hit, cmd, shift);
          setMergeFirstId(undefined);
          break;
        case "add":
          if (!hit) editor.addAt(src);
          // (Swift: clicking an existing cell in add mode just selects it; we
          //  fold that into view-selection so the delete floater can appear.)
          else setSelectedCellIds(new Set([hit.id]));
          break;
        case "remove":
          if (hit) editor.remove([hit.id]);
          break;
        case "merge":
          if (!hit) {
            setMergeFirstId(undefined);
            break;
          }
          if (mergeFirstId && mergeFirstId !== hit.id) {
            editor.merge(mergeFirstId, hit.id);
            setMergeFirstId(undefined);
          } else {
            setMergeFirstId(hit.id);
          }
          break;
        case "split":
          // First click stages the cell; the actual cut is a drag stroke.
          if (hit) setSplitStagedId(hit.id);
          else setSplitStagedId(undefined);
          break;
        case "manualCount":
          // Click an existing manual pin ⇒ remove it; otherwise place a new pin
          // (port of the .manualCount click path).
          if (hit && hit.isManual) editor.remove([hit.id]);
          else editor.addAt(src);
          break;
        case "annotate": {
          // Toggle-to-delete against the annotation layer (independent of cells).
          const near = nearestAnnotation(editor, src, viewScale);
          if (near) editor.removeAnnotation(near.id);
          else editor.addAnnotation(src);
          break;
        }
      }
    },
    [
      editor,
      editorMode,
      applyViewClick,
      mergeFirstId,
      setSelectedCellIds,
      viewScale,
    ],
  );

  // ── pointer down: begin a drag session (or a resize when a handle is hit) ──

  const onPointerDown = useCallback(
    (e: ReactPointerEvent) => {
      // Right / middle button in add mode ⇒ start a freeform stroke.
      const rightButton = e.button === 2;
      const { view, src } = locate(e);

      // If a resize handle is under the pointer (single selection), start resize.
      const handle = resizeHandleAt(editor, selectedCellIds, view, sourceToView);
      if (handle && editorMode !== "annotate") {
        const startCell = editor.cells.find((c) => c.id === handle.cellId);
        dragRef.current = {
          pointerId: e.pointerId,
          startViewX: view.x,
          startViewY: view.y,
          startSrc: src,
          currentSrc: src,
          kind: {
            t: "resize",
            cellId: handle.cellId,
            corner: handle.corner,
            liveDiameterPx: startCell?.diameterPx ?? 0,
          },
        };
        svgRef.current?.setPointerCapture(e.pointerId);
        e.stopPropagation();
        return;
      }

      // VIEW mode + primary button + empty space + no modifier ⇒ the drag is a
      // PAN. (A hit cell, a held modifier, or any edit mode claims the gesture
      // for select/edit instead.) The Viewport's own pan is gated on
      // target===currentTarget, which our covering surface prevents, so we drive
      // the Viewport's pan through the store setter ourselves — staying within
      // our own files. A short tap on empty space still clears the selection.
      const hasModifier = e.metaKey || e.ctrlKey || e.shiftKey;
      if (
        editorMode === "view" &&
        !rightButton &&
        !hasModifier &&
        !editor.hitTest(src) &&
        !resizeHandleAt(editor, selectedCellIds, view, sourceToView)
      ) {
        const p0 = useAppStore.getState().pan;
        dragRef.current = {
          pointerId: e.pointerId,
          startViewX: view.x,
          startViewY: view.y,
          startSrc: src,
          currentSrc: src,
          kind: { t: "pan", startPanX: p0.x, startPanY: p0.y },
        };
        svgRef.current?.setPointerCapture(e.pointerId);
        e.stopPropagation();
        return;
      }

      let kind: DragState["kind"] = { t: "idle" };
      if (editorMode === "add" && rightButton) {
        kind = { t: "freeform", path: [src] };
      } else if (editorMode === "split" && splitStagedId) {
        // Begin the cut stroke (staged cell is the one we split).
        kind = { t: "splitStroke", cellId: splitStagedId, path: [src] };
      }

      dragRef.current = {
        pointerId: e.pointerId,
        startViewX: view.x,
        startViewY: view.y,
        startSrc: src,
        currentSrc: src,
        kind,
      };
      // Claim the gesture so the Viewport doesn't pan underneath us.
      svgRef.current?.setPointerCapture(e.pointerId);
      e.stopPropagation();
      rerender();
    },
    [
      locate,
      editor,
      editorMode,
      selectedCellIds,
      sourceToView,
      splitStagedId,
      rerender,
    ],
  );

  // ── pointer move: grow the active drag (lazily decide its kind) ──

  const onPointerMove = useCallback(
    (e: ReactPointerEvent) => {
      const st = dragRef.current;
      if (!st || st.pointerId !== e.pointerId) return;
      const { view, src } = locate(e);
      st.currentSrc = src;
      const dist = Math.hypot(view.x - st.startViewX, view.y - st.startViewY);

      switch (st.kind.t) {
        case "pan": {
          // Pan by the raw view-px delta from the drag start (source-px agnostic).
          setPan({
            x: st.kind.startPanX + (view.x - st.startViewX),
            y: st.kind.startPanY + (view.y - st.startViewY),
          });
          break;
        }
        case "resize": {
          // Track the live diameter for the PREVIEW ring only. We commit ONCE
          // on pointer-up so undo/redo + the correction log get a single entry
          // per resize gesture (mirrors the Swift onChanged-mutate/onEnded-emit).
          const rk = st.kind; // capture narrowed type for the closure below
          const target = editor.cells.find((c) => c.id === rk.cellId);
          if (target) {
            const dx = src.x - target.cx;
            const dy = src.y - target.cy;
            const newRadiusPx = Math.max(MIN_RESIZE_RADIUS_PX, Math.hypot(dx, dy));
            rk.liveDiameterPx = newRadiusPx * 2;
          }
          break;
        }
        case "freeform": {
          const fk = st.kind;
          const last = fk.path[fk.path.length - 1];
          if (!last || (src.x - last.x) ** 2 + (src.y - last.y) ** 2 >= 1.0) {
            fk.path.push(src);
          }
          break;
        }
        case "splitStroke": {
          const sk = st.kind;
          const last = sk.path[sk.path.length - 1];
          if (!last || (src.x - last.x) ** 2 + (src.y - last.y) ** 2 >= 1.0) {
            sk.path.push(src);
          }
          break;
        }
        case "idle": {
          // Decide what this drag becomes once it crosses a floor.
          if (editorMode === "remove" && dist >= DRAG_MIN_DIST) {
            st.kind = { t: "removeRect" };
          } else if (editorMode === "view" && dist >= DRAG_MIN_DIST) {
            const extend = e.metaKey || e.ctrlKey;
            st.kind = {
              t: "lasso",
              extend,
              baseline: extend ? new Set(selectedCellIds) : new Set(),
            };
            updateLasso(st, editor, setSelectedCellIds);
          } else if (
            editorMode === "add" &&
            dist > NEWBOX_MIN_DIST &&
            !editor.hitTest(st.startSrc)
          ) {
            st.kind = { t: "newBox" };
          }
          break;
        }
        case "lasso":
          updateLasso(st, editor, setSelectedCellIds);
          break;
        case "removeRect":
        case "newBox":
          break;
      }
      rerender();
    },
    [locate, editor, editorMode, selectedCellIds, setSelectedCellIds, setPan, rerender],
  );

  // ── pointer up: finalise the drag (or dispatch a click) ──

  const onPointerUp = useCallback(
    (e: ReactPointerEvent) => {
      const st = dragRef.current;
      if (!st || st.pointerId !== e.pointerId) return;
      const { view, src } = locate(e);
      const dist = Math.hypot(view.x - st.startViewX, view.y - st.startViewY);

      try {
        svgRef.current?.releasePointerCapture(e.pointerId);
      } catch {
        /* capture may already be released */
      }

      const kind = st.kind;
      dragRef.current = null;

      switch (kind.t) {
        case "pan": {
          // A pan that never really moved is a tap on empty space ⇒ clear
          // selection (matches the Swift empty-space click in .view mode).
          if (dist < CLICK_MAX_DIST) {
            setSelectedCellIds(new Set());
            selectionAnchorRef.current = null;
          }
          break;
        }
        case "resize": {
          // Commit the resize exactly once now (single undo + correction entry).
          const target = editor.cells.find((c) => c.id === kind.cellId);
          if (target) {
            const dx = src.x - target.cx;
            const dy = src.y - target.cy;
            const radiusPx = Math.max(MIN_RESIZE_RADIUS_PX, Math.hypot(dx, dy));
            editor.resize(kind.cellId, radiusPx * 2);
          }
          break;
        }
        case "removeRect": {
          const r = rectFrom(st.startSrc, src);
          if (r.width > 1 && r.height > 1) {
            const victims = editor.cellsInRect(r).map((c) => c.id);
            if (victims.length) editor.remove(victims);
          }
          break;
        }
        case "lasso": {
          updateLasso({ ...st, currentSrc: src }, editor, setSelectedCellIds);
          break;
        }
        case "newBox": {
          finalizeNewBox(editor, st.startSrc, src);
          break;
        }
        case "freeform": {
          const path = kind.path.slice();
          const last = path[path.length - 1];
          if (!last || last.x !== src.x || last.y !== src.y) path.push(src);
          if (path.length >= 3) editor.addFromContour(path);
          break;
        }
        case "splitStroke": {
          const path = kind.path.slice();
          const last = path[path.length - 1];
          if (!last || last.x !== src.x || last.y !== src.y) path.push(src);
          if (path.length >= 2 && dist >= CLICK_MAX_DIST) {
            editor.split(kind.cellId, path);
            setSplitStagedId(undefined);
          } else {
            // Too short to be a cut — treat as a (re)stage click.
            handleClick(src, e.metaKey || e.ctrlKey, e.shiftKey);
          }
          break;
        }
        case "idle": {
          if (dist < CLICK_MAX_DIST) {
            handleClick(src, e.metaKey || e.ctrlKey, e.shiftKey);
          }
          break;
        }
      }
      rerender();
    },
    [locate, editor, setSelectedCellIds, handleClick, rerender],
  );

  const onPointerCancel = useCallback((e: ReactPointerEvent) => {
    const st = dragRef.current;
    if (!st || st.pointerId !== e.pointerId) return;
    dragRef.current = null;
    try {
      svgRef.current?.releasePointerCapture(e.pointerId);
    } catch {
      /* ignore */
    }
    rerender();
  }, [rerender]);

  // Suppress the native context menu so right-drag freeform works cleanly.
  const onContextMenu = useCallback((e: React.MouseEvent) => {
    if (editorMode === "add") e.preventDefault();
  }, [editorMode]);

  // ── transient affordance rendering ──

  // NOTE: `drag` is a mutable ref whose fields (currentSrc / path / liveDiameter)
  // are mutated IN PLACE during pointermove, then `rerender()` bumps a counter.
  // We therefore compute previews inline every render (NOT via useMemo keyed on
  // `drag`, which would keep the same object identity and skip recomputation).
  const drag = dragRef.current;
  const previews: React.ReactNode[] = (() => {
    const nodes: React.ReactNode[] = [];
    if (!drag) return nodes;
    const kind = drag.kind;

    if (kind.t === "removeRect") {
      const a = sourceToView(drag.startSrc);
      const b = sourceToView(drag.currentSrc);
      nodes.push(
        <rect
          key="rmrect"
          x={Math.min(a.x, b.x)}
          y={Math.min(a.y, b.y)}
          width={Math.abs(b.x - a.x)}
          height={Math.abs(b.y - a.y)}
          fill="var(--cc-danger, #ef4444)"
          fillOpacity={0.1}
          stroke="var(--cc-danger, #ef4444)"
          strokeOpacity={0.6}
          strokeWidth={1.5}
          strokeDasharray="5 3"
          rx={2}
        />,
      );
    } else if (kind.t === "lasso") {
      const a = sourceToView(drag.startSrc);
      const b = sourceToView(drag.currentSrc);
      nodes.push(
        <rect
          key="lasso"
          x={Math.min(a.x, b.x)}
          y={Math.min(a.y, b.y)}
          width={Math.abs(b.x - a.x)}
          height={Math.abs(b.y - a.y)}
          fill="var(--cc-accent, #3b82f6)"
          fillOpacity={0.08}
          stroke="var(--cc-accent, #3b82f6)"
          strokeOpacity={0.65}
          strokeWidth={1.5}
          strokeDasharray="5 3"
          rx={2}
        />,
      );
    } else if (kind.t === "newBox") {
      const a = sourceToView(drag.startSrc);
      const b = sourceToView(drag.currentSrc);
      nodes.push(
        <rect
          key="newbox"
          x={Math.min(a.x, b.x)}
          y={Math.min(a.y, b.y)}
          width={Math.abs(b.x - a.x)}
          height={Math.abs(b.y - a.y)}
          fill="var(--cc-accent, #3b82f6)"
          fillOpacity={0.08}
          stroke="var(--cc-accent, #3b82f6)"
          strokeWidth={1.5}
          strokeDasharray="4 3"
          rx={2}
        />,
      );
    } else if (kind.t === "freeform" && kind.path.length > 1) {
      const d = strokePath(kind.path, sourceToView);
      nodes.push(
        <path
          key="freeform"
          d={d}
          fill="none"
          stroke="var(--cc-accent, #3b82f6)"
          strokeWidth={2}
          strokeLinecap="round"
          strokeLinejoin="round"
          strokeDasharray="4 3"
        />,
      );
    } else if (kind.t === "splitStroke" && kind.path.length > 1) {
      const d = strokePath(kind.path, sourceToView);
      nodes.push(
        <path
          key="split"
          d={d}
          fill="none"
          stroke="var(--cc-info, #06b6d4)"
          strokeWidth={2}
          strokeLinecap="round"
          strokeLinejoin="round"
        />,
      );
    } else if (kind.t === "resize") {
      // Live preview of the resized outline (committed only on release).
      const cell = editor.cells.find((c) => c.id === kind.cellId);
      if (cell) {
        const center = sourceToView({ x: cell.cx, y: cell.cy });
        const rView = (kind.liveDiameterPx * viewScale) / 2;
        nodes.push(
          <circle
            key="resize-preview"
            cx={center.x}
            cy={center.y}
            r={rView}
            fill="none"
            stroke="var(--cc-accent, #3b82f6)"
            strokeWidth={1.5}
            strokeDasharray="4 3"
          />,
        );
      }
    }
    return nodes;
  })();

  // Resize handles + delete floater for the single active selection.
  const singleSelected =
    selectedCellIds.size === 1
      ? editor.cells.find((c) => selectedCellIds.has(c.id))
      : undefined;

  const handleNodes = useMemo(() => {
    if (!singleSelected || editorMode === "merge" || editorMode === "annotate") {
      return null;
    }
    const c = singleSelected;
    const center = sourceToView({ x: c.cx, y: c.cy });
    const r = (c.diameterPx * viewScale) / 2;
    const corners: Array<{ id: Corner; x: number; y: number }> = [
      { id: "tl", x: center.x - r, y: center.y - r },
      { id: "tr", x: center.x + r, y: center.y - r },
      { id: "bl", x: center.x - r, y: center.y + r },
      { id: "br", x: center.x + r, y: center.y + r },
    ];
    return (
      <g>
        {corners.map((k) => (
          <rect
            key={k.id}
            x={k.x - HANDLE_SIZE / 2}
            y={k.y - HANDLE_SIZE / 2}
            width={HANDLE_SIZE}
            height={HANDLE_SIZE}
            fill="#ffffff"
            stroke="var(--cc-accent, #3b82f6)"
            strokeWidth={1}
          />
        ))}
      </g>
    );
  }, [singleSelected, editorMode, sourceToView, viewScale]);

  const deleteFloater = useMemo(() => {
    if (!singleSelected || editorMode === "merge" || editorMode === "annotate") {
      return null;
    }
    const c = singleSelected;
    const center = sourceToView({ x: c.cx, y: c.cy });
    const r = (c.diameterPx * viewScale) / 2;
    const fx = center.x + r + 14;
    const fy = center.y - r - 4;
    return (
      <g
        transform={`translate(${fx} ${fy})`}
        style={{ cursor: "pointer" }}
        onPointerDown={(e) => {
          e.stopPropagation();
          editor.remove([c.id]);
          setSelectedCellIds(new Set());
        }}
      >
        <circle r={11} fill="var(--cc-danger, #ef4444)" />
        <path
          d="M -3.5 -3.5 L 3.5 3.5 M 3.5 -3.5 L -3.5 3.5"
          stroke="#ffffff"
          strokeWidth={2}
          strokeLinecap="round"
        />
      </g>
    );
  }, [singleSelected, editorMode, sourceToView, viewScale, editor, setSelectedCellIds]);

  // The staged-merge / staged-split rings are drawn by MaskOverlay (feat-results-
  // viewer) via its mergeStagedId/splitStagedId props; expose them through the
  // store-driven surface here by re-rendering with the local staging ids as an
  // extra selection ring so the affordance is visible even if the sibling
  // overlay isn't fed our staging ids.
  const stagingRing = useMemo(() => {
    const nodes: React.ReactNode[] = [];
    const drawRing = (id: string | undefined, color: string) => {
      if (!id) return;
      const c = editor.cells.find((x) => x.id === id);
      if (!c) return;
      const center = sourceToView({ x: c.cx, y: c.cy });
      const r = (c.diameterPx * viewScale) / 2 + 2;
      nodes.push(
        <circle
          key={`stage-${id}`}
          cx={center.x}
          cy={center.y}
          r={r}
          fill="none"
          stroke={color}
          strokeWidth={2}
        />,
      );
    };
    drawRing(mergeFirstId, "var(--cc-warning, #eab308)");
    drawRing(splitStagedId, "var(--cc-info, #06b6d4)");
    return nodes;
  }, [mergeFirstId, splitStagedId, editor, sourceToView, viewScale]);

  const cursor =
    editorMode === "manualCount" || editorMode === "annotate"
      ? "crosshair"
      : editorMode === "add"
        ? "copy"
        : editorMode === "remove"
          ? "crosshair"
          : "default";

  return (
    <svg
      ref={svgRef}
      width="100%"
      height="100%"
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerCancel}
      onContextMenu={onContextMenu}
      style={{
        position: "absolute",
        inset: 0,
        // The surface always receives pointer events (unlike the read-only
        // overlay) — even view mode uses them to select. It stops-propagation
        // on pointerdown so the Viewport pans only on truly empty canvas.
        pointerEvents: "auto",
        overflow: "visible",
        cursor,
        touchAction: "none",
      }}
    >
      {stagingRing}
      {previews}
      {handleNodes}
      {deleteFloater}
    </svg>
  );
}

// ---------------------------------------------------------------------------
// free helpers
// ---------------------------------------------------------------------------

/** Recompute the selection set from the in-flight lasso rect (port of updateSelectionFromRect). */
function updateLasso(
  st: DragState,
  editor: MaskEditorApi,
  setSelectedCellIds: (ids: Set<string>) => void,
): void {
  if (st.kind.t !== "lasso") return;
  const r = rectFrom(st.startSrc, st.currentSrc);
  const inside = editor.cellsInRect(r).map((c) => c.id);
  if (st.kind.extend) {
    setSelectedCellIds(new Set([...st.kind.baseline, ...inside]));
  } else {
    setSelectedCellIds(new Set(inside));
  }
}

/**
 * Finalise a new-box drag into a plain (non-manual) cell (port of
 * finalizeNewBox). Side = the longer bbox edge; guarded at > 2px. The engine's
 * public API has no "add plain box", but `addFromContour` produces exactly a
 * non-manual, confidence-1 cell whose `contourPx` is the drawn polygon — so we
 * hand it the four corners of a `side × side` square centered on the drag. That
 * renders as a filled box (not a manual pin) and records a plain "add"
 * correction in add mode, matching the Swift audit trail. No cell is fabricated
 * directly; all state changes go through the engine.
 */
function finalizeNewBox(editor: MaskEditorApi, a: Pt, b: Pt): void {
  const side = Math.max(Math.abs(b.x - a.x), Math.abs(b.y - a.y));
  if (side <= 2) return;
  const cx = (a.x + b.x) / 2;
  const cy = (a.y + b.y) / 2;
  const h = side / 2;
  const square: Pt[] = [
    { x: cx - h, y: cy - h },
    { x: cx + h, y: cy - h },
    { x: cx + h, y: cy + h },
    { x: cx - h, y: cy + h },
  ];
  editor.addFromContour(square);
}

/** Build an SVG polyline path (view-px) from a source-px stroke. */
function strokePath(path: Pt[], sourceToView: (p: Pt) => Pt): string {
  if (path.length === 0) return "";
  const p0 = sourceToView(path[0]);
  let d = `M ${p0.x} ${p0.y}`;
  for (let i = 1; i < path.length; i++) {
    const p = sourceToView(path[i]);
    d += ` L ${p.x} ${p.y}`;
  }
  return d;
}

/**
 * Nearest ground-truth annotation to a source-px point, within a zoom-aware
 * pick radius (port of annotationHitTest). Returns undefined when none is close.
 */
function nearestAnnotation(
  editor: MaskEditorApi,
  p: Pt,
  viewScale: number,
): { id: string } | undefined {
  const anns = editor.annotations;
  if (!anns.length) return undefined;
  const hitRadiusSrc = Math.max(2.0, (6 + 4) / Math.max(viewScale, 0.0001));
  const r2 = hitRadiusSrc * hitRadiusSrc;
  for (let i = anns.length - 1; i >= 0; i--) {
    const a = anns[i];
    const dx = p.x - a.cx;
    const dy = p.y - a.cy;
    if (dx * dx + dy * dy <= r2) return { id: a.id };
  }
  return undefined;
}

/**
 * Which resize handle (if any) sits under a view-px point, for the single
 * active selection. Returns the cell id + corner, or undefined.
 */
function resizeHandleAt(
  editor: MaskEditorApi,
  selectedCellIds: ReadonlySet<string>,
  view: Pt,
  sourceToView: (p: Pt) => Pt,
): { cellId: string; corner: Corner } | undefined {
  if (selectedCellIds.size !== 1) return undefined;
  const id = [...selectedCellIds][0];
  const c = editor.cells.find((x) => x.id === id);
  if (!c) return undefined;
  const center = sourceToView({ x: c.cx, y: c.cy });
  // View-px radius = (diameterPx/2)·viewScale, computed via the transform (no
  // direct viewScale here) so the hit corners match where the handles are drawn.
  const rightEdge = sourceToView({ x: c.cx + c.diameterPx / 2, y: c.cy });
  const rView = Math.abs(rightEdge.x - center.x);
  const corners: Array<{ id: Corner; x: number; y: number }> = [
    { id: "tl", x: center.x - rView, y: center.y - rView },
    { id: "tr", x: center.x + rView, y: center.y - rView },
    { id: "bl", x: center.x - rView, y: center.y + rView },
    { id: "br", x: center.x + rView, y: center.y + rView },
  ];
  const pad = HANDLE_SIZE; // generous hit area
  for (const k of corners) {
    if (Math.abs(view.x - k.x) <= pad && Math.abs(view.y - k.y) <= pad) {
      return { cellId: c.id, corner: k.id };
    }
  }
  return undefined;
}

export default EditingSurface;
