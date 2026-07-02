/**
 * pages/library/useMeasuredSize.ts — measure a flex-grow container so the
 * windowed grid (react-window FixedSizeGrid) can be sized in pixels.
 *
 * react-window needs an explicit pixel width + height. The Library grid lives
 * inside the shell's `.cc-content` scroll pane (which we don't own), so we let a
 * wrapper flex to fill the remaining pane height and measure it here, exactly
 * like `kernel/viewport/Viewport.tsx` measures its canvas. The virtualized grid
 * then owns its own scroll for the (potentially 100s of) thumbnails.
 *
 * Feature-owned by feat-library-dedup; used only by this page directory.
 */

import { useLayoutEffect, useRef, useState, type RefObject } from "react";

export interface MeasuredSize {
  width: number;
  height: number;
}

/**
 * Attach the returned `ref` to a block element; the hook reports its current
 * content-box size and keeps it live via a `ResizeObserver` (window resize,
 * sidebar collapse, aggregate-strip growth, etc. all re-measure). Starts at
 * `{0,0}`; callers should render nothing / a placeholder until height > 0.
 */
export function useMeasuredSize<T extends HTMLElement = HTMLDivElement>(): {
  ref: RefObject<T | null>;
  size: MeasuredSize;
} {
  const ref = useRef<T>(null);
  const [size, setSize] = useState<MeasuredSize>({ width: 0, height: 0 });

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => {
      const r = el.getBoundingClientRect();
      // Only commit real changes so we don't thrash react-window on sub-pixel
      // reflows.
      setSize((prev) =>
        prev.width === r.width && prev.height === r.height
          ? prev
          : { width: r.width, height: r.height },
      );
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  return { ref, size };
}
