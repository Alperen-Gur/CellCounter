/**
 * pages/batch/useMeasuredSize.ts — measure a flex-grow container so the
 * windowed batch table (react-window FixedSizeList) can be sized in pixels.
 *
 * The batch table lives inside the shell's `.cc-content` scroll pane (which we
 * don't own), so we let the table body's wrapper flex to fill the remaining
 * pane height and measure it here — the same idiom `kernel/viewport/Viewport`
 * uses. The virtualized body then owns its own scroll for the per-image rows.
 *
 * Feature-owned by feat-batch; used only by this page directory.
 */

import { useLayoutEffect, useRef, useState, type RefObject } from "react";

export interface MeasuredSize {
  width: number;
  height: number;
}

/**
 * Attach the returned `ref` to a block element; the hook reports its current
 * content-box size and keeps it live via a `ResizeObserver`. Starts at
 * `{0,0}`; callers render nothing until height > 0.
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
