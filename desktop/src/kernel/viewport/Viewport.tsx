/**
 * kernel/viewport/Viewport.tsx — pan / zoom / image render (ARCHITECTURE.md §3.4).
 *
 * Operates entirely in SOURCE-PIXEL space and hands children a `viewScale` /
 * `viewOffset` (via `ViewportTransformContext`) exactly like the Swift
 * `EditableOverlay`. Overlay + edit layers are `children` so they share one
 * coordinate transform.
 *
 * Interaction:
 *   - wheel / trackpad-pinch → zoom toward the cursor, clamped to
 *     [minZoom (0.4), maxZoom (4.0)]
 *   - drag on empty canvas → pan (children may stop-propagation to claim drags)
 *   - `onFit()` (⌘0) → the page resets zoom→1 (fit) and pan→0
 *
 * FROZEN CONTRACT (§6.5): `ViewportProps` + the `ViewportTransform` context.
 */

import {
  createContext,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
  type WheelEvent as ReactWheelEvent,
} from "react";

import { useViewportTransform, fitScaleFor } from "./useViewportTransform";

export type Pt = { x: number; y: number };

/** Provided to children so all hit-testing / render uses one transform. */
export interface ViewportTransform {
  /** source-px → view-px scale factor (fitScale · zoom). */
  viewScale: number;
  /** translation applied after scaling (centering + pan), in view-px. */
  viewOffset: Pt;
  sourceToView(p: Pt): Pt;
  viewToSource(p: Pt): Pt;
}

/**
 * Identity transform used as the context default (when a child is rendered
 * outside a `<Viewport>`). Real values always come from the provider.
 */
const IDENTITY_TRANSFORM: ViewportTransform = {
  viewScale: 1,
  viewOffset: { x: 0, y: 0 },
  sourceToView: (p) => p,
  viewToSource: (p) => p,
};

export const ViewportTransformContext =
  createContext<ViewportTransform>(IDENTITY_TRANSFORM);

export interface ViewportProps {
  /** decoded image (blob URL or convertFileSrc path). */
  imageSrc: string;
  sourceWidth: number;
  sourceHeight: number;
  zoom: number;
  pan: Pt;
  minZoom?: number; // default 0.4
  maxZoom?: number; // default 4.0
  onZoomChange(z: number): void;
  onPanChange(p: Pt): void;
  onFit(): void; // ⌘0
  children?: React.ReactNode; // overlay + edit layers, rendered in source-px via context
}

const DEFAULT_MIN_ZOOM = 0.4;
const DEFAULT_MAX_ZOOM = 4.0;

const clamp = (v: number, lo: number, hi: number): number =>
  Math.min(hi, Math.max(lo, v));

