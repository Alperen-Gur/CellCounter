/** Results uses one source-coordinate selection for overlays, measurements and plots. */

import { Suspense, lazy, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";

import { Viewport } from "../../kernel/viewport/Viewport";
import { MaskOverlay } from "../../kernel/overlay/MaskOverlay";
import { useAppStore } from "../../kernel/store/store";
import { Icon } from "../../components/Icon";
import { ExportPanel } from "../../components/ExportPanel";
import { navigate as shellNavigate } from "../../components/useHashRoute";
import { useKeymap } from "../../components/useKeymap";
import { rerunDetection, isImporting } from "../home/importFlow";

import { useResultsData } from "./useResultsData";
import { applyRoiFilter } from "./roiFilter";
import { AnalysisSidebar } from "./AnalysisSidebar";
import { OverlayControls } from "./OverlayControls";
import { QCBadges } from "./QCBadges";
import { LinkedMeasurements } from "./LinkedMeasurements";
import { MaskVersionsPanel } from "./MaskVersionsPanel";
import { RunProvenance } from "./RunProvenance";
import { useSavedRun } from "./useSavedRun";
import { assertReviewImageWritable, isReviewImageBusy, useReviewImageBusy } from "./reviewWriteGuard";

// Mask-editing (feat-mask-editing): one shared editor drives the toolbar, the
// live overlay cells, and the in-Viewport gesture surface.
import { useMaskEditor } from "./editing/useMaskEditor";
import { useEditingKeymap } from "./editing/useEditingKeymap";
import { EditingToolbar } from "./editing/EditingToolbar";
import { EditingSurface } from "./editing/EditingSurface";

import "./results.css";

// Load the desktop mask file picker only when Results is open.
const SegNpyPanel = lazy(() => import("./segnpy/SegNpyPanel"));

export default function ResultsPage() {
  const data = useResultsData();
  const {
    batch,
    images,
    imageIdx,
    currentImage,
    detection,
    annotations,
    cells,
    allCells,
    confidenceCutoff,
    thresholds,
    loading,
    error: loadError,
    reloadImageData,
    reloadRois,
    reloadAnnotations,
    rois,
  } = data;

  // ---- store: session view state (zoom/pan/overlay/selection/nav) ----
  const zoom = useAppStore((s) => s.zoom);
  const pan = useAppStore((s) => s.pan);
  const setZoom = useAppStore((s) => s.setZoom);
  const setPan = useAppStore((s) => s.setPan);
  const overlayMode = useAppStore((s) => s.overlayMode);
  const showMaskFills = useAppStore((s) => s.showMaskFills);
  const setShowMaskFills = useAppStore((s) => s.setShowMaskFills);
  const showOutlines = useAppStore((s) => s.showOutlines);
  const setShowOutlines = useAppStore((s) => s.setShowOutlines);
  const maskOpacity = useAppStore((s) => s.maskOpacity);
  const selectedCellIds = useAppStore((s) => s.selectedCellIds);
  const editorMode = useAppStore((s) => s.editorMode);
  const setCurrentImageIdx = useAppStore((s) => s.setCurrentImageIdx);
  const pxPerUm = useAppStore((s) => s.pxPerUm);
  const setSelectedCellIds = useAppStore((s) => s.setSelectedCellIds);
  const currentBatchId = useAppStore((s) => s.currentBatchId);

  // Export sheet (per-image export of the open image) + re-run detection.
  const [exportOpen, setExportOpen] = useState(false);

  const [panel, setPanel] = useState<"measurements" | "variants" | null>(null);
  const [operationBusy, setOperationBusy] = useState(false);
  const imageBusy = useReviewImageBusy(currentImage?.id);
  const savedRun = useSavedRun(currentImage?.id, detection);
  const readOnly = imageBusy || operationBusy || exportOpen;

  // ---- shared mask-editing engine (feat-mask-editing) ----
  // One editor instance for the current image drives the toolbar, the live
  // overlay cells, and the gesture surface; its commits persist + record
  // corrections. Until it loads we render the read-only detection cells.
  const editor = useMaskEditor({
    imageId: currentImage?.id,
    readOnly,
    sourceWidth: currentImage?.widthPx,
    sourceHeight: currentImage?.heightPx,
  });
  useEditingKeymap({ editor, enabled: !!currentImage && !readOnly && !editor.loading && !loading });
  // OVERLAY cells: the full live list (engine cells while editing, else the
  // detection cells). The overlay must render hidden/low-confidence cells too
  // (dashed), so it is intentionally UNfiltered.
  const displayCells = editor.engine ? editor.cells : allCells;
  const displayAnnotations = editor.engine ? editor.annotations : annotations;
  const reportError = (error: unknown) => useAppStore.getState().setDetectionError(error instanceof Error ? error.message : String(error));
  const openExport = async () => {
    if (!currentImage || readOnly || editor.loading) return;
    setOperationBusy(true);
    try { await editor.flush(); assertReviewImageWritable(currentImage.id); setExportOpen(true); }
    catch (error) { reportError(error); }
    finally { setOperationBusy(false); }
  };
  const onRerun = async () => {
    if (!currentImage || !batch || isImporting() || readOnly) return;
    setOperationBusy(true);
    try {
      assertReviewImageWritable(currentImage.id);
      await editor.flush();
      assertReviewImageWritable(currentImage.id);
      await rerunDetection(currentImage, batch, { navigate: id => shellNavigate(id), onDuplicates: async () => null }, { getState: () => useAppStore.getState() });
    } catch (error) { reportError(error); }
    finally { setOperationBusy(false); }
  };
  const goToImage = async (index: number) => {
    if (operationBusy || exportOpen || index < 0 || index >= images.length) return;
    setOperationBusy(true);
    try { await editor.flush(); setCurrentImageIdx(index); }
    catch (error) { reportError(error); }
    finally { setOperationBusy(false); }
  };
  const onRestored = async () => {
    editor.reload();
    await reloadImageData();
  };

  // SIDEBAR cells: when the editor is live it owns the cell list, but the
  // sidebar must still count only the confidence-passing, ROI-included cells —
  // exactly what `useResultsData.cells` does for the non-editing path. Run the
  // live cells through the SAME confidence cutoff + ROI filter so every
  // count-driven panel (count, size bins, histograms, F1) honours the slider
  // and the ROI include/exclude panel. When no engine is loaded, `cells` from
  // useResultsData is already filtered, so pass it through unchanged.
  const sidebarCells = useMemo(() => {
    if (!editor.engine) return cells;
    const confFiltered = editor.cells.filter(
      (c) => c.confidence >= confidenceCutoff,
    );
    return applyRoiFilter(confFiltered, rois);
  }, [editor.engine, editor.cells, cells, confidenceCutoff, rois]);

  // Resolve the on-disk image path to a webview-loadable URL. Recomputed only
  // when the stored path changes.
  const imageSrc = useMemo(
    () => (currentImage ? convertFileSrc(currentImage.storedPath) : null),
    [currentImage],
  );

  // Reset pan when the image changes (zoom is intentionally sticky, matching a
  // "keep my magnification while flipping through a batch" workflow).
  const lastImageId = useRef<string | null>(null);
  useEffect(() => {
    const id = currentImage?.id ?? null;
    if (id !== lastImageId.current) {
      lastImageId.current = id;
      setPan({ x: 0, y: 0 });
      setSelectedCellIds(new Set());
      setExportOpen(false);
    }
  }, [currentImage, setPan, setSelectedCellIds]);

  // ---- fit-to-view (⌘0 handled inside Viewport; button + reset here) ----
  const onFit = useCallback(() => {
    setZoom(1);
    setPan({ x: 0, y: 0 });
  }, [setZoom, setPan]);

  // ---- keyboard: overlay toggles (Space/X/Z) + directory nav (←/→) ----
  // Drive these through the shared keymap (the frozen `overlay` + `navigation`
  // scopes) rather than a hand-rolled window keydown switch, so the chords stay
  // the single source of truth: rebinding e.g. "toggle outlines" in keymap.ts
  // updates both this page and the KeyboardShortcutsSheet together. useKeymap
  // already ignores events from text fields and calls preventDefault.
  useKeymap("overlay", {
    toggleOverlay: () => {
      const next = !(showMaskFills || showOutlines);
      setShowMaskFills(next);
      setShowOutlines(next);
    },
    toggleMaskFills: () => setShowMaskFills(!showMaskFills),
    toggleOutlines: () => setShowOutlines(!showOutlines),
    cycleOverlayMode: () => useAppStore.getState().setOverlayMode(overlayMode === "outline" ? "bbox" : "outline"),
  });
  useKeymap(
    "navigation",
    {
      nextImage: () => void goToImage(imageIdx + 1),
      prevImage: () => void goToImage(imageIdx - 1),
    },
    { enabled: images.length > 0 && !operationBusy && !exportOpen },
  );

  useKeymap("results", {
    selectAll: () => setSelectedCellIds(new Set(sidebarCells.map(cell => cell.id))),
    clearSelection: () => setSelectedCellIds(new Set()),
    export: () => void openExport(),
    measurements: () => setPanel(value => value === "measurements" ? null : "measurements"),
    variants: () => setPanel(value => value === "variants" ? null : "variants"),
  }, { enabled: !!currentImage && !operationBusy && !exportOpen });

  // ---- empty / loading states ----
  if (!batch && !loading) {
    return (
      <div className="rv-empty">
        <div className="rv-empty__glyph" aria-hidden="true">
          <Icon name="scope" size={40} />
        </div>
        <div className="rv-empty__title">No analysis open</div>
        <p className="rv-empty__msg">
          Drop a microscope image on the Home screen to start a new analysis.
        </p>
      </div>
    );
  }

  if (batch && images.length === 0 && !loading) {
    return (
      <div className="rv-empty">
        <div className="rv-empty__glyph" aria-hidden="true">
          <Icon name="batches" size={40} />
        </div>
        <div className="rv-empty__title">Batch has no images yet</div>
        <p className="rv-empty__msg">
          Drop new microscope images on Home to add to this batch.
        </p>
      </div>
    );
  }

  return (
    <div className="rv-root">
      <div className="rv-viewer-col">
        {/* Editing toolbar mount — owned by feat-mask-editing. Given the live
            cell list + edit context so the gestures can drive the engine and
            persist corrections; this task only provides the mount + props. */}
        <div className="rv-toolbar-mount">
          {currentImage && <fieldset className="rv-edit-lock" disabled={readOnly || editor.loading || loading || !editor.engine}><EditingToolbar editor={editor} /></fieldset>}
          <Suspense fallback={null}>
            <SegNpyPanel image={currentImage} batch={batch} disabled={readOnly || editor.loading || loading} beforeWrite={editor.flush} onBusyChange={setOperationBusy} />
          </Suspense>
          {currentImage && (
            <button
              type="button"
              className="rv-export-btn"
              onClick={() => void openExport()}
              disabled={readOnly || editor.loading || loading}
              title="Export this image (CSV, ImageJ ROIs, provenance, PDF)"
            >
              <Icon name="download" size={16} />
              <span>Export</span>
            </button>
          )}
          {currentImage && <>
            <button className="rv-export-btn" disabled={operationBusy || exportOpen} onClick={() => setPanel(value => value === "measurements" ? null : "measurements")} aria-pressed={panel === "measurements"}>Measurements</button>
            <button className="rv-export-btn" disabled={operationBusy || exportOpen} onClick={() => setPanel(value => value === "variants" ? null : "variants")} aria-pressed={panel === "variants"}>Mask versions</button>
            <button className="rv-export-btn" disabled={readOnly || editor.loading || loading} onClick={() => void onRerun()}>Analyze again</button>
          </>}
        </div>
        {currentImage && <RunProvenance detection={detection} run={savedRun.run} loading={savedRun.loading} error={savedRun.error} reviewPxPerUm={pxPerUm} confidence={confidenceCutoff} />}
        {imageBusy && <div className="rv-review-notice" role="status">This image is in the active processing job. Open a completed image below to review its result.
          <button onClick={() => { const index = images.findIndex(image => image.id !== currentImage?.id && image.cellCount > 0 && !isReviewImageBusy(image.id)); if (index >= 0) void goToImage(index); }} disabled={!images.some(image => image.id !== currentImage?.id && image.cellCount > 0 && !isReviewImageBusy(image.id))}>View a completed image</button>
        </div>}
        {editor.saving && <p className="rv-review-notice" role="status">Saving mask edits…</p>}
        {(editor.loadError || loadError) && <p className="rv-review-error" role="alert">This result could not be loaded: {editor.loadError || loadError} <button onClick={() => { editor.reload(); void reloadImageData().catch(reportError); }}>Try again</button></p>}
        {editor.saveError && <p className="rv-review-error" role="alert">Mask edits have not saved: {editor.saveError} Keep this image open; the next edit retries its unsaved corrections.</p>}
        <div className="rv-canvas">
          {imageSrc && currentImage ? (
            <Viewport
              imageSrc={imageSrc}
              sourceWidth={currentImage.widthPx}
              sourceHeight={currentImage.heightPx}
              zoom={zoom}
              pan={pan}
              onZoomChange={setZoom}
              onPanChange={setPan}
              onFit={onFit}
            >
              {(showMaskFills || showOutlines) && (
                <MaskOverlay
                  cells={displayCells}
                  annotations={displayAnnotations}
                  thresholds={thresholds}
                  overlayMode={overlayMode}
                  confidenceCutoff={confidenceCutoff}
                  showMaskFills={showMaskFills}
                  showOutlines={showOutlines}
                  maskOpacity={maskOpacity}
                  selectedCellIds={selectedCellIds}
                />
              )}
              {/* Gesture layer — shares the editor with the toolbar; must live
                  INSIDE Viewport to read the source-px transform via context. */}
              {!readOnly && !editor.loading && !loading && <EditingSurface editor={editor} />}
            </Viewport>
          ) : (
            <div className="rv-canvas__placeholder">Loading image…</div>
          )}

          <OverlayControls onFit={onFit} />

          <div className="rv-qc-mount">
            <QCBadges stats={detection?.imageStats} />
          </div>

          {currentImage && detection == null && !loading && !loadError && (
            <div className="rv-detbanner">
              <span className="rv-detbanner__icon" aria-hidden="true">
                <Icon name="alert" size={18} />
              </span>
              <div className="rv-detbanner__text">
                <strong>No detection for this image</strong>
                <span>
                  Detection hasn't run (or produced no result). Re-run it below
                  by opening analysis setup, previewing, and processing it.
                </span>
              </div>
              {batch && (
                <button
                  type="button"
                  className="rv-detbanner__action"
                  onClick={() => void onRerun()}
                  disabled={readOnly || editor.loading}
                  title="Re-run detection on this image"
                >
                  <Icon name="refresh" size={16} />
                  <span>Re-run detection</span>
                </button>
              )}
            </div>
          )}
        </div>

        {currentImage && panel && <div className="rv-review-dock">
          {panel === "measurements" ? <LinkedMeasurements key={currentImage.id} cells={sidebarCells} /> : imageSrc && <MaskVersionsPanel key={currentImage.id} image={currentImage} imageSrc={imageSrc} detection={detection} cells={displayCells} run={savedRun.run} reviewPxPerUm={pxPerUm} thresholds={thresholds} disabled={readOnly || loading || editor.loading || !editor.engine || !!loadError || savedRun.loading} flush={editor.flush} onRestored={onRestored} onBusyChange={setOperationBusy} />}
        </div>}
        {/* Directory nav strip — ←/→ through the batch's images. */}
        {images.length > 0 && (
          <nav className="rv-nav" aria-label="Batch images">
            <button
              type="button"
              className="rv-nav__arrow"
              disabled={imageIdx <= 0 || operationBusy || exportOpen}
              onClick={() => void goToImage(imageIdx - 1)}
              title="Previous image (←)"
              aria-label="Previous image"
            >
              <Icon name="chevronLeft" size={18} />
            </button>
            <div className="rv-nav__strip">
              {images.map((im, i) => (
                <button
                  type="button"
                  key={im.id}
                  className={`rv-nav__thumb${i === imageIdx ? " rv-nav__thumb--on" : ""}`}
                  onClick={() => void goToImage(i)}
                  disabled={operationBusy || exportOpen}
                  title={im.fileName}
                >
                  <img src={convertFileSrc(im.thumbPath)} alt="" draggable={false} />
                  <span className="rv-nav__idx">{i + 1}</span>
                </button>
              ))}
            </div>
            <button
              type="button"
              className="rv-nav__arrow"
              disabled={imageIdx >= images.length - 1 || operationBusy || exportOpen}
              onClick={() => void goToImage(imageIdx + 1)}
              title="Next image (→)"
              aria-label="Next image"
            >
              <Icon name="chevronRight" size={18} />
            </button>
            <span className="rv-nav__counter">
              {imageIdx + 1} / {images.length}
              {currentImage ? ` · ${currentImage.fileName}` : ""}
              {` · ${editorMode}`}
            </span>
          </nav>
        )}
      </div>

      <AnalysisSidebar
        batch={batch}
        image={currentImage}
        imageSrc={imageSrc}
        cells={sidebarCells}
        annotations={displayAnnotations}
        rois={rois}
        imageStats={detection?.imageStats}
        thresholds={thresholds}
        confidenceCutoff={confidenceCutoff}
        reloadImageData={reloadImageData}
        reloadRois={reloadRois}
        reloadAnnotations={reloadAnnotations}
      />

      {/* Per-image export sheet — mounts feat-export's ExportPanel pinned to the
          open image so its Cells CSV / ImageJ ROIs / Provenance / PDF are
          reachable from the only per-image analysis view. */}
      {exportOpen && currentImage && (
        <div
          className="rv-export-overlay"
          role="dialog"
          aria-modal="true"
          aria-label="Export"
          onClick={(e) => {
            if (e.target === e.currentTarget) setExportOpen(false);
          }}
        >
          <div className="rv-export-sheet">
            <div className="rv-export-sheet__head">
              <span className="rv-export-sheet__title">Export image</span>
              <button
                type="button"
                className="rv-export-sheet__close"
                onClick={() => setExportOpen(false)}
                title="Close"
                aria-label="Close"
              >
                <Icon name="close" size={18} />
              </button>
            </div>
            <ExportPanel imageId={currentImage.id} batchId={currentBatchId ?? undefined} />
          </div>
        </div>
      )}
    </div>
  );
}
