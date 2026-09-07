/** Cellpose mask import/export for the exact image supplied by Results.
 * Flush pending edits before I/O and clear run provenance before replacement.
 */

import { useCallback, useEffect, useRef, useState } from "react";

import type { BatchDTO, DetectionResultDTO, ImageDTO } from "../../../kernel/types";
import { getPort } from "../../../kernel/persistence";
import { useAppStore } from "../../../kernel/store/store";
import { Icon } from "../../../components/Icon";
import { saveWorkflowDocument, deleteWorkflowDocument } from "../../../kernel/workflow/workflowDocuments";
import { assertReviewImageWritable } from "../reviewWriteGuard";
import { replaceMasksWithProvenance } from "../maskVersions";
import { DETECTION_UPDATED_EVENT } from "../events";

import "./segnpy.css";


// ---------------------------------------------------------------------------
// Environment + lazy Tauri bridges (mirrors the app's graceful-degrade pattern)
// ---------------------------------------------------------------------------

function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/** `invoke` loaded lazily so this module type-checks + tree-shakes cleanly. */
async function tauriInvoke<T>(cmd: string, args: Record<string, unknown>): Promise<T> {
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<T>(cmd, args);
}

/** The desktop dialog plugin is unavailable in a plain browser preview. */
interface DialogModule {
  open(options: {
    multiple?: boolean;
    directory?: boolean;
    title?: string;
    defaultPath?: string;
    filters?: { name: string; extensions: string[] }[];
  }): Promise<string | string[] | null>;
  save(options: {
    title?: string;
    defaultPath?: string;
    filters?: { name: string; extensions: string[] }[];
  }): Promise<string | null>;
}

