/**
 * kernel/calibration/calibration.ts — px/µm derivation helpers + size-binning
 * (ARCHITECTURE.md §3.6).
 *
 * Ported from `Services/EXIFCalibration.swift`, `Domain/SizeBin.swift`,
 * `Domain/CalibrationPreset.swift`, and `AppState.objectiveLabel`.
 *
 * The EXIF *probe* itself runs in Rust at import time (it needs the raw
 * TIFF/OME bytes) and returns a `CalibrationDTO`. This TS module owns the parts
 * that are pure and shared by both the desktop and browser builds:
 *   - the priority contract (`CALIBRATION_PRIORITY`) the Rust importer follows,
 *   - unit → µm conversion (`unitToUm`),
 *   - the built-in preset ladder + objective labelling,
 *   - µm size-binning (`binsFromThresholds`, `binIndex`).
 *
 * No platform deps.
 */

import type { CalibrationDTO, SizeBin } from "../types";

// ===========================================================================
// Calibration source priority (the contract the Rust importer follows)
// ===========================================================================

/**
 * Priority order the Rust importer probes, highest → lowest confidence
 * (matches the parser order in `EXIFCalibration.detectPxPerUm` and §3.6):
 *
 *   1. `omeXML`       — OME-XML in TIFF ImageDescription (tag 270):
 *                       PhysicalSizeX + PhysicalSizeXUnit (µm default) → high
 *   2. `tiffBaseline` — TIFF XResolution + ResolutionUnit
 *                       (2=inch÷25400, 3=cm÷10000); rejects 72/96/300 dpi
 *                       defaults; valid 0.001 < px/µm < 1000 → medium
 *   3. `imagej`       — ImageJ ImageDescription ("ImageJ=" prefix):
 *                       pixelWidth + unit → medium
 *   4. `olympus`      — Olympus vendor: "Calibration Value" + "Calibration Unit"
 *                       → low
 *
 * The importer returns `null` when nothing recognized. `preset`, `manual`, and
 * `default` are not probe outputs — they come from user/app choices downstream.
 */
export const CALIBRATION_PRIORITY: readonly CalibrationDTO["source"][] = [
  "omeXML",
  "tiffBaseline",
  "imagej",
  "olympus",
] as const;

/**
 * Convert a physical size `value` in `unit` to micrometers. Returns `null` for
 * unrecognized units. Mirrors `EXIFCalibration.convertToMicrons`:
 *   µm / um / micron / microns → ×1
 *   nm → ÷1e3,  pm → ÷1e6,  mm → ×1e3,  cm → ×1e4,  m → ×1e6
 */
export function unitToUm(value: number, unit: string): number | null {
  switch (unit.trim().toLowerCase()) {
    case "µm":
    case "um":
    case "micron":
    case "microns":
      return value;
    case "nm":
      return value / 1000.0;
    case "pm":
      return value / 1_000_000.0;
    case "mm":
      return value * 1000.0;
    case "cm":
      return value * 10000.0;
    case "m":
      return value * 1_000_000.0;
    default:
      return null;
  }
}

// ===========================================================================
// Built-in calibration presets + objective labelling
// ===========================================================================

/**
 * Built-in calibration presets, seeded on fresh installs (port of
 * `CalibrationPreset.builtIn`). 10× (2.6 px/µm) is the default — confirmed
 * against the reference phase-contrast keratinocyte imaging setup.
 */
export const BUILTIN_PRESETS: {
  name: string;
  pxPerUm: number;
  isDefault?: boolean;
}[] = [
  { name: "Olympus IX73 — 10×", pxPerUm: 2.6, isDefault: true },
  { name: "Olympus IX73 — 20×", pxPerUm: 5.2 },
  { name: "Olympus IX73 — 40×", pxPerUm: 10.4 },
  { name: "Zeiss Axio Vert.A1 — 20×", pxPerUm: 4.9 },
];

/**
 * Map a px/µm value to a human-readable objective label using the Olympus IX73
 * ladder (1.3 / 2.6 / 5.2 / 10.4 px/µm → 5× / 10× / 20× / 40×) with ±25%
 * tolerance, else "custom scale". Mirrors `AppState.objectiveLabel` /
 * `ScalePanel.objectiveLabel`.
 */
export function objectiveLabel(pxPerUm: number): string {
  const presets: [number, string][] = [
    [1.3, "5×"],
    [2.6, "10×"],
    [5.2, "20×"],
    [10.4, "40×"],
  ];
  const match = presets.find(([px]) => Math.abs(pxPerUm - px) / px < 0.25);
  return match ? `${match[1]} objective` : "custom scale";
}

// ===========================================================================
// Size binning (port of Domain/SizeBin.swift `BinMath`)
// ===========================================================================

/** Format a threshold: drop `.0` for integers, else one decimal (Swift `fmt`). */
function fmtThreshold(v: number): string {
  return Number.isInteger(v) ? String(v) : v.toFixed(1);
}

/**
 * Build the µm size bins from a list of ascending thresholds. `[20, 30]` →
 * `< 20 µm`, `20–30 µm`, `> 30 µm`. Empty thresholds → a single `all` bin
 * `[0, ∞)`. The top bin's `max` is `Infinity` (open top). Port of
 * `BinMath.bins(from:)`.
 */
export function binsFromThresholds(rawThresholds: number[]): SizeBin[] {
  // Sort defensively (matches Swift `BinMath.bins(from:)`) so out-of-order
  // thresholds can't emit inverted/empty interior bins.
  const thresholds = rawThresholds.slice().sort((a, b) => a - b);
  const first = thresholds.length > 0 ? thresholds[0] : undefined;
  const last =
    thresholds.length > 0 ? thresholds[thresholds.length - 1] : undefined;
  if (first === undefined || last === undefined) {
    return [{ min: 0, max: Infinity, label: "all" }];
  }
  const out: SizeBin[] = [];
  out.push({ min: 0, max: first, label: `< ${fmtThreshold(first)} µm` });
  for (let i = 0; i < thresholds.length - 1; i++) {
    const a = thresholds[i];
    const b = thresholds[i + 1];
    out.push({ min: a, max: b, label: `${fmtThreshold(a)}–${fmtThreshold(b)} µm` });
  }
  out.push({ min: last, max: Infinity, label: `> ${fmtThreshold(last)} µm` });
  return out;
}

/**
 * Index of the bin a `diameterUm` falls into, given the thresholds. Returns the
 * index of the first threshold the diameter is strictly below, else
 * `thresholds.length` (the open top bin). Port of `BinMath.binIndex`.
 *
 * For `[20, 30]`: `< 20` → 0, `[20, 30)` → 1, `>= 30` → 2. Aligns 1:1 with the
 * bins from `binsFromThresholds` (which uses half-open `[min, max)` interior
 * bins, top bin `[last, ∞)`).
 */
export function binIndex(diameterUm: number, rawThresholds: number[]): number {
  // Sort defensively (matches Swift `BinMath.binIndex(for:)`) so an unsorted
  // thresholds array can't miscount cells into the wrong bin.
  const thresholds = rawThresholds.slice().sort((a, b) => a - b);
  for (let i = 0; i < thresholds.length; i++) {
    if (diameterUm < thresholds[i]) return i;
  }
  return thresholds.length;
}
