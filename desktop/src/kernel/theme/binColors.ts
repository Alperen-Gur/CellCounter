/**
 * kernel/theme/binColors.ts — the canonical size-bin color ramp.
 *
 * The read-only mask renderer (`kernel/overlay/MaskOverlay.tsx`) draws each cell
 * in a bin color from this 5-stop OKLCH ramp (a port of `Tokens.binColor`). The
 * Results sidebar, the Compare bin breakdown, and the Settings "Default bins"
 * swatches must all use the SAME colors so a swatch always matches the mask it
 * describes.
 *
 * This is the single source of truth: `MaskOverlay` and every page swatch import
 * `BIN_OKLCH` / `binColor` from here, so a ramp change (new stop, shifted hue)
 * happens in exactly one place and can never drift between the overlay and the
 * swatches. Pure, platform-free — runs identically in the desktop and future
 * browser builds.
 */

/** 5-stop OKLCH ramp (viridis-ish, colorblind-safe) — port of `Tokens.bin1…bin5`. */
export const BIN_OKLCH: ReadonlyArray<readonly [number, number, number]> = [
  [0.45, 0.14, 280], // bin1
  [0.58, 0.13, 230], // bin2
  [0.68, 0.11, 180], // bin3
  [0.78, 0.13, 105], // bin4
  [0.82, 0.16, 60], // bin5
];

/** Bin color for index `i`, clamped to the ramp (port of `Tokens.binColor`). */
export function binColor(i: number): string {
  const idx = Math.max(0, Math.min(i, BIN_OKLCH.length - 1));
  const [l, c, h] = BIN_OKLCH[idx];
  return `oklch(${l} ${c} ${h})`;
}
