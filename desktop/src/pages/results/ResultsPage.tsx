/**
 * pages/results/ResultsPage.tsx — the Results screen (feat-results-viewer).
 *
 * Composes the core analysis screen from the frozen kernel:
 *   - `Viewport` (pan/zoom, source-px transform) + read-only `MaskOverlay`
 *     (contours/bbox/markers/annotations, opacity, uncertain-dashed)
 *   - the floating overlay/zoom controls (OverlayControls) + Space/X/Z + opacity
 *   - a directory nav strip (←/→ through the batch's images)
 *   - the right analysis sidebar (AnalysisSidebar): count, size bins, intensity +
 *     size histograms, QC badges, colonies, notes, ROI include/exclude, F1 vs
 *     ground truth — all via calibration/stats + PersistencePort
 *   - the editing toolbar mount (feat-mask-editing) and _seg.npy mount
 *     (feat-seg-npy-io) as entry points only — this task does NOT implement them.
 *
 * This task owns pages/results/ EXCLUDING pages/results/editing/ and
 * pages/results/segnpy/. Reads/writes go through the frozen store + ports; no
 * detection is dispatched here (Home/Processing own that).
 *
 * Coordinate space: all cell/annotation geometry stays SOURCE-PIXEL; the
 * Viewport supplies the view transform to MaskOverlay via context.
 */

import { Suspense, lazy, useCallback, useEffect, useMemo, useRef } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";

import { Viewport } from "../../kernel/viewport/Viewport";
import { MaskOverlay } from "../../kernel/overlay/MaskOverlay";
import { useAppStore } from "../../kernel/store/store";
import { Icon } from "../../components/Icon";

import { useResultsData } from "./useResultsData";
import { AnalysisSidebar } from "./AnalysisSidebar";
import { OverlayControls } from "./OverlayControls";
import { QCBadges } from "./QCBadges";

// Mask-editing (feat-mask-editing): one shared editor drives the toolbar, the
// live overlay cells, and the in-Viewport gesture surface.
import { useMaskEditor } from "./editing/useMaskEditor";
import { useEditingKeymap } from "./editing/useEditingKeymap";
import { EditingToolbar } from "./editing/EditingToolbar";
import { EditingSurface } from "./editing/EditingSurface";

import "./results.css";

// _seg.npy round-trip lives in a physically-disjoint directory owned by
// feat-seg-npy-io; lazy-mounted as an entry point only.
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
    confidenceCutoff,
    thresholds,
    loading,
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
  const nextImage = useAppStore((s) => s.nextImage);
  const prevImage = useAppStore((s) => s.prevImage);

  // ---- shared mask-editing engine (feat-mask-editing) ----
  // One editor instance for the current image drives the toolbar, the live
  // overlay cells, and the gesture surface; its commits persist + record
  // corrections. Until it loads we render the read-only detection cells.
  const editor = useMaskEditor({
    imageId: currentImage?.id,
    sourceWidth: currentImage?.widthPx,
    sourceHeight: currentImage?.heightPx,
  });
  useEditingKeymap({ editor, enabled: !!currentImage });
  const displayCells = editor.engine ? editor.cells : cells;

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
    }
  }, [currentImage, setPan]);

  // ---- fit-to-view (⌘0 handled inside Viewport; button + reset here) ----
  const onFit = useCallback(() => {
    setZoom(1);
    setPan({ x: 0, y: 0 });
  }, [setZoom, setPan]);

  // ---- keyboard: overlay toggles (Space/X/Z) + directory nav (←/→) ----
  // The shell binds only "?" / Escape; the Viewport binds ⌘0. These bindings
  // are disjoint from both. The full keymap (feat-directory-nav-keyboard) will
  // supersede these; until then the task's required toggles work here.
  useEffect(() => {
    const isTyping = (t: EventTarget | null): boolean => {
      const el = t as HTMLElement | null;
      return (
        !!el &&
        (el.tagName === "INPUT" ||
          el.tagName === "TEXTAREA" ||
          el.isContentEditable)
      );
    };
    const onKey = (e: KeyboardEvent) => {
      if (isTyping(e.target)) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return; // leave modified chords alone
      switch (e.key) {
        case " ": {
          e.preventDefault();
          const next = !(showMaskFills || showOutlines);
          setShowMaskFills(next);
          setShowOutlines(next);
          break;
        }
        case "x":
        case "X":
          e.preventDefault();
          setShowMaskFills(!showMaskFills);
          break;
        case "z":
        case "Z":
          e.preventDefault();
          setShowOutlines(!showOutlines);
          break;
        case "ArrowRight":
          if (images.length > 0) {
            e.preventDefault();
            nextImage();
          }
          break;
        case "ArrowLeft":
          if (images.length > 0) {
            e.preventDefault();
            prevImage();
          }
          break;
        default:
          break;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [
    images.length,
    showMaskFills,
    showOutlines,
    setShowMaskFills,
    setShowOutlines,
    nextImage,
    prevImage,
  ]);

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
          {currentImage && <EditingToolbar editor={editor} />}
          <Suspense fallback={null}>
            <SegNpyPanel />
          </Suspense>
        </div>

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
                  annotations={annotations}
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
              <EditingSurface editor={editor} />
            </Viewport>
          ) : (
            <div className="rv-canvas__placeholder">Loading image…</div>
          )}

          <OverlayControls onFit={onFit} />

          <div className="rv-qc-mount">
            <QCBadges stats={detection?.imageStats} />
          </div>

          {currentImage && detection == null && !loading && (
            <div className="rv-detbanner">
              <span className="rv-detbanner__icon" aria-hidden="true">
                <Icon name="alert" size={18} />
              </span>
              <div className="rv-detbanner__text">
                <strong>No detection for this image</strong>
                <span>
                  Detection hasn't run (or produced no result). Re-run it from
                  Home or the Models page.
                </span>
              </div>
            </div>
          )}
        </div>

        {/* Directory nav strip — ←/→ through the batch's images. */}
        {images.length > 0 && (
          <nav className="rv-nav" aria-label="Batch images">
            <button
              type="button"
              className="rv-nav__arrow"
              disabled={imageIdx <= 0}
              onClick={() => prevImage()}
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
                  onClick={() => setCurrentImageIdx(i)}
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
              disabled={imageIdx >= images.length - 1}
              onClick={() => nextImage()}
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
        cells={cells}
        annotations={annotations}
        rois={rois}
        imageStats={detection?.imageStats}
        thresholds={thresholds}
        confidenceCutoff={confidenceCutoff}
        reloadImageData={reloadImageData}
        reloadRois={reloadRois}
        reloadAnnotations={reloadAnnotations}
      />
    </div>
  );
}
