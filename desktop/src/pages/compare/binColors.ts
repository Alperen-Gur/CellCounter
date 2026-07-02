/**
 * pages/compare/binColors.ts — the size-bin color ramp for the Compare screen's
 * bin breakdown rows (feature `feat-compare`).
 *
 * Mirrors the same 5-stop OKLCH ramp the read-only mask renderer
 * (`kernel/overlay/MaskOverlay.tsx`) and the Results sidebar
 * (`pages/results/binColors.ts`) use, so a Compare bin swatch matches the mask
 * color for that size class. This task owns only `pages/compare/` and may not
 * import a sibling page's module, so the ramp is re-declared here byte-for-byte;
 * if the kernel later exports `binColor`, this collapses to a re-export.
 *
 * (The pooled-histogram bars are drawn in each condition's own plot color, per
 * the Swift `PooledHistogram`. This ramp is only for the per-bin breakdown, which
 * the Swift `BinBar` colors with `Tokens.binColor(i)`.)
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