export function Viewport({
  imageSrc,
  sourceWidth,
  sourceHeight,
  zoom,
  pan,
  minZoom = DEFAULT_MIN_ZOOM,
  maxZoom = DEFAULT_MAX_ZOOM,
  onZoomChange,
  onPanChange,
  onFit,
  children,
}: ViewportProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState<{ w: number; h: number }>({ w: 0, h: 0 });

  // Measure the container and keep it up to date (ResizeObserver).
  useLayoutEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const measure = () => {
      const r = el.getBoundingClientRect();
      setSize({ w: r.width, h: r.height });
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const transform = useViewportTransform({
    containerWidth: size.w,
    containerHeight: size.h,
    sourceWidth,
    sourceHeight,
    zoom,
    pan,
  });

  // --- wheel / pinch zoom toward the cursor ---
  const handleWheel = useCallback(
    (e: ReactWheelEvent<HTMLDivElement>) => {
      // Trackpad pinch arrives as ctrlKey+wheel; normal wheel also zooms here
      // (the canvas has no scroll of its own). Prevent page scroll.
      e.preventDefault();
      const el = containerRef.current;
      if (!el) return;
      const rect = el.getBoundingClientRect();
      const cursor: Pt = { x: e.clientX - rect.left, y: e.clientY - rect.top };

      // Exponential zoom feels natural and is symmetric in/out.
      const factor = Math.exp(-e.deltaY * 0.0015);
      const nextZoom = clamp(zoom * factor, minZoom, maxZoom);
      if (nextZoom === zoom) return;

      // Keep the source point under the cursor fixed across the zoom.
      const src = transform.viewToSource(cursor);
      const fitScale = fitScaleFor(size.w, size.h, sourceWidth, sourceHeight);
      const nextViewScale = fitScale * nextZoom;
      const baseX = (size.w - sourceWidth * nextViewScale) / 2;
      const baseY = (size.h - sourceHeight * nextViewScale) / 2;
      const nextPan: Pt = {
        x: cursor.x - src.x * nextViewScale - baseX,
        y: cursor.y - src.y * nextViewScale - baseY,
      };

      onZoomChange(nextZoom);
      onPanChange(nextPan);
    },
    [
      zoom,
      minZoom,
      maxZoom,
      transform,
      size.w,
      size.h,
      sourceWidth,
      sourceHeight,
      onZoomChange,
      onPanChange,
    ],
  );

  // --- drag to pan (only when the event reaches the canvas, i.e. children
  //     didn't stop propagation to claim the drag for editing) ---
  const panState = useRef<{
    pointerId: number;
    startX: number;
    startY: number;
    startPan: Pt;
  } | null>(null);

  const handlePointerDown = useCallback(
    (e: ReactPointerEvent<HTMLDivElement>) => {
      // Only the container itself initiates a pan; a child overlay that wants
      // the drag calls stopPropagation on its own handler.
      if (e.target !== e.currentTarget) return;
      panState.current = {
        pointerId: e.pointerId,
        startX: e.clientX,
        startY: e.clientY,
        startPan: { ...pan },
      };
      e.currentTarget.setPointerCapture(e.pointerId);
    },
    [pan],
  );

  const handlePointerMove = useCallback(
    (e: ReactPointerEvent<HTMLDivElement>) => {
      const st = panState.current;
      if (!st || st.pointerId !== e.pointerId) return;
      onPanChange({
        x: st.startPan.x + (e.clientX - st.startX),
        y: st.startPan.y + (e.clientY - st.startY),
      });
    },
    [onPanChange],
  );

  const endPan = useCallback((e: ReactPointerEvent<HTMLDivElement>) => {
    const st = panState.current;
    if (!st || st.pointerId !== e.pointerId) return;
    panState.current = null;
    try {
      e.currentTarget.releasePointerCapture(e.pointerId);
    } catch {
      // capture may already be released — ignore.
    }
  }, []);

  // --- ⌘0 / Ctrl+0 fit-to-view ---
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "0") {
        e.preventDefault();
        onFit();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onFit]);

  // The image is positioned at viewOffset and sized to source·viewScale so it
  // shares the children's source-px transform exactly.
  const imgLeft = transform.viewOffset.x;
  const imgTop = transform.viewOffset.y;
  const imgW = sourceWidth * transform.viewScale;
  const imgH = sourceHeight * transform.viewScale;

  return (
    <div
      ref={containerRef}
      onWheel={handleWheel}
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={endPan}
      onPointerCancel={endPan}
      style={{
        position: "relative",
        width: "100%",
        height: "100%",
        overflow: "hidden",
        touchAction: "none",
        cursor: panState.current ? "grabbing" : "grab",
        userSelect: "none",
      }}
    >
      <img
        src={imageSrc}
        alt=""
        draggable={false}
        style={{
          position: "absolute",
          left: imgLeft,
          top: imgTop,
          width: imgW,
          height: imgH,
          imageRendering: transform.viewScale > 1 ? "pixelated" : "auto",
          pointerEvents: "none",
        }}
      />
      <ViewportTransformContext.Provider value={transform}>
        {children}
      </ViewportTransformContext.Provider>
    </div>
  );
}
