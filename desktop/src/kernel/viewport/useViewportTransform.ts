/**
 * kernel/viewport/useViewportTransform.ts — source-px ⇄ view-px math (§3.4).
 *
 * The Viewport renders the image at `viewScale = fitScale · zoom`, centered in
 * the container, offset by `pan`. Overlay + edit layers are drawn in
 * SOURCE-PIXEL space and use the returned `sourceToView` / `viewToSource` to
 * map — exactly the `viewScale` / `viewOffset` contract of the Swift
 * `EditableOverlay`.
 *
 * `fitScale` is the scale that makes the whole source image fit inside the
 * container (the `⌘0` "fit to view" baseline). User `zoom` multiplies it.
 *
 * Pure geometry — no React state here beyond `useMemo`, so the same math is
 * reused by the browser build.
 */

import { useMemo } from "react";

import type { Pt, ViewportTransform } from "./Viewport";

/** Compute the fit-to-view scale: fit the source image inside the container. */
export function fitScaleFor(
  containerWidth: number,
  containerHeight: number,
  sourceWidth: number,
  sourceHeight: number,
): number {
  if (sourceWidth <= 0 || sourceHeight <= 0) return 1;
  if (containerWidth <= 0 || containerHeight <= 0) return 1;
  return Math.min(containerWidth / sourceWidth, containerHeight / sourceHeight);
}

/**
 * Build the `ViewportTransform` for the current container size, source size,
 * zoom, and pan. The image is centered in the container at `fitScale · zoom`,
 * then translated by `pan`.
 *
 *   viewScale  = fitScale · zoom
 *   viewOffset = center-the-image + pan
 *   sourceToView(p) = p · viewScale + viewOffset
 *   viewToSource(p) = (p − viewOffset) / viewScale
 */
export function useViewportTransform(args: {
  containerWidth: number;
  containerHeight: number;
  sourceWidth: number;
  sourceHeight: number;
  zoom: number;
  pan: Pt;
}): ViewportTransform {
  const {
    containerWidth,
    containerHeight,
    sourceWidth,
    sourceHeight,
    zoom,
    pan,
  } = args;

  return useMemo<ViewportTransform>(() => {
    const fitScale = fitScaleFor(
      containerWidth,
      containerHeight,
      sourceWidth,
      sourceHeight,
    );
    const viewScale = fitScale * zoom;

    // Center the scaled image in the container, then apply pan.
    const scaledW = sourceWidth * viewScale;
    const scaledH = sourceHeight * viewScale;
    const offsetX = (containerWidth - scaledW) / 2 + pan.x;
    const offsetY = (containerHeight - scaledH) / 2 + pan.y;
    const viewOffset: Pt = { x: offsetX, y: offsetY };

    const safeScale = Math.max(viewScale, 0.0001);

    const sourceToView = (p: Pt): Pt => ({
      x: p.x * viewScale + viewOffset.x,
      y: p.y * viewScale + viewOffset.y,
    });
    const viewToSource = (p: Pt): Pt => ({
      x: (p.x - viewOffset.x) / safeScale,
      y: (p.y - viewOffset.y) / safeScale,
    });

    return { viewScale, viewOffset, sourceToView, viewToSource };
  }, [
    containerWidth,
    containerHeight,
    sourceWidth,
    sourceHeight,
    zoom,
    pan.x,
    pan.y,
  ]);
}
