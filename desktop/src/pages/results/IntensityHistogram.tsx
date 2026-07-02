/**
 * pages/results/IntensityHistogram.tsx — 256-bucket grayscale intensity
 * histogram for the current image.
 *
 * Port of `Views/Results/IntensityHistogram.swift`. The Swift version decodes
 * the stored image, downsamples to ≤512 px on the long edge, converts to
 * device-gray, and histograms the 8-bit values (min/max/mean/σ overlay). Here
 * the image is already decoded into an `<img>` for the Viewport, so we draw it
 * to an offscreen canvas at ≤512 px, read back the pixels, and grayscale with
 * the Rec.601 luma (matches CoreGraphics device-gray closely enough for a
 * qualitative exposure readout).
 *
 * Runs off the render path (in an effect) and bails silently on a canvas
 * read error (e.g. tainted canvas) — returning the empty state, never throwing.
 */

import { useEffect, useRef, useState } from "react";

interface HistData {
  buckets: number[]; // 256
  minVal: number;
  maxVal: number;
  mean: number;
  sigma: number;
}

const EMPTY: HistData = {
  buckets: new Array<number>(256).fill(0),
  minVal: 0,
  maxVal: 0,
  mean: 0,
  sigma: 0,
};

const CHART_H = 80;

/** Compute the histogram from a loaded HTMLImageElement. Returns EMPTY on failure. */
function computeHistogram(img: HTMLImageElement): HistData {
  const srcW = img.naturalWidth;
  const srcH = img.naturalHeight;
  if (srcW <= 0 || srcH <= 0) return EMPTY;

  const maxDim = 512;
  const scale = Math.min(1, maxDim / Math.max(srcW, srcH));
  const dstW = Math.max(1, Math.round(srcW * scale));
  const dstH = Math.max(1, Math.round(srcH * scale));

  const canvas = document.createElement("canvas");
  canvas.width = dstW;
  canvas.height = dstH;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx) return EMPTY;
  ctx.drawImage(img, 0, 0, dstW, dstH);

  let pixels: Uint8ClampedArray;
  try {
    pixels = ctx.getImageData(0, 0, dstW, dstH).data;
  } catch {
    // Tainted canvas (cross-origin) — give up gracefully.
    return EMPTY;
  }

  const buckets = new Array<number>(256).fill(0);
  let sum = 0;
  let minV = 255;
  let maxV = 0;
  let n = 0;
  for (let p = 0; p < pixels.length; p += 4) {
    // Rec.601 luma → 8-bit gray.
    const g = Math.round(
      0.299 * pixels[p] + 0.587 * pixels[p + 1] + 0.114 * pixels[p + 2],
    );
    const v = g < 0 ? 0 : g > 255 ? 255 : g;
    buckets[v] += 1;
    sum += v;
    if (v < minV) minV = v;
    if (v > maxV) maxV = v;
    n += 1;
  }
  const mean = n > 0 ? sum / n : 0;
  let variance = 0;
  for (let p = 0; p < pixels.length; p += 4) {
    const g = Math.round(
      0.299 * pixels[p] + 0.587 * pixels[p + 1] + 0.114 * pixels[p + 2],
    );
    const v = g < 0 ? 0 : g > 255 ? 255 : g;
    variance += (v - mean) * (v - mean);
  }
  const sigma = n > 1 ? Math.sqrt(variance / n) : 0;

  return { buckets, minVal: minV, maxVal: maxV, mean, sigma };
}

export interface IntensityHistogramProps {
  /** The convertFileSrc URL of the current image (same src the Viewport uses). */
  imageSrc: string | null;
  /** Changes when the current image changes — recompute trigger. */
  imageId: string | null;
}

export function IntensityHistogram({ imageSrc, imageId }: IntensityHistogramProps) {
  const [data, setData] = useState<HistData>(EMPTY);
  const reqRef = useRef(0);

  useEffect(() => {
    const req = ++reqRef.current;
    setData(EMPTY);
    if (!imageSrc) return;
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => {
      if (req !== reqRef.current) return;
      setData(computeHistogram(img));
    };
    img.onerror = () => {
      /* leave EMPTY */
    };
    img.src = imageSrc;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [imageSrc, imageId]);

  const maxBucket = Math.max(1, ...data.buckets);

  return (
    <div className="rv-intensity">
      <div className="rv-intensity__chart" style={{ height: CHART_H }}>
        <svg
          width="100%"
          height={CHART_H}
          viewBox={`0 0 256 ${CHART_H}`}
          preserveAspectRatio="none"
          role="img"
          aria-label="Intensity histogram"
        >
          {data.buckets.map((h, i) => {
            const barH = (h / maxBucket) * CHART_H;
            if (barH <= 0) return null;
            return (
              <rect
                key={i}
                x={i}
                y={CHART_H - barH}
                width={1}
                height={barH}
                fill="var(--cc-text)"
                opacity={0.6}
              />
            );
          })}
        </svg>
        {data.maxVal > 0 && (
          <span className="rv-intensity__stats">
            {`min: ${data.minVal} · max: ${data.maxVal} · mean: ${data.mean.toFixed(1)} · σ: ${data.sigma.toFixed(1)}`}
          </span>
        )}
      </div>
      <div className="rv-intensity__axis">
        <span>0</span>
        <span>128</span>
        <span>255</span>
      </div>
    </div>
  );
}
