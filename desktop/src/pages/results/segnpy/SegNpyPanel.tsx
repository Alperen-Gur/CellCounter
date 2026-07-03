/**
 * pages/results/segnpy/SegNpyPanel.tsx — Cellpose `_seg.npy` round-trip UI
 * (feature task `feat-seg-npy-io`).
 *
 * WHAT THIS MOUNTS AS. `feat-results-viewer` mounts `<SegNpyPanel/>` (no props)
 * in its `.rv-toolbar-mount` strip, alongside the editing toolbar. So this is a
 * compact toolbar: two actions —
 *   • Import `_seg.npy`  — pick a Cellpose `_seg.npy`, decode it via the Rust
 *     `seg_npy_import` command (masks → cells/contours through the SAME
 *     measurement loop the detector uses), then persist it as THIS image's 1:1
 *     detection via the frozen `PersistencePort.saveDetection`.
 *   • Export `_seg.npy`  — write the current image's cells to a Cellpose-
 *     compatible `_seg.npy` (`seg_npy_export`), losslessly (label map + outlines)
 *     so corrected masks open in the Cellpose GUI and can feed the future
 *     train-from-GUI seam (ARCHITECTURE.md §3.5 note).
 *
 * DATA. Like the sibling editing toolbar, this panel is mounted OUTSIDE
 * `useResultsData`, so it resolves the current image itself from the store
 * (`currentBatchId` + `currentImageIdx`) through `getPort()` and reads the
 * image's detection on demand. Geometry stays SOURCE-PIXEL end to end.
 *
 * REFRESH. After a successful import we re-save the detection and dispatch a
 * `window` `CustomEvent("cc:detection-updated")` so listeners can re-read; the
 * surrounding Results sidebar (owned by feat-results-viewer) refreshes on its
 * own image-change cycle. `refreshLibraryStats()` keeps the badges current.
 *
 * BOUNDARY. Owns only pages/results/segnpy/. Uses only the frozen kernel:
 * `getTransport`-adjacent `invoke` for the two seg-npy commands, `getPort()` for
 * persistence, the store, and `kernel/types`. It imports nothing from
 * pages/results/ or pages/results/editing/.
 */

import { useCallback, useEffect, useRef, useState } from "react";

import type { BatchDTO, CellDTO, DetectionResultDTO, ImageDTO } from "../../../kernel/types";
import { getPort } from "../../../kernel/persistence";
import { useAppStore } from "../../../kernel/store/store";
import { Icon } from "../../../components/Icon";

import "./segnpy.css";

/** Event other parts of Results can listen for after an import replaces cells. */
export const DETECTION_UPDATED_EVENT = "cc:detection-updated";

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

/**
 * Shape of the (optional) dialog plugin we depend on. Declared locally so this
 * file compiles even though `@tauri-apps/plugin-dialog` is not in the v1 deps
 * (see kernelGaps) — same convention as pages/home/fileSources.ts.
 */
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
    const spec = "@tauri-apps/plugin-dialog";
    const mod = (await import(/* @vite-ignore */ spec)) as unknown as DialogModule;
    return typeof mod.open === "function" && typeof mod.save === "function" ? mod : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Current-image resolution (store batch/idx → ImageDTO), self-contained
// ---------------------------------------------------------------------------

/**
 * Resolve the current image AND its owning batch from the store's
 * `currentBatchId` + `currentImageIdx` through the port. Read-only.
 * Intentionally a local copy (not imported from editing/) so this feature owns
 * disjoint files.
 *
 * The batch is returned alongside the image because the seg-npy measurement must
 * size cells with the SAME calibration the batch was analyzed with
 * (`batch.pxPerUm` / `batch.thresholds`), not the live global slider — otherwise
 * imported cells diverge in scale/size-class from the rest of the batch.
 */
