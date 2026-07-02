/**
 * pages/settings/binColors.ts — the size-bin color ramp for the threshold
 * swatches shown in the "Default bins" section.
 *
 * Mirrors the same 5-stop OKLCH ramp the read-only mask renderer
 * (`kernel/overlay/MaskOverlay.tsx`) and the Results/Compare sidebars use, so a
 * threshold row's swatch matches the color a cell in that bin is drawn with.
 * The ramp is private to the kernel today; we keep a byte-for-byte copy here to
 * avoid importing a sibling page's module (settings owns only pages/settings/).
 *
 * If the kernel later exports `binColor`, this file collapses to a re-export.
 * (Recorded as a kernel gap.)
 */

/** 5-stop OKLCH ramp — identical to `BIN_OKLCH` in MaskOverlay.tsx. */
const BIN_OKLCH: ReadonlyArray<readonly [number, number, number]> = [
  [0.45, 0.14, 280],
  [0.58, 0.13, 230],
  [0.68, 0.11, 180],
  [0.78, 0.13, 105],
  [0.82, 0.16, 60],
];

/** Bin color for index `i`, clamped to the ramp (matches `MaskOverlay.binColor`). */
export function binColor(i: number): string {
  const idx = Math.max(0, Math.min(i, BIN_OKLCH.length - 1));
  const [l, c, h] = BIN_OKLCH[idx];
  return `oklch(${l} ${c} ${h})`;
}
