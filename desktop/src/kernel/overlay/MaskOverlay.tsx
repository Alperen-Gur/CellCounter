/**
 * kernel/overlay/MaskOverlay.tsx — the read-only mask renderer (§3.5).
 *
 * Ported from the RENDER half of `Views/Results/EditableOverlay.swift`
 * (`cellsLayer` + `annotationsLayer`). Read-only: it draws, it never mutates —
 * all editing lives in the framework-free `MaskEditEngine` and its gesture layer
 * (`pages/results/editing/EditingSurface`), a SEPARATE sibling that sits ON TOP
 * of this overlay inside the same `<Viewport>` and shares the same source-px
 * transform via `ViewportTransformContext`.
 *
 * ── Why a <canvas> and not SVG ───────────────────────────────────────────────
 * The original implementation emitted one SVG `<g>/<polygon>` per cell and
 * recomputed every contour vertex through `sourceToView` on every pan/zoom
 * frame — thousands of DOM nodes plus a full re-project each frame, the main
 * jank source on 100+-image batches with thousands of cells each.
 *
 * This version draws every cell onto a single HTML `<canvas>`:
 *   - the canvas is sized to the container (× devicePixelRatio for crispness),
 *   - the source→view transform is applied ONCE via `ctx.setTransform`, so
 *     `contourPx` (already in source-px) is stroked/filled with NO per-vertex
 *     JS projection — the whole cell layer is one draw pass,
 *   - a `requestAnimationFrame`-coalesced effect redraws only when the transform
 *     or the visual inputs change,
 *   - cells whose bbox lies outside the visible source rect are culled.
 *
 * ── Visual semantics (identical to the SVG version) ─────────────────────────
 * Per cell, in SOURCE-PIXEL space (mapped through the enclosing transform):
 *   - a filled polygon from `contourPx` (bin-color fill at `maskOpacity`,
 *     bin-color outline; DASHED stroke when `confidence < confidenceCutoff`),
 *   - else a bbox/ellipse fallback chosen by `overlayMode`,
 *   - manual markers as fixed-radius numbered pins (accent circle + index),
 *   - ground-truth points as yellow crosshairs.
 * Selected / merge-staged / split-staged cells get an extra ring.
 *
 * Fixed-size affordances (marker radius, crosshair arms, stroke widths, dash
 * lengths, the `+2` selection-ring padding) are expressed in VIEW units exactly
 * as before: geometry that scales with zoom (contours, bbox/ellipse radii) is
 * drawn under the scaled CTM, while line widths / dash arrays are divided by
 * `viewScale` so a `strokeWidth={1}` renders as 1 view-px at any zoom, and the
 * pins / crosshairs / rings are drawn in view-px space around a single projected
 * center point. This is the pixel-for-pixel equivalent of the SVG output.
 *
 * Colors use CSS `oklch()` — the exact perceptual bin ramp ported from
 * `Theme/Tokens.swift` (bin1…bin5). Modern webviews accept `oklch()` for both
 * SVG paint and canvas `fillStyle`/`strokeStyle`.
 */

import { useContext, useEffect, useMemo, useRef } from "react";

import type { CellDTO, GroundTruthDTO, OverlayMode } from "../types";
import { binIndex } from "../calibration/calibration";
import { ViewportTransformContext } from "../viewport/Viewport";

export interface MaskOverlayProps {
  cells: CellDTO[];
  annotations?: GroundTruthDTO[];
  thresholds: number[]; // for bin coloring
  overlayMode: OverlayMode;
  confidenceCutoff: number; // cells below render dashed/uncertain
  showMaskFills: boolean;
  showOutlines: boolean;
  maskOpacity: number;
  selectedCellIds: ReadonlySet<string>;
  mergeStagedId?: string;
  splitStagedId?: string;
}

// ---------------------------------------------------------------------------
// Bin color ramp — ported from Tokens.swift (5 OKLCH stops, viridis-ish,
// colorblind-safe). Modern webviews render `oklch()` natively.
// ---------------------------------------------------------------------------

