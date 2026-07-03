/**
 * pages/review/ReviewCard.tsx — one Review-queue card.
 *
 * Read-only presentation of a single low-confidence cell (port of the Swift
 * `ReviewCardView`):
 *   - a tight crop around the cell (~5× diameter of context) drawn to a canvas,
 *     with the target cell's contour filled in its bin colour + a red "halo"
 *     ring so it's unmistakable, and neighbour cells caught in the crop drawn as
 *     de-emphasised outlines,
 *   - a bin label + diameter readout + a confidence bar,
 *   - an optional diameter slider when the card is in edit mode.
 *
 * All interaction is delegated up via `onEditChange`; this component owns no
 * persistence and no queue logic. The crop/overlay is redrawn imperatively to a
 * <canvas> (an offscreen-loaded <img> as the source) — the same approach as the
 * Swift `Canvas` overlay, kept dependency-free.
 *
 * Feature-owned by feat-review-queue. Uses kernel-types only (the geometry
 * helpers live in `reviewCrop.ts`; the bin colour ramp is mirrored locally with
 * the shell tokens, matching the read-only renderer's palette in spirit).
 */

import { useEffect, useMemo, useRef, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";

import type { CellDTO } from "../../kernel/types";
import type { ReviewItem } from "./useReviewQueue";
import {
  cellIntersectsCrop,
  computeCropRect,
  cropScale,
  reviewBinIndex,
  reviewBinLabel,
  type CropRect,
} from "./reviewCrop";

/** Canvas backing-store size (source of the crop; card scales it via CSS). */
const CANVAS_W = 560;
const CANVAS_H = 320;

/**
 * Size-bin palette (shell tokens). The read-only mask renderer uses a private
 * OKLCH ramp; here — inside a <canvas> that can't read CSS variables per-stroke
 * — we resolve the shell's `--cc-bin-*` trio to concrete strings and cycle them,
 * matching `pages/library/ImageThumbCell` (the same 3-stop token cycle the app
 * uses wherever the kernel ramp isn't imported).
 */
const BIN_TOKENS = ["--cc-bin-small", "--cc-bin-mid", "--cc-bin-large"];

/** convertFileSrc, guarded so a plain browser preview (no Tauri IPC) won't throw. */
function safeConvert(path: string): string | undefined {
  try {
    return convertFileSrc(path);
  } catch {
    return undefined;
  }
}

/** Resolve a CSS custom property to its computed value (for canvas strokes). */
function cssVar(name: string, fallback: string): string {
  if (typeof window === "undefined" || !window.getComputedStyle) return fallback;
  const v = window
    .getComputedStyle(document.documentElement)
    .getPropertyValue(name)
    .trim();
  return v || fallback;
}

function binColor(i: number): string {
  const token = BIN_TOKENS[Math.max(0, i) % BIN_TOKENS.length];
  return cssVar(token, "#4c9be8");
}

export interface ReviewCardProps {
  item: ReviewItem;
  thresholds: number[];
  /** Live diameter override while editing (µm), or null when not editing. */
  editingDiameter: number | null;
  /** Emit a new edit diameter (µm) as the slider moves. */
  onEditChange?: (diameterUm: number) => void;
  /** Peek card behind the top one: dimmed + non-interactive. */
  peek?: boolean;
}

export function ReviewCard({
  item,
  thresholds,
  editingDiameter,
  onEditChange,
  peek = false,
}: ReviewCardProps) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const [img, setImg] = useState<HTMLImageElement | null>(null);

  const imageSrc = useMemo(
    () => (item.image.storedPath ? safeConvert(item.image.storedPath) : undefined),
    [item.image.storedPath],
  );

  const activeDiameter = editingDiameter ?? item.cell.diameterUm;
  const binIdx = reviewBinIndex(activeDiameter, thresholds);
  const binLabel = reviewBinLabel(activeDiameter, thresholds);

  // ── load the full source image once per card (cancellable) ───────────────
  useEffect(() => {
    if (!imageSrc) {
      setImg(null);
      return;
    }
    let alive = true;
    const el = new Image();
    el.onload = () => {
      if (alive) setImg(el);
    };
    el.onerror = () => {
      if (alive) setImg(null);
    };
    el.src = imageSrc;
    return () => {
      alive = false;
      el.onload = null;
      el.onerror = null;
    };
  }, [imageSrc]);

  // ── draw the crop + overlay whenever the image / cell / edit changes ──────
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    ctx.clearRect(0, 0, CANVAS_W, CANVAS_H);
    // Sunken background so an unloaded / letterboxed crop still reads as a card.
    ctx.fillStyle = cssVar("--cc-bg-sidebar", "#eef0f3");
    ctx.fillRect(0, 0, CANVAS_W, CANVAS_H);

    if (!img) return;

    const crop: CropRect = computeCropRect(
      item.image.widthPx,
      item.image.heightPx,
      item.cell,
      CANVAS_W,
      CANVAS_H,
    );
    const scale = cropScale(crop, CANVAS_W, CANVAS_H);
    const renderedW = crop.width * scale;
    const renderedH = crop.height * scale;
    // Centre the rendered crop in the canvas (matches aspect-fit letterboxing).
    const offX = (CANVAS_W - renderedW) / 2;
    const offY = (CANVAS_H - renderedH) / 2;

    // Source-px point → canvas point.
    const tx = (px: number) => offX + (px - crop.x) * scale;
    const ty = (py: number) => offY + (py - crop.y) * scale;

    // 1) the cropped image region.
    ctx.save();
    ctx.beginPath();
    ctx.rect(offX, offY, renderedW, renderedH);
    ctx.clip();
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(
      img,
      crop.x,
      crop.y,
      crop.width,
      crop.height,
      offX,
      offY,
      renderedW,
      renderedH,
    );

    const targetId = item.cell.id;

    // 2) neighbours first (under the target ring), de-emphasised.
    for (const c of item.detection.cells) {
      if (c.id === targetId) continue;
      if (!cellIntersectsCrop(c, crop)) continue;
      const col = binColor(reviewBinIndex(c.diameterUm, thresholds));
      if (c.contourPx && c.contourPx.length >= 3) {
        strokeContour(ctx, c.contourPx, tx, ty, {
          fill: withAlpha(col, 0.12),
          stroke: withAlpha(col, 0.55),
          width: 0.8,
        });
      } else {
        strokeCircle(ctx, c, tx, ty, scale, {
          stroke: withAlpha(col, 0.55),
          width: 0.8,
        });
      }
    }

    // 3) the target cell — bin fill at 0.35 + a red halo ring.
    const col = binColor(binIdx);
    const danger = cssVar("--cc-danger", "#d1453b");
    if (item.cell.contourPx && item.cell.contourPx.length >= 3) {
      strokeContour(ctx, item.cell.contourPx, tx, ty, {
        fill: withAlpha(col, 0.35),
        stroke: col,
        width: 1.5,
      });
      // Red halo, then repaint the crisp colour stroke on top.
      strokeContour(ctx, item.cell.contourPx, tx, ty, {
        stroke: withAlpha(danger, 0.9),
        width: 2.5,
      });
      strokeContour(ctx, item.cell.contourPx, tx, ty, {
        stroke: col,
        width: 1.2,
      });
    } else {
      // Legacy fallback: circle from the (possibly edited) diameter.
      const activeDiameterPx =
        item.pxPerUm > 0 ? activeDiameter * item.pxPerUm : item.cell.diameterPx;
      const cx = tx(item.cell.cx);
      const cy = ty(item.cell.cy);
      const r = (activeDiameterPx * scale) / 2;
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.fillStyle = withAlpha(col, 0.35);
      ctx.fill();
      ctx.lineWidth = 1.5;
      ctx.strokeStyle = col;
      ctx.stroke();
      // Outer red highlight ring just beyond the circle.
      ctx.beginPath();
      ctx.arc(cx, cy, r + 3, 0, Math.PI * 2);
      ctx.lineWidth = 1.5;
      ctx.strokeStyle = withAlpha(danger, 0.9);
      ctx.stroke();
    }

    ctx.restore();
  }, [img, item, thresholds, binIdx, activeDiameter]);

  const confidencePct = Math.round(item.cell.confidence * 100);
  const confidenceClass =
    item.cell.confidence < 0.35
      ? "cc-review__conf-fill--danger"
      : item.cell.confidence < 0.55
        ? "cc-review__conf-fill--warn"
        : "cc-review__conf-fill--ok";

  // Slider bounds mirror the Swift card: 0.3×…2.5× the original diameter.
  const sliderMin = Math.max(2, item.cell.diameterUm * 0.3);
  const sliderMax = item.cell.diameterUm * 2.5;

  return (
    <div
      className={"cc-review__card" + (peek ? " cc-review__card--peek" : "")}
      aria-hidden={peek || undefined}
    >
      <div className="cc-review__crop">
        <canvas
          ref={canvasRef}
          width={CANVAS_W}
          height={CANVAS_H}
          className="cc-review__canvas"
          role="img"
          aria-label={`Detected cell crop, diameter ${activeDiameter.toFixed(
            1,
          )} µm, size bin ${binLabel}`}
        />
        {!img && (
          <div className="cc-review__crop-loading" aria-hidden="true">
            Loading…
          </div>
        )}
      </div>

      <div className="cc-review__card-meta">
        <div className="cc-review__card-row">
          <span
            className="cc-review__bin"
            style={{ borderColor: binColor(binIdx) }}
          >
            {binLabel}
          </span>
          <span className="cc-review__diameter">
            {activeDiameter.toFixed(1)} µm
          </span>
          <span className="cc-review__conf">
            <span className="cc-review__conf-track">
              <span
                className={"cc-review__conf-fill " + confidenceClass}
                style={{ width: `${Math.max(3, confidencePct)}%` }}
              />
            </span>
            <span className="cc-review__conf-pct">{confidencePct}%</span>
          </span>
        </div>

        {editingDiameter !== null && !peek && (
          <div className="cc-review__slider-row">
            <span className="cc-review__slider-unit">µm</span>
            <input
              type="range"
              className="cc-review__slider"
              min={sliderMin}
              max={sliderMax}
              step={0.1}
              value={editingDiameter}
              onChange={(e) => onEditChange?.(Number(e.target.value))}
              aria-label="Cell diameter (µm)"
            />
            <span className="cc-review__slider-value">
              {editingDiameter.toFixed(1)} µm
            </span>
          </div>
        )}

        <span className="cc-review__filename" title={item.image.fileName}>
          {item.image.fileName}
        </span>
      </div>
    </div>
  );
}

