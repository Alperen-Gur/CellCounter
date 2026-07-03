/**
 * kernel/viewport/useMeasuredSize.ts — measure a flex-grow container so a
 * windowed list/grid (react-window) can be sized in explicit pixels.
 *
 * react-window needs an explicit pixel width + height. Consumers (the Library
 * grid, the Batch table) live inside the shell's `.cc-content` scroll pane
 * (which they don't own), so they let a wrapper flex to fill the remaining pane
 * height and measure it here — the same content-box measurement idiom
 * `kernel/viewport/Viewport.tsx` uses for its canvas. The virtualized child then
 * owns its own scroll.
 *
 * The single owner: both the Batch table and the Library grid import this hook,
 * so the measurement logic (including the sub-pixel guard) lives in one place.
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
