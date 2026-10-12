/**
 * components/ExportPanel.tsx — result export surface (feature `feat-export`).
 *
 * The single entry point pages mount to export a result. It surfaces every
 * export format that the Rust `export` commands implement and calls them:
 *   - cells.csv           → `export_cells_csv`
 *   - summary.csv (batch) → `export_batch_summary_csv`
 *   - RoiSet.zip (ImageJ) → `export_imagej_roi`   (via _export_imagej_roi.py)
 *   - provenance.json     → `export_provenance`
 *   - report.pdf          → `export_pdf_report`
 *
 * Self-contained: with no props it derives the current image + batch + cells
 * from the store + `PersistencePort` exactly like `useResultsData` (batch →
 * images in `batch.imageIds` order → images[currentImageIdx] → detection.cells).
 * Callers may pin a specific `imageId` / `batchId` via props (Results passes the
 * open image; Batch passes the open batch).
 *
 * BOUNDARIES: this component owns the export UX. Pages call it; they do NOT embed
 * export logic. It imports only the kernel store, the frozen `PersistencePort`,
 * `@tauri-apps` invoke, the opener plugin, and the shared `applyRoiFilter` pure
 * helper (so exports honour the exact ROI include/exclude Results counts by,
 * rather than re-implementing that geometry). The column orders / formats live
 * in the Rust writers (the frozen output contract).
 *
 * Save location: each export opens a native Save panel via
 * `@tauri-apps/plugin-dialog` (already a declared dependency, as `compareCsv.ts`
 * uses it) and passes the chosen absolute path to the Rust command as `outPath`,
 * which the writer honors verbatim. If the dialog plugin is unavailable (e.g. a
 * plain browser build), the command falls back to a bare filename under the
 * app-data `Exports/` dir, and the panel offers "Reveal in folder".
 */