// ── canvas helpers ─────────────────────────────────────────────────────────

interface StrokeStyle {
  fill?: string;
  stroke?: string;
  width: number;
}

/** Trace a source-px polygon into canvas space and fill/stroke it. */
function strokeContour(
  ctx: CanvasRenderingContext2D,
  contour: Array<[number, number]>,
  tx: (px: number) => number,
  ty: (py: number) => number,
  style: StrokeStyle,
): void {
  ctx.beginPath();
  ctx.moveTo(tx(contour[0][0]), ty(contour[0][1]));
  for (let i = 1; i < contour.length; i++) {
    ctx.lineTo(tx(contour[i][0]), ty(contour[i][1]));
  }
  ctx.closePath();
  if (style.fill) {
    ctx.fillStyle = style.fill;
    ctx.fill();
  }
  if (style.stroke) {
    ctx.lineWidth = style.width;
    ctx.strokeStyle = style.stroke;
    ctx.stroke();
  }
}

/** Fallback circle (source-px diameter) for a legacy contour-less cell. */
function strokeCircle(
  ctx: CanvasRenderingContext2D,
  c: CellDTO,
  tx: (px: number) => number,
  ty: (py: number) => number,
  scale: number,
  style: StrokeStyle,
): void {
  const cx = tx(c.cx);
  const cy = ty(c.cy);
  const r = (c.diameterPx * scale) / 2;
  ctx.beginPath();
  ctx.arc(cx, cy, Math.max(0, r), 0, Math.PI * 2);
  if (style.fill) {
    ctx.fillStyle = style.fill;
    ctx.fill();
  }
  if (style.stroke) {
    ctx.lineWidth = style.width;
    ctx.strokeStyle = style.stroke;
    ctx.stroke();
  }
}

/**
 * Apply an alpha to a resolved colour string. Handles `#rgb`/`#rrggbb` and
 * `rgb()/oklch()/hsl()` by wrapping in a layer via `rgba`-style compositing;
 * falls back to the raw colour when it can't parse (still visible, just opaque).
 */
function withAlpha(color: string, alpha: number): string {
  const c = color.trim();
  // #rgb / #rrggbb → rgba(...)
  if (c.startsWith("#")) {
    const hex = c.slice(1);
    const full =
      hex.length === 3
        ? hex
            .split("")
            .map((ch) => ch + ch)
            .join("")
        : hex;
    if (full.length === 6) {
      const r = parseInt(full.slice(0, 2), 16);
      const g = parseInt(full.slice(2, 4), 16);
      const b = parseInt(full.slice(4, 6), 16);
      if (!Number.isNaN(r) && !Number.isNaN(g) && !Number.isNaN(b)) {
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
      }
    }
  }
  // Functional colours: use color-mix so alpha applies to oklch()/hsl()/rgb().
  return `color-mix(in srgb, ${c} ${Math.round(alpha * 100)}%, transparent)`;
}