function useCurrentImage(): { image: ImageDTO | null; batch: BatchDTO | null } {
  const currentBatchId = useAppStore((s) => s.currentBatchId);
  const currentImageIdx = useAppStore((s) => s.currentImageIdx);
  const [image, setImage] = useState<ImageDTO | null>(null);
  const [batch, setBatch] = useState<BatchDTO | null>(null);

  useEffect(() => {
    let cancelled = false;
    if (!currentBatchId) {
      setImage(null);
      setBatch(null);
      return;
    }
    const port = getPort();
    void (async () => {
      try {
        const [b, all] = await Promise.all([
          port.batch(currentBatchId),
          port.allImages(),
        ]);
        if (cancelled) return;
        const imageId = b?.imageIds[currentImageIdx];
        setBatch(b);
        setImage(imageId ? all.find((i) => i.id === imageId) ?? null : null);
      } catch (err) {
        if (!cancelled) {
          console.warn("[SegNpyPanel] resolve image failed:", err);
          setImage(null);
          setBatch(null);
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [currentBatchId, currentImageIdx]);

  return { image, batch };
}

// ---------------------------------------------------------------------------
// The panel
// ---------------------------------------------------------------------------

type Status =
  | { kind: "idle" }
  | { kind: "busy"; label: string }
  | { kind: "ok"; label: string }
  | { kind: "error"; label: string };

export default function SegNpyPanel() {
  const { image, batch } = useCurrentImage();
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
    if (clearTimer.current) window.clearTimeout(clearTimer.current);
    if (s.kind === "ok" || s.kind === "error") {
      clearTimer.current = window.setTimeout(
        () => setStatus({ kind: "idle" }),
        s.kind === "error" ? 6000 : 3500,
      );
    }
  }, []);
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
    if (!image || busy) return;
    const dialog = await loadDialog();
    if (!dialog) {
      flash({
        kind: "error",
        label: "File picker unavailable (install @tauri-apps/plugin-dialog).",
      });
      return;
    }
    let picked: string | string[] | null;
    try {
      picked = await dialog.open({
        multiple: false,
        directory: false,
        title: "Import a Cellpose _seg.npy",
        filters: [{ name: "Cellpose segmentation", extensions: ["npy"] }],
      });
    } catch (err) {
      flash({ kind: "error", label: `Could not open picker: ${errText(err)}` });
      return;
    }
    const npyPath = Array.isArray(picked) ? picked[0] : picked;
    if (!npyPath) return; // user cancelled

    // Guard a destructive overwrite: the import replaces this image's detection
    // wholesale, discarding any manual mask edits / resizes / rejects. Only
    // prompt when a detection already exists (a fresh image imports silently).
    try {
      const existing = await getPort().getDetection(image.id);
      if (existing && existing.cells.length > 0) {
        const ok =
          typeof window === "undefined" ||
          window.confirm(
            "Replace this image's detection with the imported masks?\n\n" +
              "The current detection and any manual edits on this image will be lost. This cannot be undone.",
          );
        if (!ok) return;
      }
    } catch {
      // Couldn't read the current detection — proceed (import is still valid).
    }

    flash({ kind: "busy", label: "Importing _seg.npy…" });
    try {
      // Decode masks → cells through the Rust command (runs the venv helper).
      const result = await tauriInvoke<DetectionResultDTO>("seg_npy_import", {
        imagePath: image.storedPath,
        npyPath,
        pxPerUm,
        smallThresholdUm: smallT,
        largeThresholdUm: largeT,
      });

      // Persist as this image's 1:1 detection (replaces any existing one). We
      // stamp a seg-npy detector id so provenance shows where the masks came
      // from; the sidebar recomputes counts/bins from the new cells.
      const port = getPort();
      await port.saveDetection(
        image.id,
        "cellpose/_seg.npy",
        result.cells,
        result.imageStats,
      );

      // Nudge dependent views: refresh library badges + broadcast the change.
      void useAppStore.getState().refreshLibraryStats();
      window.dispatchEvent(
        new CustomEvent(DETECTION_UPDATED_EVENT, {
          detail: { imageId: image.id, source: "seg-npy-import" },
        }),
      );

      flash({
        kind: "ok",
        label: `Imported ${result.cells.length} cell${result.cells.length === 1 ? "" : "s"}.`,
      });
    } catch (err) {
      flash({ kind: "error", label: `Import failed: ${errText(err)}` });
    }
  }, [image, busy, pxPerUm, smallT, largeT, flash]);

  // ── EXPORT ──────────────────────────────────────────────────────────────
  const onExport = useCallback(async () => {
    if (!image || busy) return;
    const dialog = await loadDialog();
    if (!dialog) {
      flash({
        kind: "error",
        label: "File picker unavailable (install @tauri-apps/plugin-dialog).",
      });
      return;
    }

    // Read the current cells fresh from persistence (the panel doesn't hold the
    // live editing engine — the on-disk detection is the source of truth here).
    let cells: CellDTO[] = [];
    try {
      const port = getPort();
      const det = await port.getDetection(image.id);
      cells = det?.cells ?? [];
    } catch (err) {
      flash({ kind: "error", label: `Could not read cells: ${errText(err)}` });
      return;
    }
    if (cells.length === 0) {
      flash({ kind: "error", label: "No cells to export for this image." });
      return;
    }

    // Cellpose convention: "<image-stem>_seg.npy" next to nothing in particular;
    // we default the save name to that so a GUI user finds it beside the image.
    const stem = fileStem(image.fileName) || "cellcounter";
    let outPath: string | null;
    try {
      outPath = await dialog.save({
        title: "Export cells as Cellpose _seg.npy",
        defaultPath: `${stem}_seg.npy`,
        filters: [{ name: "Cellpose segmentation", extensions: ["npy"] }],
      });
    } catch (err) {
      flash({ kind: "error", label: `Could not open save dialog: ${errText(err)}` });
      return;
    }
    if (!outPath) return; // cancelled

    flash({ kind: "busy", label: "Exporting _seg.npy…" });
    try {
      const written = await tauriInvoke<string>("seg_npy_export", {
        imagePath: image.storedPath,
        cells,
        imageWidth: image.widthPx,
        imageHeight: image.heightPx,
        outPath,
      });
      flash({ kind: "ok", label: `Exported → ${baseName(written)}` });
    } catch (err) {
      flash({ kind: "error", label: `Export failed: ${errText(err)}` });
    }
  }, [image, busy, flash]);

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
          disabled={busy}
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
          disabled={busy}
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