async function loadDialog(): Promise<DialogModule | null> {
  if (!isTauri()) return null;
  try {
    const mod = (await import("@tauri-apps/plugin-dialog")) as unknown as DialogModule;
    return typeof mod.open === "function" && typeof mod.save === "function" ? mod : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// The panel
// ---------------------------------------------------------------------------

type Status =
  | { kind: "idle" }
  | { kind: "busy"; label: string }
  | { kind: "ok"; label: string }
  | { kind: "error"; label: string };

export default function SegNpyPanel({ image, batch, disabled = false, beforeWrite, onBusyChange }: {
  image: ImageDTO | null; batch: BatchDTO | null; disabled?: boolean;
  beforeWrite: () => Promise<void>; onBusyChange: (busy: boolean) => void;
}) {
  const globalPxPerUm = useAppStore((s) => s.pxPerUm);
  const globalThresholds = useAppStore((s) => s.thresholds);

  // Prefer the owning batch's calibration + thresholds so imported masks are
  // sized/size-classed with the SAME scale the batch was analyzed with (the
  // detection used batch.pxPerUm; useResultsData prefers batch.thresholds).
  // Fall back to the global store only when no batch is resolved.
  const pxPerUm = batch?.pxPerUm ?? globalPxPerUm;
  const thresholds =
    batch?.thresholds && batch.thresholds.length > 0
      ? batch.thresholds
      : globalThresholds;

  const [status, setStatus] = useState<Status>({ kind: "idle" });
  // Auto-clear a success/error note after a moment so the toolbar stays tidy.
  const clearTimer = useRef<number | null>(null);
  const flash = useCallback((s: Status) => {
    setStatus(s);
    onBusyChange(s.kind === "busy");
    if (clearTimer.current) window.clearTimeout(clearTimer.current);
    if (s.kind === "ok" || s.kind === "error") {
      clearTimer.current = window.setTimeout(
        () => setStatus({ kind: "idle" }),
        s.kind === "error" ? 6000 : 3500,
      );
    }
  }, [onBusyChange]);
  useEffect(
    () => () => {
      if (clearTimer.current) window.clearTimeout(clearTimer.current);
    },
    [],
  );

  const busy = status.kind === "busy";

  // Size thresholds → small/large (µm), passed to the sidecar's
  // `--small-threshold` / `--large-threshold`. Use the SAME convention as the
  // detector ran with (detectionParamsFromStore): small = first threshold,
  // large = LAST threshold — so imported masks size-class consistently with the
  // batch's original detection when more than two thresholds are configured.
  const smallT = thresholds[0] ?? 20;
  const largeT =
    thresholds.length > 0 ? thresholds[thresholds.length - 1] : 30;

  // ── IMPORT ────────────────────────────────────────────────────────────────
  const onImport = useCallback(async () => {
    if (!image || busy || disabled) return;
    flash({ kind: "busy", label: "Choosing masks…" });
    let finished = false;
    try {
      const dialog = await loadDialog();
      if (!dialog) throw new Error("The file picker is unavailable in this environment.");
      const picked = await dialog.open({ multiple: false, title: "Import Cellpose masks", filters: [{ name: "Cellpose segmentation", extensions: ["npy"] }] });
      const npyPath = Array.isArray(picked) ? picked[0] : picked;
      if (!npyPath) return;
      await beforeWrite();
      assertReviewImageWritable(image.id);
      const existing = await getPort().getDetection(image.id);
      if (existing?.cells.length && !window.confirm("Replace this image's current masks? Save a mask version first if you want to keep the current edits.")) return;
      flash({ kind: "busy", label: "Importing _seg.npy…" });
      const result = await tauriInvoke<DetectionResultDTO>("seg_npy_import", {
        imagePath: image.storedPath, npyPath, pxPerUm, smallThresholdUm: smallT, largeThresholdUm: largeT,
      });
      await replaceMasksWithProvenance({ detectorId: "cellpose/_seg.npy", cells: result.cells, imageStats: result.imageStats, run: null }, {
        assertWritable: () => assertReviewImageWritable(image.id),
        deleteRun: () => deleteWorkflowDocument(`run-${image.id}`),
        saveDetection: (detector, cells, stats) => getPort().saveDetection(image.id, detector, cells, stats),
        saveRun: run => saveWorkflowDocument(`run-${image.id}`, run),
        newToken: () => crypto.randomUUID(),
        refresh: async () => {
          void useAppStore.getState().refreshLibraryStats().catch(() => {});
          window.dispatchEvent(new CustomEvent(DETECTION_UPDATED_EVENT, { detail: { imageId: image.id, source: "seg-npy-import" } }));
        },
      });
      flash({ kind: "ok", label: `Imported ${result.cells.length} cells.` });
      finished = true;
    } catch (err) {
      flash({ kind: "error", label: `Import failed: ${errText(err)}` });
      finished = true;
    } finally { if (!finished) flash({ kind: "idle" }); }
  }, [image, busy, disabled, pxPerUm, smallT, largeT, flash, beforeWrite]);

  const onExport = useCallback(async () => {
    if (!image || busy || disabled) return;
    flash({ kind: "busy", label: "Preparing export…" });
    let finished = false;
    try {
      await beforeWrite();
      assertReviewImageWritable(image.id);
      const dialog = await loadDialog();
      if (!dialog) throw new Error("The file picker is unavailable in this environment.");
      const detection = await getPort().getDetection(image.id);
      if (!detection?.cells.length) throw new Error("No cells to export for this image.");
      const outPath = await dialog.save({ title: "Export cells as Cellpose _seg.npy",
        defaultPath: `${fileStem(image.fileName) || "cellcounter"}_seg.npy`,
        filters: [{ name: "Cellpose segmentation", extensions: ["npy"] }],
      });
      if (!outPath) return;
      assertReviewImageWritable(image.id);
      const written = await tauriInvoke<string>("seg_npy_export", {
        imagePath: image.storedPath, cells: detection.cells,
        imageWidth: image.widthPx, imageHeight: image.heightPx, outPath,
      });
      flash({ kind: "ok", label: `Exported → ${baseName(written)}` });
      finished = true;
    } catch (err) {
      flash({ kind: "error", label: `Export failed: ${errText(err)}` });
      finished = true;
    } finally { if (!finished) flash({ kind: "idle" }); }
  }, [image, busy, disabled, flash, beforeWrite]);

  // Collapse the (`:empty`) toolbar mount when there's no image open.
  if (!image) return null;

  return (
    <div className="cc-segnpy" role="group" aria-label="Cellpose _seg.npy round-trip">
      <span className="cc-segnpy__label" title="Round-trip masks with the Cellpose GUI">
        _seg.npy
      </span>
      <div className="cc-segnpy__actions">
        <button
          type="button"
          className="cc-segnpy__btn"
          onClick={onImport}
          disabled={busy || disabled}
          title="Import a Cellpose _seg.npy as this image's masks"
        >
          <span className="cc-segnpy__glyph" aria-hidden="true">
            <Icon name="download" size={14} />
          </span>
          <span className="cc-segnpy__btn-label">Import</span>
        </button>
        <button
          type="button"
          className="cc-segnpy__btn"
          onClick={onExport}
          disabled={busy || disabled}
          title="Export the current cells as a Cellpose-compatible _seg.npy"
        >
          <span className="cc-segnpy__glyph" aria-hidden="true">
            <Icon name="upload" size={14} />
          </span>
          <span className="cc-segnpy__btn-label">Export</span>
        </button>
      </div>
      {status.kind !== "idle" && (
        <span
          className={`cc-segnpy__status cc-segnpy__status--${status.kind}`}
          role={status.kind === "error" ? "alert" : "status"}
        >
          {status.kind === "busy" && <span className="cc-segnpy__spinner" aria-hidden="true" />}
          {status.label}
        </span>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Small pure helpers
// ---------------------------------------------------------------------------

function errText(err: unknown): string {
  if (typeof err === "string") return err;
  if (err instanceof Error) return err.message;
  // Tauri command rejections arrive as the Rust `Err(String)` — often a bare
  // string, sometimes an object; stringify defensively.
  try {
    return JSON.stringify(err);
  } catch {
    return String(err);
  }
}

/** "dish_A_01.tif" → "dish_A_01" (strip the final extension). */
function fileStem(name: string): string {
  const base = baseName(name);
  const dot = base.lastIndexOf(".");
  return dot > 0 ? base.slice(0, dot) : base;
}

/** Last path component, tolerating both `/` and `\` separators. */
function baseName(path: string): string {
  const norm = path.replace(/\\/g, "/");
  const i = norm.lastIndexOf("/");
  return i >= 0 ? norm.slice(i + 1) : norm;
}
