/**
 * pages/results/binColors.ts — the size-bin color ramp for sidebar swatches +
 * histogram bars.
 *
 * The read-only mask renderer (`kernel/overlay/MaskOverlay.tsx`) draws each cell
 * in a bin color from a 5-stop OKLCH ramp (port of `Tokens.binColor`), but keeps
 * that ramp private. The Results sidebar (size-bin rows, distribution bars) must
 * use the SAME colors so a swatch matches the mask it describes — so the ramp is
 * mirrored here, byte-for-byte, and both consume `binIndex` from calibration.
 *
 * If the kernel later exports `binColor`, this file collapses to a re-export.
 * (Recorded as a kernel gap by feat-results-viewer.)
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