const BIN_OKLCH: ReadonlyArray<readonly [number, number, number]> = [
  [0.45, 0.14, 280], // bin1
  [0.58, 0.13, 230], // bin2
  [0.68, 0.11, 180], // bin3
  [0.78, 0.13, 105], // bin4
  [0.82, 0.16, 60], // bin5
];

/** Bin color for index `i`, clamped to the ramp (port of `Tokens.binColor`). */
function binColor(i: number): string {
  const idx = Math.max(0, Math.min(i, BIN_OKLCH.length - 1));
  const [l, c, h] = BIN_OKLCH[idx];
  return `oklch(${l} ${c} ${h})`;
}

// Fixed view-unit constants (unchanged from the SVG version). These are VIEW
// pixels — they must stay constant across zoom, so anything drawn under the
// scaled source→view CTM divides them by `viewScale` first.

/** Fixed pin radius (view units) for manual markers. */
const MANUAL_MARKER_RADIUS = 7;
/** Crosshair arm length (view units) for ground-truth annotations. */
const ANNOTATION_ARM = 6;

// Paint constants pulled from the SVG so the two renderers can't drift. These
// resolve the same CSS custom properties the SVG used, with identical fallbacks.
const ACCENT = "var(--cc-accent, #3b82f6)";
const WARNING = "var(--cc-warning, #eab308)";
const INFO = "var(--cc-info, #06b6d4)";
/** Dash pattern for uncertain (below-cutoff) cells — "3.5 3" in the SVG. */
const UNCERTAIN_DASH: readonly number[] = [3.5, 3];

/**
 * Snapshot of everything the draw pass reads, recomputed only when a visual
 * input actually changes. Keeping this behind `useMemo` means a pure
 * transform change (pan/zoom) reuses it and skips the array walk that builds
 * per-cell derived data — only the canvas is repainted.
 */
interface DrawModel {
  cells: CellDTO[];
  annotations: GroundTruthDTO[];
  overlayMode: OverlayMode;
  confidenceCutoff: number;
  showMaskFills: boolean;
  showOutlines: boolean;
  maskOpacity: number;
  selectedCellIds: ReadonlySet<string>;
  mergeStagedId?: string;
  splitStagedId?: string;
  /** Precomputed bin color per non-manual cell, keyed by cell id. */
  colorById: Map<string, string>;
}

