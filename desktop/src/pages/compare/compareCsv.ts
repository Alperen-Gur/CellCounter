/**
 * pages/compare/compareCsv.ts — the comparison CSV (feature `feat-compare`).
 *
 * Direct port of `BottomBar.writeCSV` in `Views/Compare/CompareView.swift`. One
 * row per (condition × size-bin) with the bin count, its percentage of that
 * condition's pooled cells, the condition total, and the batch count.
 *
 * The column order is the FROZEN contract from tasks.json (`feat-compare.output`):
 *
 *     condition,bin_label,count,percent,total_cells,batches
 *
 * Numeric formatting mirrors the Swift original exactly:
 *   - percent → 3 decimals (`String(format: "%.3f", pct)`), where
 *     `pct = total > 0 ? count / total * 100 : 0`,
 *   - count / total_cells / batches → plain integers.
 *
 * Bins come from `binsFromThresholds(thresholds)` and each cell is tallied with
 * `binIndex(diameterUm, thresholds)` — the kernel calibration math, never
 * re-implemented here.
 *
 * boundaries: this task owns "the comparison CSV" only. The generic export
 * formats (cells/summary/annotations/PDF/ROI) belong to `feat-export`; this file
 * is deliberately self-contained (the Swift Compare view wrote its own CSV, not
 * via ExportService) and pulls in no other export format.
 */

import type { CellDTO } from "../../kernel/types";
import {
  binsFromThresholds,
  binIndex,
} from "../../kernel/calibration/calibration";
import type { PooledCondition } from "./comparePooling";

/** The frozen CSV header, in the exact required column order. */
export const COMPARE_CSV_HEADER = [
  "condition",
  "bin_label",
  "count",
  "percent",
  "total_cells",
  "batches",
] as const;

/**
 * Escape a CSV field the way `CompareView.csvEscape` does: wrap in double quotes
 * and double any embedded quote iff the value contains a comma, quote, or
 * newline. (`bin_label` never needs it, but condition names can.)
 */
export function csvEscape(s: string): string {
  if (s.includes(",") || s.includes('"') || s.includes("\n")) {
    return '"' + s.replace(/"/g, '""') + '"';
  }
  return s;
}

/** Percent to 3 decimals, matching Swift `String(format: "%.3f", …)`. */
function pct3(count: number, total: number): string {
  const pct = total > 0 ? (count / total) * 100 : 0;
  return pct.toFixed(3);
}

/** Tally pooled cells into bins for a set of thresholds. */
function binCounts(cells: CellDTO[], thresholds: number[]): number[] {
  const bins = binsFromThresholds(thresholds);
  const counts = new Array<number>(bins.length).fill(0);
  for (const c of cells) {
    const idx = binIndex(c.diameterUm, thresholds);
    if (idx >= 0 && idx < counts.length) counts[idx] += 1;
  }
  return counts;
}

/**
 * Build the full comparison-CSV text (including a trailing newline, as the Swift
 * writer emits). Rows are grouped by condition, then by bin, in the same order
 * the panels are laid out.
 */
export function buildCompareCsv(
  pools: PooledCondition[],
  thresholds: number[],
): string {
  const bins = binsFromThresholds(thresholds);
  const lines: string[] = [COMPARE_CSV_HEADER.join(",")];

  for (const pool of pools) {
    const counts = binCounts(pool.cells, thresholds);
    const total = pool.cells.length;
    const batches = pool.batches.length;
    for (let i = 0; i < bins.length; i++) {
      const count = counts[i] ?? 0;
      lines.push(
        [
          csvEscape(pool.condition),
          csvEscape(bins[i].label),
          String(count),
          pct3(count, total),
          String(total),
          String(batches),
        ].join(","),
      );
    }
  }

  return lines.join("\n") + "\n";
}

/** A short `yyyyMMdd-HHmmss` stamp for the default filename (Swift `timestamp()`). */
export function csvTimestamp(d: Date = new Date()): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return (
    `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}` +
    `-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`
  );
}

/** Outcome of a save attempt so the page can surface a status line. */
export type CsvSaveResult =
  | { ok: true; path?: string }
  | { ok: false; cancelled: true }
  | { ok: false; cancelled: false; error: string };

// ---------------------------------------------------------------------------
// Saving the CSV to disk.
//
// The macOS original used an NSSavePanel. On Tauri that maps to
// `@tauri-apps/plugin-dialog` (`save`) + `@tauri-apps/plugin-fs` (`writeTextFile`)
// — neither of which is a declared dependency of the scaffold yet (see
// `pages/home/fileSources.ts`, which loads the dialog/fs plugins optionally the
// same way). So we load them dynamically and, if they are absent (or we are in a
// plain browser during the future WebGPU build), fall back to a Blob download.
// ---------------------------------------------------------------------------

/** Minimal shape of the dialog plugin's `save` we depend on. */
interface DialogSaveModule {
  save(options: {
    defaultPath?: string;
    filters?: { name: string; extensions: string[] }[];
  }): Promise<string | null>;
}

/** Minimal shape of the fs plugin's `writeTextFile` we depend on. */
interface FsWriteModule {
  writeTextFile(path: string, contents: string): Promise<void>;
}

async function loadDialogSave(): Promise<DialogSaveModule | null> {
  try {
    const spec = "@tauri-apps/plugin-dialog";
    const mod = (await import(/* @vite-ignore */ spec)) as unknown as DialogSaveModule;
    return typeof mod.save === "function" ? mod : null;
  } catch {
    return null;
  }
}

async function loadFsWrite(): Promise<FsWriteModule | null> {
  try {
    const spec = "@tauri-apps/plugin-fs";
    const mod = (await import(/* @vite-ignore */ spec)) as unknown as FsWriteModule;
    return typeof mod.writeTextFile === "function" ? mod : null;
  } catch {
    return null;
  }
}

/** Last-resort browser download (also serves the future WebGPU build). */
function downloadInBrowser(csv: string, filename: string): boolean {
  try {
    if (typeof document === "undefined" || typeof URL === "undefined") {
      return false;
    }
    const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    // Revoke on the next tick so the click has a chance to start the download.
    setTimeout(() => URL.revokeObjectURL(url), 0);
    return true;
  } catch {
    return false;
  }
}

/**
 * Save the comparison CSV. Prefers the native save panel (Tauri dialog + fs);
 * if those plugins aren't in the build, downloads via the browser instead so the
 * feature never silently no-ops. Returns a structured result the page renders as
 * a status line (mirrors the Swift `exportError` UX).
 */
export async function saveCompareCsv(
  csv: string,
  defaultFilename: string,
): Promise<CsvSaveResult> {
  const dialog = await loadDialogSave();
  const fs = await loadFsWrite();

  if (dialog && fs) {
    try {
      const path = await dialog.save({
        defaultPath: defaultFilename,
        filters: [{ name: "CSV", extensions: ["csv"] }],
      });
      if (path === null) return { ok: false, cancelled: true };
      await fs.writeTextFile(path, csv);
      return { ok: true, path };
    } catch (e) {
      return {
        ok: false,
        cancelled: false,
        error: e instanceof Error ? e.message : String(e),
      };
    }
  }

  // Fallback path (plugins absent / browser build).
  if (downloadInBrowser(csv, defaultFilename)) {
    return { ok: true };
  }
  return {
    ok: false,
    cancelled: false,
    error: "No save dialog available in this build.",
  };
}