import { useEffect, useMemo, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { revealItemInDir } from "@tauri-apps/plugin-opener";

import type { BatchDTO, CellDTO, ImageDTO } from "../kernel/types";
import { getPort } from "../kernel/persistence";
import { useAppStore, effectiveConfidence } from "../kernel/store/store";
import { applyRoiFilter } from "../pages/results/roiFilter";
import { Icon, type IconName } from "./Icon";

export interface ExportPanelProps {
  /** Pin the image to export (Results). Defaults to the store's current image. */
  imageId?: string;
  /** Pin the batch for summary export (Batch). Defaults to the store's batch. */
  batchId?: string;
  /**
   * Show an explicit image picker for the per-image formats. Set by the Batch
   * export sheet, where the batch-titled header would otherwise silently target
   * a stale `currentImageIdx`. Results pins a single `imageId` and omits this.
   */
  showImagePicker?: boolean;
}

/** Minimal shape of the dialog plugin's `save` we depend on (see compareCsv). */
interface DialogSaveModule {
  save(options: {
    defaultPath?: string;
    filters?: { name: string; extensions: string[] }[];
  }): Promise<string | null>;
  open(options: {
    title?: string;
    directory?: boolean;
    multiple?: boolean;
  }): Promise<string | string[] | null>;
}

/** Load the Tauri save dialog, or null when the plugin isn't in the build. */
async function loadDialogSave(): Promise<DialogSaveModule | null> {
  try {
    const mod = (await import("@tauri-apps/plugin-dialog")) as unknown as DialogSaveModule;
    return typeof mod.save === "function" && typeof mod.open === "function" ? mod : null;
  } catch {
    return null;
  }
}

/** The file-dialog filter for a default filename's extension. */
function filterForFilename(name: string): { name: string; extensions: string[] } {
  const dot = name.lastIndexOf(".");
  const ext = dot >= 0 ? name.slice(dot + 1).toLowerCase() : "";
  const labels: Record<string, string> = {
    csv: "CSV",
    zip: "ZIP archive",
    json: "JSON",
    geojson: "GeoJSON",
    pdf: "PDF",
    md: "Markdown",
  };
  return { name: labels[ext] ?? "File", extensions: ext ? [ext] : [] };
}

/**
 * Cancellation sentinel: thrown when the user dismisses the Save panel so the
 * caller can distinguish a cancel from a real failure (a cancel is a no-op).
 */
const EXPORT_CANCELLED = Symbol("export-cancelled");

/**
 * Ask the user where to save, then return the chosen absolute path. Falls back
 * to the bare `defaultName` (→ app-data `Exports/`) when no dialog is available
 * so exports never silently no-op. Throws EXPORT_CANCELLED if the user cancels.
 */
async function chooseOutPath(
  defaultName: string,
  destination: "file" | "directory",
): Promise<string> {
  const dialog = await loadDialogSave();
  if (!dialog) return destination === "file" ? defaultName : "";
  if (destination === "directory") {
    const path = await dialog.open({
      title: "Choose export parent folder",
      directory: true,
      multiple: false,
    });
    if (path === null) throw EXPORT_CANCELLED;
    return Array.isArray(path) ? (path[0] ?? "") : path;
  }
  const path = await dialog.save({
    defaultPath: defaultName,
    filters: [filterForFilename(defaultName)],
  });
  if (path === null) throw EXPORT_CANCELLED;
  return path;
}

/** One export format the panel can run. */
type FormatId =
  | "cellsCsv"
  | "summaryCsv"
  | "imagejRoi"
  | "annotatedPng"
  | "batchAnnotated"
  | "geojson"
  | "provenance"
  | "pdf"
  | "markdown"
  | "groundTruthJson"
  | "groundTruthCsv"
  | "sampleBundle";

interface FormatDef {
  id: FormatId;
  label: string;
  hint: string;
  icon: IconName;
  /** false when the current context can't produce it (disabled). */
  enabled: boolean;
  /** Default filename offered in the Save panel. */
  defaultName: string;
  destination?: "file" | "directory";
  /** Run the export, writing to the user-chosen (or fallback) absolute path. */
  run: (outPath: string) => Promise<string | { path: string; warnings: string[] }>;
}

/** Strip the extension off a filename for a sensible export basename. */
function baseName(fileName: string): string {
  const dot = fileName.lastIndexOf(".");
  const stem = dot > 0 ? fileName.slice(0, dot) : fileName;
  // Keep only filesystem-safe chars (mirrors ExportService.sanitizeFilename).
  const cleaned = stem.replace(/[/\\:*?"<>|\x00-\x1F]+/g, "_").replace(/_+/g, "_");
  const trimmed = cleaned.replace(/^[ ._]+|[ ._]+$/g, "");
  return trimmed.length > 0 ? trimmed : "sample";
}

type RunState =
  | { kind: "idle" }
  | { kind: "running"; format: FormatId }
  | { kind: "done"; format: FormatId; path: string; warnings?: string[] }
  | { kind: "error"; format: FormatId; message: string };

export function ExportPanel({ imageId, batchId, showImagePicker }: ExportPanelProps) {
  const currentBatchId = useAppStore((s) => s.currentBatchId);
  const currentImageIdx = useAppStore((s) => s.currentImageIdx);
  const globalPxPerUm = useAppStore((s) => s.pxPerUm);
  const globalConfidence = useAppStore((s) => s.confidence);
  const overlayMode = useAppStore((s) => s.overlayMode);

  const effectiveBatchId = batchId ?? currentBatchId;

  const [batch, setBatch] = useState<BatchDTO | null>(null);
  const [orderedImages, setOrderedImages] = useState<ImageDTO[]>([]);
  const [image, setImage] = useState<ImageDTO | null>(null);
  const [cells, setCells] = useState<CellDTO[]>([]);
  const [loading, setLoading] = useState(true);
  const [run, setRun] = useState<RunState>({ kind: "idle" });
  const exportBusy = useRef(false);
  // Explicit picker selection (Batch sheet). null ⇒ follow the store's current
  // index. A pinned `imageId` prop (Results) makes the picker irrelevant.
  const [pickedImageId, setPickedImageId] = useState<string | null>(null);

  // Resolve the batch, its ordered images, and the target image + detection.
  // Mirrors useResultsData: batch → images in `batch.imageIds` order → the
  // target (pinned `imageId` prop → explicit picker → store's current index).
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    void (async () => {
      const port = getPort();
      try {
        const b = effectiveBatchId ? await port.batch(effectiveBatchId) : null;

        // Fetch the image table ONCE and index it — both the ordered-list build
        // and the pinned-image resolve reuse this map, instead of two full
        // allImages() round-trips (allImages is the priciest read on this path).
        const all = await port.allImages();
        const byId = new Map(all.map((im) => [im.id, im]));

        // Ordered batch images (used both to resolve the target and to populate
        // the picker), in `batch.imageIds` order to match useResultsData.
        let ordered: ImageDTO[] = [];
        if (b) {
          ordered = b.imageIds
            .map((id) => byId.get(id))
            .filter((im): im is ImageDTO => im !== undefined);
        }

        // Which image? A pinned prop wins; else an explicit picker selection;
        // else the batch's current index.
        let resolvedImage: ImageDTO | null = null;
        if (imageId) {
          resolvedImage = byId.get(imageId) ?? null;
        } else if (pickedImageId) {
          resolvedImage = ordered.find((im) => im.id === pickedImageId) ?? null;
        } else if (ordered.length > 0) {
          const idx = Math.min(Math.max(0, currentImageIdx), ordered.length - 1);
          resolvedImage = ordered[idx];
        }

        // Load the detection AND the image's ROIs together, then run the cells
        // through the SAME include/exclude ROI filter Results counts by
        // (useResultsData/AnalysisSidebar → applyRoiFilter). Without this the
        // Cells CSV / ImageJ RoiSet would include cells the user excluded via
        // ROI, disagreeing with the on-screen count. (The Rust writers still
        // apply the confidence cutoff; ROI filtering isn't theirs to know.)
        const [det, roiList] = resolvedImage
          ? await Promise.all([
              port.getDetection(resolvedImage.id),
              port.rois(resolvedImage.id),
            ])
          : [null, []];
        if (cancelled) return;
        setBatch(b);
        setOrderedImages(ordered);
        setImage(resolvedImage);
        setCells(applyRoiFilter(det?.cells ?? [], roiList));
      } catch {
        if (cancelled) return;
        setBatch(null);
        setOrderedImages([]);
        setImage(null);
        setCells([]);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [effectiveBatchId, imageId, currentImageIdx, pickedImageId]);

  const stem = image ? baseName(image.fileName) : "sample";
  const hasCells = cells.length > 0;

  // Resolve the scale + confidence cutoff the export must record so they match
  // what Results actually shows: the batch's own pxPerUm (batches can carry
  // EXIF-derived calibration distinct from the global) and the per-image
  // effectiveConfidence (the image's confidenceOverride wins over the slider),
  // falling back to the global store values.
  const pxPerUm = batch?.pxPerUm ?? globalPxPerUm;
  const confidence = image
    ? effectiveConfidence(useAppStore.getState(), image)
    : globalConfidence;

  const formats: FormatDef[] = useMemo(() => {
    const imgId = image?.id;
    return [
      {
        id: "sampleBundle", label: "Sample folder", icon: "folder",
        hint: "Source, reports, geometry, cells and ground truth from one saved snapshot.",
        enabled: !!imgId, defaultName: stem, destination: "directory",
        run: (outDir) => invoke<{ path: string; warnings: string[] }>("export_sample_bundle", { imageId: imgId, cellIds: cells.map(cell => cell.id), confidence, overlayMode, outDir }),
      },
      {
        id: "markdown", label: "Markdown report", icon: "info",
        hint: "Readable analysis summary with source and run provenance.",
        enabled: !!imgId, defaultName: `${stem}_report.md`,
        run: (outPath) => invoke<string>("export_markdown_report", { imageId: imgId, cellIds: cells.map(cell => cell.id), confidence, outPath }),
      },
      ...(["json", "csv"] as const).map((format): FormatDef => ({
        id: format === "json" ? "groundTruthJson" : "groundTruthCsv", label: `Ground truth ${format.toUpperCase()}`, icon: "scope",
        hint: "Annotation coordinates in preserved source pixels.",
        enabled: !!imgId, defaultName: `${stem}_annotations.${format}`,
        run: (outPath) => invoke<string>("export_ground_truth", { imageId: imgId, format, outPath }),
      })),
      {
        id: "annotatedPng",
        label: "Annotated PNG",
        hint: "Full-resolution image with the current contours or boxes.",
        icon: "image",
        enabled: !!imgId && hasCells,
        defaultName: `${stem}_annotated.png`,
        run: (outPath) =>
          invoke<string>("export_annotated_png", {
            imageId: imgId,
            cells,
            confidence,
            overlayMode,
            outPath,
          }),
      },
      {
        id: "batchAnnotated",
        label: "Annotated PNG folder",
        hint: "Export every analyzed batch image into a collision-safe folder.",
        icon: "folder",
        enabled: !!effectiveBatchId,
        defaultName: batch ? baseName(batch.displayName) : "batch",
        destination: "directory",
        run: (outDir) =>
          invoke<string>("export_batch_annotated_pngs", {
            batchId: effectiveBatchId,
            confidence: globalConfidence,
            overlayMode,
            outDir,
          }),
      },
      {
        id: "cellsCsv",
        label: "Cells CSV",
        hint: "Per-cell measurements (id, diameter, bin, flags, …).",
        icon: "grid",
        enabled: !!imgId && hasCells,
        defaultName: `${stem}_cells.csv`,
        run: (outPath) =>
          invoke<string>("export_cells_csv", {
            imageId: imgId,
            cells,
            pxPerUm,
            confidence,
            outPath,
          }),
      },
      {
        id: "summaryCsv",
        label: "Summary CSV",
        hint: "One row per image for the whole batch.",
        icon: "histogram",
        enabled: !!effectiveBatchId,
        defaultName: `${batch ? baseName(batch.displayName) : "batch"}_summary.csv`,
        run: (outPath) =>
          invoke<string>("export_batch_summary_csv", {
            batchId: effectiveBatchId,
            outPath,
          }),
      },
      {
        id: "imagejRoi",
        label: "ImageJ RoiSet",
        hint: "RoiSet.zip — polygon per cell (oval fallback).",
        icon: "scope",
        enabled: !!imgId && hasCells && !!image,
        defaultName: `${stem}_RoiSet.zip`,
        run: (outPath) =>
          invoke<string>("export_imagej_roi", {
            imageId: imgId,
            cells,
            imageWidth: image?.widthPx ?? 0,
            imageHeight: image?.heightPx ?? 0,
            outPath,
          }),
      },
      {
        id: "geojson",
        label: "GeoJSON contours",
        hint: "Source-pixel polygons for QuPath, Shapely, and GeoPandas.",
        icon: "scope",
        enabled: !!imgId && hasCells && !!image,
        defaultName: `${stem}_cells.geojson`,
        run: (outPath) =>
          invoke<string>("export_geojson", {
            imageId: imgId,
            cells,
            imageWidth: image?.widthPx ?? 0,
            imageHeight: image?.heightPx ?? 0,
            pxPerUm,
            confidence,
            outPath,
          }),
      },
      {
        id: "provenance",
        label: "Provenance JSON",
        hint: "How this result was produced (model, calibration, params).",
        icon: "info",
        enabled: !!imgId,
        defaultName: `${stem}_provenance.json`,
        run: (outPath) =>
          invoke<string>("export_provenance", {
            imageId: imgId,
            confidence,
            outPath,
          }),
      },
      {
        id: "pdf",
        label: "PDF report",
        hint: "One-page lab-journal report (image, histogram, QC, F1).",
        icon: "image",
        enabled: !!imgId,
        defaultName: `${stem}_report.pdf`,
        run: (outPath) =>
          invoke<string>("export_pdf_report", {
            imageId: imgId,
            confidence,
            outPath,
          }),
      },
    ];
  }, [
    image,
    batch,
    cells,
    hasCells,
    pxPerUm,
    confidence,
    stem,
    effectiveBatchId,
    globalConfidence,
    overlayMode,
  ]);

  const runFormat = async (fmt: FormatDef) => {
    if (!fmt.enabled || loading || exportBusy.current) return;
    exportBusy.current = true;
    setRun({ kind: "running", format: fmt.id });
    try {
      const outPath = await chooseOutPath(fmt.defaultName, fmt.destination ?? "file");
      const result = await fmt.run(outPath);
      setRun(typeof result === "string" ? { kind: "done", format: fmt.id, path: result } : { kind: "done", format: fmt.id, ...result });
    } catch (err) {
      if (err === EXPORT_CANCELLED) setRun({ kind: "idle" });
      else setRun({ kind: "error", format: fmt.id, message: typeof err === "string" ? err : err instanceof Error ? err.message : String(err) });
    } finally { exportBusy.current = false; }
  };

  const reveal = async (path: string) => {
    try {
      await revealItemInDir(path);
    } catch {
      /* best-effort; opener may be unsupported on some platforms */
    }
  };

  return (
    <section className="cc-export" aria-label="Export">
      <style>{EXPORT_PANEL_CSS}</style>
      <header className="cc-export__head">
        <div className="cc-export__title">Export</div>
        <div className="cc-export__subtitle">
          {loading
            ? "Loading current result…"
            : image
              ? `${image.fileName}${hasCells ? ` · ${cells.length} cells` : " · no detection"}`
              : effectiveBatchId
                ? "Batch summary available"
                : "No image or batch selected"}
        </div>
        {/* Explicit image picker for the per-image formats (Batch sheet). Makes
            the target of Cells CSV / ROIs / Provenance / PDF unambiguous instead
            of silently following a stale current index. */}
        {showImagePicker && orderedImages.length > 0 && (
          <label className="cc-export__picker">
            <span className="cc-export__picker-label">Per-image target</span>
            <select
              className="cc-export__picker-select"
              value={image?.id ?? ""}
              onChange={(e) => setPickedImageId(e.target.value)}
            >
              {orderedImages.map((im, i) => (
                <option key={im.id} value={im.id}>
                  {i + 1}. {im.fileName}
                </option>
              ))}
            </select>
          </label>
        )}
      </header>

      <ul className="cc-export__list">
        {formats.map((fmt) => {
          const isRunning = run.kind === "running" && run.format === fmt.id;
          // Narrow the run state to this row so `path` / `message` are typed.
          const donePath =
            run.kind === "done" && run.format === fmt.id ? run.path : null;
          const errorMsg =
            run.kind === "error" && run.format === fmt.id ? run.message : null;
          return (
            <li key={fmt.id} className="cc-export__row">
              <button
                type="button"
                className="cc-export__btn"
                disabled={!fmt.enabled || loading || run.kind === "running"}
                onClick={() => void runFormat(fmt)}
                title={fmt.hint}
              >
                <span className="cc-export__glyph" aria-hidden="true">
                  <Icon name={fmt.icon} size={18} />
                </span>
                <span className="cc-export__text">
                  <span className="cc-export__label">{fmt.label}</span>
                  <span className="cc-export__hint">{fmt.hint}</span>
                </span>
                <span
                  className={
                    "cc-export__status" +
                    (donePath ? " cc-export__status--done" : "")
                  }
                >
                  {isRunning ? (
                    "Exporting…"
                  ) : donePath ? (
                    <>
                      <Icon name="check" size={14} />
                      Saved
                    </>
                  ) : (
                    ""
                  )}
                </span>
              </button>
              {donePath ? (
                <div className="cc-export__result">
                  <code className="cc-export__path" title={donePath}>
                    {donePath}
                  </code>
                  <button
                    type="button"
                    className="cc-export__reveal"
                    onClick={() => void reveal(donePath)}
                  >
                    <Icon name="folder" size={14} />
                    Reveal in folder
                  </button>
                </div>
              ) : null}
              {run.kind === "done" && run.format === fmt.id && run.warnings?.length ? <div className="cc-export__error" role="status">{run.warnings.join(" ")}</div> : null}
              {errorMsg ? (
                <div className="cc-export__error" role="alert">
                  <Icon name="alert" size={14} />
                  <span>{errorMsg}</span>
                </div>
              ) : null}
            </li>
          );
        })}
      </ul>
    </section>
  );
}

/**
 * Scoped styles for the panel. Kept inline (as a `<style>` child) because this
 * feature owns exactly one file; the classnames are `cc-export`-prefixed so they
 * don't collide with any page. Everything reads the shared design tokens from
 * `styles/theme.css`.
 */
const EXPORT_PANEL_CSS = `
.cc-export {
  display: flex;
  flex-direction: column;
  gap: var(--cc-space-4);
  padding: var(--cc-space-4);
  min-width: 340px;
  max-width: 520px;
  color: var(--cc-text);
}
.cc-export__head {
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.cc-export__title {
  font-family: var(--cc-font-display);
  font-size: var(--cc-text-lg);
  font-weight: 650;
  letter-spacing: -0.01em;
  color: var(--cc-text);
}
.cc-export__subtitle {
  font-size: var(--cc-text-sm);
  color: var(--cc-text-secondary);
}
.cc-export__picker {
  display: flex;
  flex-direction: column;
  gap: 4px;
  margin-top: var(--cc-space-2);
}
.cc-export__picker-label {
  font-size: var(--cc-text-xs);
  font-weight: 550;
  color: var(--cc-text-tertiary);
}
.cc-export__picker-select {
  font-size: var(--cc-text-sm);
  padding: 6px 8px;
  border: 1px solid var(--cc-border-strong);
  border-radius: var(--cc-radius-sm);
  background: var(--cc-bg-elevated);
  color: var(--cc-text);
  max-width: 100%;
}
.cc-export__picker-select:focus-visible {
  outline: none;
  box-shadow: 0 0 0 2px var(--cc-focus-ring);
  border-color: var(--cc-border-focus);
}
.cc-export__list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: var(--cc-space-2);
}
.cc-export__row {
  display: flex;
  flex-direction: column;
  border: 1px solid var(--cc-border);
  border-radius: var(--cc-radius-lg);
  background: var(--cc-bg-elevated);
  overflow: hidden;
  transition: border-color 0.12s ease, box-shadow 0.12s ease;
}
.cc-export__row:hover {
  border-color: var(--cc-border-focus);
  box-shadow: var(--cc-shadow-1);
}
.cc-export__btn {
  display: flex;
  align-items: center;
  gap: var(--cc-space-3);
  width: 100%;
  background: transparent;
  border: 0;
  padding: var(--cc-space-3);
  cursor: pointer;
  text-align: left;
  color: inherit;
}
.cc-export__btn:focus-visible {
  outline: none;
  box-shadow: inset 0 0 0 2px var(--cc-focus-ring);
}
.cc-export__row:has(.cc-export__btn:disabled) {
  box-shadow: none;
}
.cc-export__row:has(.cc-export__btn:disabled):hover {
  border-color: var(--cc-border);
}
.cc-export__btn:disabled {
  opacity: 0.45;
  cursor: default;
}
.cc-export__glyph {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 34px;
  height: 34px;
  border-radius: var(--cc-radius-md);
  background: var(--cc-bg-subtle);
  border: 1px solid var(--cc-border);
  color: var(--cc-text-secondary);
}
.cc-export__text {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 1px;
}
.cc-export__label {
  font-size: var(--cc-text-md);
  font-weight: 600;
  color: var(--cc-text);
}
.cc-export__hint {
  font-size: var(--cc-text-xs);
  color: var(--cc-text-tertiary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.cc-export__status {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: var(--cc-text-xs);
  font-weight: 550;
  color: var(--cc-text-tertiary);
}
.cc-export__status--done {
  color: var(--cc-success);
}
.cc-export__result {
  display: flex;
  align-items: center;
  gap: var(--cc-space-2);
  padding: var(--cc-space-2) var(--cc-space-3) var(--cc-space-3);
  border-top: 1px solid var(--cc-border);
  background: var(--cc-bg-subtle);
}
.cc-export__path {
  flex: 1 1 auto;
  min-width: 0;
  font-family: var(--cc-font-mono);
  font-size: var(--cc-text-xs);
  color: var(--cc-text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.cc-export__reveal {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-size: var(--cc-text-xs);
  font-weight: 550;
  padding: 4px 9px;
  border: 1px solid var(--cc-border-strong);
  border-radius: var(--cc-radius-sm);
  background: var(--cc-bg-elevated);
  color: var(--cc-text);
  cursor: pointer;
  transition: background 0.12s ease, border-color 0.12s ease;
}
.cc-export__reveal:hover {
  background: var(--cc-bg-hover);
  border-color: var(--cc-border-focus);
}
.cc-export__error {
  display: flex;
  align-items: flex-start;
  gap: var(--cc-space-2);
  padding: var(--cc-space-2) var(--cc-space-3) var(--cc-space-3);
  border-top: 1px solid var(--cc-border);
  font-size: var(--cc-text-xs);
  color: var(--cc-danger);
  word-break: break-word;
}
.cc-export__error .cc-icon {
  flex: 0 0 auto;
  margin-top: 1px;
}
`;

export default ExportPanel;