export function MaskOverlay({
  cells,
  annotations,
  thresholds,
  overlayMode,
  confidenceCutoff,
  showMaskFills,
  showOutlines,
  maskOpacity,
  selectedCellIds,
  mergeStagedId,
  splitStagedId,
}: MaskOverlayProps) {
  const t = useContext(ViewportTransformContext);
  const { viewScale, viewOffset } = t;

  const canvasRef = useRef<HTMLCanvasElement>(null);
  // The wrapper is measured so the canvas backing store matches the container
  // (the SVG used width/height 100% + absolute inset:0; we replicate that box).
  const wrapRef = useRef<HTMLDivElement>(null);

  // Bin coloring depends only on cells + thresholds, not the transform — so a
  // pan/zoom never re-walks the cell list to recolor.
  const colorById = useMemo(() => {
    const m = new Map<string, string>();
    for (const c of cells) {
      if (c.isManual === true) continue;
      m.set(c.id, binColor(binIndex(c.diameterUm, thresholds)));
    }
    return m;
  }, [cells, thresholds]);

  // Everything the paint reads, gathered once per visual-input change. The
  // transform is intentionally NOT part of this object; it is read live in the
  // draw effect so hover/pan/zoom repaint without rebuilding the model.
  const model = useMemo<DrawModel>(
    () => ({
      cells,
      annotations: annotations ?? [],
      overlayMode,
      confidenceCutoff,
      showMaskFills,
      showOutlines,
      maskOpacity,
      selectedCellIds,
      mergeStagedId,
      splitStagedId,
      colorById,
    }),
    [
      cells,
      annotations,
      overlayMode,
      confidenceCutoff,
      showMaskFills,
      showOutlines,
      maskOpacity,
      selectedCellIds,
      mergeStagedId,
      splitStagedId,
      colorById,
    ],
  );

  // Single rAF-coalesced draw effect. Re-runs on any transform or model change;
  // multiple invalidations within a frame collapse to one paint.
  useEffect(() => {
    const canvas = canvasRef.current;
    const wrap = wrapRef.current;
    if (!canvas || !wrap) return;

    let rafId = 0;

    const paint = () => {
      rafId = 0;
      const ctx = canvas.getContext("2d");
      if (!ctx) return;

      // Size the backing store to the container × devicePixelRatio so 1 view-px
      // maps to `dpr` device-px and lines stay crisp on HiDPI / Retina. The CSS
      // size stays in view-px (the element fills the container via inset:0).
      const rect = wrap.getBoundingClientRect();
      const dpr = Math.max(1, window.devicePixelRatio || 1);
      const wCss = Math.max(0, Math.round(rect.width));
      const hCss = Math.max(0, Math.round(rect.height));
      const wDev = Math.round(wCss * dpr);
      const hDev = Math.round(hCss * dpr);
      // Resizing the canvas also clears it; only reassign when it actually
      // changed to avoid a redundant clear + reallocation each frame.
      if (canvas.width !== wDev || canvas.height !== hDev) {
        canvas.width = wDev;
        canvas.height = hDev;
      }
      if (wDev === 0 || hDev === 0) return;

      drawOverlay(ctx, model, {
        viewScale,
        viewOffset,
        dpr,
        widthView: wCss,
        heightView: hCss,
      });
    };

    // Schedule via rAF so a burst of pan/zoom/state updates paints once.
    rafId = requestAnimationFrame(paint);
    return () => {
      if (rafId) cancelAnimationFrame(rafId);
    };
  }, [model, viewScale, viewOffset]);

  return (
    <div
      ref={wrapRef}
      style={{
        position: "absolute",
        inset: 0,
        // READ-ONLY: never capture pointer events. The editing gesture layer is
        // a later sibling in the same Viewport and must receive every pointer.
        pointerEvents: "none",
        overflow: "hidden",
      }}
    >
      <canvas
        ref={canvasRef}
        // CSS size fills the wrapper; the backing store is sized in the effect.
        style={{
          position: "absolute",
          inset: 0,
          width: "100%",
          height: "100%",
          pointerEvents: "none",
        }}
      />
    </div>
  );
}

// Keep the historical default export alongside the named one so both import
// styles (`import { MaskOverlay }` and `import MaskOverlay`) resolve.
export default MaskOverlay;

// ===========================================================================
// Canvas drawing — pure, framework-free. Given a 2D context, the draw model,
// and the live view transform, it paints one frame. No React, no allocations
// per vertex; contours are stroked directly from source-px coordinates.
// ===========================================================================

interface DrawTransform {
  viewScale: number;
  viewOffset: { x: number; y: number };
  dpr: number;
  /** Canvas CSS size in VIEW pixels (device size ÷ dpr). */
  widthView: number;
  heightView: number;
}

/**
 * Paint the whole overlay for one frame.
 *
 * Two coordinate regimes are used, mirroring the SVG:
 *  - SOURCE→VIEW CTM (`ctx.setTransform`) for geometry that zooms: contour
 *    polygons and the bbox/ellipse fallbacks. Under this CTM, source-px map
 *    straight to device-px, so `contourPx` needs no JS projection. Stroke
 *    widths and dash lengths are divided by `viewScale` to stay view-constant.
 *  - VIEW space (device CTM = dpr scale, no source scaling) for fixed-size
 *    affordances: manual pins, annotation crosshairs, and selection rings,
 *    positioned at a single projected center per item.
 */
function drawOverlay(
  ctx: CanvasRenderingContext2D,
  model: DrawModel,
  tf: DrawTransform,
): void {
  const { viewScale, viewOffset, dpr, widthView, heightView } = tf;
  const safeScale = Math.max(viewScale, 0.0001);

  // Clear the full backing store in device space (identity transform).
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, widthView * dpr, heightView * dpr);

  // Project source-px → view-px (matches useViewportTransform.sourceToView).
  const sx = (x: number): number => x * viewScale + viewOffset.x;
  const sy = (y: number): number => y * viewScale + viewOffset.y;

  // Visible source rect for culling: invert the four view-space corners. Adding
  // a small margin (in source-px) keeps partially-visible cells and any pins
  // that overhang a cell edge from popping at the border.
  const vsMargin = 32 / safeScale; // ~32 view-px of slack, in source-px
  const srcMinX = (0 - viewOffset.x) / safeScale - vsMargin;
  const srcMinY = (0 - viewOffset.y) / safeScale - vsMargin;
  const srcMaxX = (widthView - viewOffset.x) / safeScale + vsMargin;
  const srcMaxY = (heightView - viewOffset.y) / safeScale + vsMargin;

  // ── Cell layer ────────────────────────────────────────────────────────────
  // Geometry pass uses the source→view CTM: setTransform pre-multiplies by dpr
  // so the composed matrix is device-px = source-px · (viewScale·dpr) + offset·dpr.
  ctx.setTransform(
    viewScale * dpr,
    0,
    0,
    viewScale * dpr,
    viewOffset.x * dpr,
    viewOffset.y * dpr,
  );
  ctx.lineJoin = "round";
  ctx.lineCap = "butt";

  // Deferred fixed-size affordances, collected during the geometry walk and
  // painted afterwards in view space so their sizes ignore zoom. We also assign
  // manual-marker sequence numbers here, in the same draw order as the SVG.
  interface Pin {
    x: number; // source-px center
    y: number;
    seq: number;
  }
  interface Ring {
    x: number; // source-px center
    y: number;
    rView: number; // radius already in VIEW px (diameterPx·viewScale/2 + 2)
    color: string;
    /** true → circle ring, false → rounded-rect ring (matches overlayMode). */
    round: boolean;
  }
  const pins: Pin[] = [];
  const rings: Ring[] = [];

  let manualSeq = 0;

  const {
    cells,
    overlayMode,
    confidenceCutoff,
    showMaskFills,
    showOutlines,
    maskOpacity,
    selectedCellIds,
    mergeStagedId,
    splitStagedId,
    colorById,
  } = model;

  // Stroke widths expressed in SOURCE units so they render at the intended
  // VIEW width under the scaled CTM (1 view-px ⇒ 1/viewScale source-px).
  const w1 = 1 / safeScale;
  const w15 = 1.5 / safeScale;
  const dashUncertain = UNCERTAIN_DASH.map((d) => d / safeScale);

  for (const c of cells) {
    const isManual = c.isManual === true;
    const isSelected = selectedCellIds.has(c.id);
    const isMergeStaged = mergeStagedId === c.id;
    const isSplitStaged = splitStagedId === c.id;
    const staged = isSelected || isMergeStaged || isSplitStaged;

    // rView is the cell's view-space radius (source diameter · viewScale / 2),
    // reused for the bbox/ellipse fallbacks and the selection ring.
    const rView = (c.diameterPx * viewScale) / 2;

    if (isManual) {
      // Manual markers are numbered in draw order regardless of visibility, so
      // the sequence matches the SVG even for off-screen pins. Only on-screen
      // pins are queued for painting.
      manualSeq += 1;
      if (inRange(c.cx, c.cy, srcMinX, srcMinY, srcMaxX, srcMaxY)) {
        pins.push({ x: c.cx, y: c.cy, seq: manualSeq });
        if (staged) {
          rings.push({
            x: c.cx,
            y: c.cy,
            rView: rView + 2,
            color: ringColor(isMergeStaged, isSplitStaged),
            // Manual markers have no contour; ring shape follows overlayMode.
            round: overlayMode === "outline",
          });
        }
      }
      continue;
    }

    // Cull non-manual cells whose bbox is fully outside the visible source rect.
    // Use the source-px half-extent (diameterPx/2) so contour overhang is kept.
    const halfPx = c.diameterPx / 2;
    if (
      !bboxIntersects(
        c.cx - halfPx,
        c.cy - halfPx,
        c.cx + halfPx,
        c.cy + halfPx,
        srcMinX,
        srcMinY,
        srcMaxX,
        srcMaxY,
      )
    ) {
      continue;
    }

    const col = colorById.get(c.id) ?? binColor(0);
    const isUncertain = c.confidence < confidenceCutoff;
    const hasContour = !!c.contourPx && c.contourPx.length >= 3;

    ctx.setLineDash(isUncertain ? dashUncertain : EMPTY_DASH);

    if (hasContour) {
      // Filled polygon straight from source-px contour — no per-vertex JS.
      const pts = c.contourPx as Array<[number, number]>;
      ctx.beginPath();
      ctx.moveTo(pts[0][0], pts[0][1]);
      for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
      ctx.closePath();
      if (showMaskFills) {
        ctx.globalAlpha = maskOpacity;
        ctx.fillStyle = col;
        ctx.fill();
        ctx.globalAlpha = 1;
      }
      if (showOutlines) {
        ctx.lineWidth = w1;
        ctx.strokeStyle = col;
        ctx.stroke();
      }
      if (staged) {
        // Contour cells always get a CIRCLE ring (matches SVG selectionRing).
        rings.push({
          x: c.cx,
          y: c.cy,
          rView: rView + 2,
          color: ringColor(isMergeStaged, isSplitStaged),
          round: true,
        });
      }
    } else if (overlayMode === "outline") {
      // Ellipse (circle) fallback. Fill floor at 0.18 as in the SVG.
      ctx.beginPath();
      ctx.arc(c.cx, c.cy, rView / safeScale, 0, Math.PI * 2);
      if (showMaskFills) {
        ctx.globalAlpha = Math.max(maskOpacity, 0.18);
        ctx.fillStyle = col;
        ctx.fill();
        ctx.globalAlpha = 1;
      }
      if (showOutlines) {
        ctx.lineWidth = w15;
        ctx.strokeStyle = col;
        ctx.stroke();
      }
      if (staged) {
        rings.push({
          x: c.cx,
          y: c.cy,
          rView: rView + 2,
          color: ringColor(isMergeStaged, isSplitStaged),
          round: true,
        });
      }
    } else {
      // Bounding-box fallback (rounded rect, rx=2 view-px). Fill floor 0.1.
      const halfView = rView / safeScale; // source-px half side
      const rxSrc = 2 / safeScale;
      roundRectPath(
        ctx,
        c.cx - halfView,
        c.cy - halfView,
        halfView * 2,
        halfView * 2,
        rxSrc,
      );
      if (showMaskFills) {
        ctx.globalAlpha = Math.max(maskOpacity, 0.1);
        ctx.fillStyle = col;
        ctx.fill();
        ctx.globalAlpha = 1;
      }
      if (showOutlines) {
        ctx.lineWidth = w15;
        ctx.strokeStyle = col;
        ctx.stroke();
      }
      if (staged) {
        // Bbox cells get a rounded-RECT ring (matches SVG selectionRing).
        rings.push({
          x: c.cx,
          y: c.cy,
          rView: rView + 2,
          color: ringColor(isMergeStaged, isSplitStaged),
          round: false,
        });
      }
    }
  }

  // Reset dash/alpha before the view-space pass.
  ctx.setLineDash(EMPTY_DASH);
  ctx.globalAlpha = 1;

  // ── Fixed-size affordance pass (VIEW space) ─────────────────────────────────
  // Switch to a device CTM that only applies dpr, so sizes below are literal
  // view-px. Positions are projected through sx()/sy() (2 mults + 2 adds each —
  // negligible, and only for on-screen pins/rings/annotations).
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

  // Selection / staging rings.
  for (const r of rings) {
    const cxv = sx(r.x);
    const cyv = sy(r.y);
    ctx.strokeStyle = r.color;
    ctx.lineWidth = 2;
    if (r.round) {
      ctx.beginPath();
      ctx.arc(cxv, cyv, r.rView, 0, Math.PI * 2);
      ctx.stroke();
    } else {
      // rounded-rect ring, rx=3 view-px, side = 2·rView (matches SVG rect ring).
      roundRectPath(ctx, cxv - r.rView, cyv - r.rView, r.rView * 2, r.rView * 2, 3);
      ctx.stroke();
    }
  }

  // Manual-marker pins: accent circle + white outline + centered index.
  if (pins.length > 0) {
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = "700 9px ui-monospace, monospace";
    for (const p of pins) {
      const cxv = sx(p.x);
      const cyv = sy(p.y);
      ctx.beginPath();
      ctx.arc(cxv, cyv, MANUAL_MARKER_RADIUS, 0, Math.PI * 2);
      ctx.fillStyle = ACCENT;
      ctx.fill();
      ctx.lineWidth = 1.5;
      ctx.strokeStyle = "#ffffff";
      ctx.stroke();
      ctx.fillStyle = "#ffffff";
      ctx.fillText(String(p.seq), cxv, cyv);
    }
  }

  // ── Annotation layer (ground-truth crosshairs), VIEW space ──────────────────
  for (const a of model.annotations) {
    if (!inRange(a.cx, a.cy, srcMinX, srcMinY, srcMaxX, srcMaxY)) continue;
    const cxv = sx(a.cx);
    const cyv = sy(a.cy);
    // Backing disc for contrast (r = ARM + 1), then the two warning-color arms,
    // then a tiny white center dot — identical to the SVG annotation node.
    ctx.beginPath();
    ctx.arc(cxv, cyv, ANNOTATION_ARM + 1, 0, Math.PI * 2);
    ctx.fillStyle = "rgba(0,0,0,0.30)";
    ctx.fill();

    ctx.strokeStyle = WARNING;
    ctx.lineWidth = 1.8;
    ctx.lineCap = "round";
    ctx.beginPath();
    ctx.moveTo(cxv - ANNOTATION_ARM, cyv);
    ctx.lineTo(cxv + ANNOTATION_ARM, cyv);
    ctx.moveTo(cxv, cyv - ANNOTATION_ARM);
    ctx.lineTo(cxv, cyv + ANNOTATION_ARM);
    ctx.stroke();
    ctx.lineCap = "butt";

    ctx.beginPath();
    ctx.arc(cxv, cyv, 1.25, 0, Math.PI * 2);
    ctx.fillStyle = "#ffffff";
    ctx.fill();
  }
}

// ---------------------------------------------------------------------------
// Small pure helpers
// ---------------------------------------------------------------------------

/** Reused empty dash array so we don't allocate one per cell. */
const EMPTY_DASH: number[] = [];

/** Ring color for the current staging state (matches SVG selectionRing). */
function ringColor(isMergeStaged: boolean, isSplitStaged: boolean): string {
  if (isMergeStaged) return WARNING;
  if (isSplitStaged) return INFO;
  return ACCENT;
}

/** Point-in-rect test (source-px) for pins / annotations. */
function inRange(
  x: number,
  y: number,
  minX: number,
  minY: number,
  maxX: number,
  maxY: number,
): boolean {
  return x >= minX && x <= maxX && y >= minY && y <= maxY;
}

/** Axis-aligned bbox intersection test (source-px) for cell culling. */
function bboxIntersects(
  aMinX: number,
  aMinY: number,
  aMaxX: number,
  aMaxY: number,
  bMinX: number,
  bMinY: number,
  bMaxX: number,
  bMaxY: number,
): boolean {
  return aMinX <= bMaxX && aMaxX >= bMinX && aMinY <= bMaxY && aMaxY >= bMinY;
}

/**
 * Trace a rounded-rect path into the current CTM. Radius is clamped to half the
 * shorter side so extreme values degrade gracefully. Used for bbox fills (in
 * source space) and bbox selection rings (in view space).
 */
function roundRectPath(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  r: number,
): void {
  const rr = Math.max(0, Math.min(r, w / 2, h / 2));
  ctx.beginPath();
  ctx.moveTo(x + rr, y);
  ctx.lineTo(x + w - rr, y);
  ctx.arcTo(x + w, y, x + w, y + rr, rr);
  ctx.lineTo(x + w, y + h - rr);
  ctx.arcTo(x + w, y + h, x + w - rr, y + h, rr);
  ctx.lineTo(x + rr, y + h);
  ctx.arcTo(x, y + h, x, y + h - rr, rr);
  ctx.lineTo(x, y + rr);
  ctx.arcTo(x, y, x + rr, y, rr);
  ctx.closePath();
}
