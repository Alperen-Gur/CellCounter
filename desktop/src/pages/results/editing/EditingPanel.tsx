/**
 * pages/results/editing/EditingPanel.tsx — the mask-editing feature entry point
 * (feature task `feat-mask-editing`).
 *
 * WHAT THIS MOUNTS AS. `feat-results-viewer` composes the Results screen and
 * mounts this component in its `.rv-toolbar-mount` strip (above its own
 * `<Viewport>`), with no props — i.e. it treats `<EditingPanel/>` as the editing
 * TOOLBAR. So this component renders the toolbar (mode switches V/A/R/M/S/C/G +
 * undo/redo + the manual-marker-diameter stepper) and owns the live editing
 * engine for the current image, wiring:
 *   - `store.editorMode` (the FROZEN SessionSlice key the whole Results screen
 *     already reads — the nav strip even shows it),
 *   - one `MaskEditEngine` per image (via `useMaskEditor`) whose every commit
 *     persists the detection + appends a `corrections` row, and
 *   - the editor keyboard scheme (⌘Z / ⌘⇧Z, Delete, Escape, mode letters).
 *
 * WHERE THE GESTURES GO. The pointer-capture layer is `<EditingSurface>` — it
 * must render INSIDE a `<Viewport>` to consume `ViewportTransformContext` and
 * overlay the image. Because this panel is mounted OUTSIDE the results Viewport
 * (React context follows the tree, so a portal can't bridge it), the surface is
 * exported for the results page to drop into ITS Viewport, sharing the SAME
 * `useMaskEditor` instance. See INTEGRATION below and the module exports.
 *
 *   ── INTEGRATION (one line in feat-results-viewer's ResultsPage) ────────────
 *   const editor = useMaskEditor({ imageId: currentImage?.id });   // shared
 *   <EditingToolbar editor={editor} />                             // in toolbar
 *   <Viewport …>
 *     <MaskOverlay cells={editor.cells} … />       // drive overlay from engine
 *     <EditingSurface editor={editor} />           // ← the gesture layer
 *   </Viewport>
 *   ───────────────────────────────────────────────────────────────────────────
 *
 * A fully self-contained editor (its own Viewport + overlay + surface) is also
 * exported as `StandaloneEditor` for tests / the future browser build. No kernel
 * logic is re-implemented here; everything routes through the engine + ports.
 *
 * Coordinate space: everything the engine sees is SOURCE-PIXEL; a Viewport
 * transform (context) maps to view-px.
 */

import { useEffect, useMemo, useState } from "react";

import type { CellDTO, ImageDTO } from "../../../kernel/types";
import { Viewport } from "../../../kernel/viewport/Viewport";
import { MaskOverlay } from "../../../kernel/overlay/MaskOverlay";
import { getPort } from "../../../kernel/persistence";
import {
  useAppStore,
  effectiveConfidence,
} from "../../../kernel/store/store";

import { useMaskEditor } from "./useMaskEditor";
import { EditingSurface } from "./EditingSurface";
import { EditingToolbar } from "./EditingToolbar";
import { useEditingKeymap } from "./useEditingKeymap";
import "./editing.css";

// Re-exports so feat-results-viewer can compose the pieces into its Viewport.
export { EditingSurface } from "./EditingSurface";
export { EditingToolbar } from "./EditingToolbar";
export { useMaskEditor } from "./useMaskEditor";
export type { MaskEditorApi } from "./useMaskEditor";
export { useEditingKeymap } from "./useEditingKeymap";

// ---------------------------------------------------------------------------
// Current-image resolution (store batch/idx → ImageDTO id)
// ---------------------------------------------------------------------------

/**
 * Resolve the current image id from the store's `currentBatchId` +
 * `currentImageIdx` through the port. Purely read-only; returns the ImageDTO (or
 * null) so callers can bind an editor to it and derive a displayable src.
 */
export function useCurrentImage(): { image: ImageDTO | null; loading: boolean } {
  const currentBatchId = useAppStore((s) => s.currentBatchId);
  const currentImageIdx = useAppStore((s) => s.currentImageIdx);
  const [image, setImage] = useState<ImageDTO | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    let cancelled = false;
    if (!currentBatchId) {
      setImage(null);
      return;
    }
    const port = getPort();
    setLoading(true);
    void (async () => {
      try {
        const [batch, all] = await Promise.all([
          port.batch(currentBatchId),
          port.allImages(),
        ]);
        if (cancelled) return;
        const imageId = batch?.imageIds[currentImageIdx];
        setImage(imageId ? all.find((i) => i.id === imageId) ?? null : null);
      } catch (err) {
        if (!cancelled) {
          console.warn("[EditingPanel] resolve image failed:", err);
          setImage(null);
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [currentBatchId, currentImageIdx]);

  return { image, loading };
}

/** Map a stored file path to a webview-loadable URL (Tauri asset protocol). */
export async function toDisplaySrc(storedPath: string): Promise<string> {
  if (!storedPath) return "";
  if (/^(blob:|https?:|data:)/.test(storedPath)) return storedPath;
  try {
    const { convertFileSrc } = await import("@tauri-apps/api/core");
    return convertFileSrc(storedPath);
  } catch {
    return storedPath;
  }
}

// ---------------------------------------------------------------------------
// EditingPanel — the toolbar (what feat-results-viewer mounts)
// ---------------------------------------------------------------------------

export default function EditingPanel() {
  const { image } = useCurrentImage();

  // One live engine for the current image. Its commits persist + record
  // corrections (see useMaskEditor); undo/redo drive off it.
  const editor = useMaskEditor({
    imageId: image?.id,
    sourceWidth: image?.widthPx,
    sourceHeight: image?.heightPx,
  });

  // Editor keyboard scheme (⌘Z/⌘⇧Z/Delete/Escape/mode letters) — active only
  // when there's an image to edit.
  useEditingKeymap({ editor, enabled: !!image });

  // Render nothing (collapses the :empty toolbar mount) when there's no image.
  if (!image) return null;

  return <EditingToolbar editor={editor} />;
}

// ---------------------------------------------------------------------------
// StandaloneEditor — full self-contained editor (own Viewport + surface)
// ---------------------------------------------------------------------------

/**
 * A complete, self-contained mask editor: toolbar + its own `<Viewport>` +
 * read-only `<MaskOverlay>` (fed the engine's LIVE cells, confidence-filtered
 * for display only) + the interactive `<EditingSurface>`. Used by tests and the
 * future browser build; the desktop Results screen instead composes the pieces
 * into its own Viewport (see the INTEGRATION note above).
 */
export function StandaloneEditor() {
  const { image, loading } = useCurrentImage();
  const [src, setSrc] = useState<string>("");

  const editor = useMaskEditor({
    imageId: image?.id,
    sourceWidth: image?.widthPx,
    sourceHeight: image?.heightPx,
  });
  useEditingKeymap({ editor, enabled: !!image });

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const s = image ? await toDisplaySrc(image.storedPath) : "";
      if (!cancelled) setSrc(s);
    })();
    return () => {
      cancelled = true;
    };
  }, [image]);

  const zoom = useAppStore((s) => s.zoom);
  const pan = useAppStore((s) => s.pan);
  const setZoom = useAppStore((s) => s.setZoom);
  const setPan = useAppStore((s) => s.setPan);
  const overlayMode = useAppStore((s) => s.overlayMode);
  const showMaskFills = useAppStore((s) => s.showMaskFills);
  const showOutlines = useAppStore((s) => s.showOutlines);
  const maskOpacity = useAppStore((s) => s.maskOpacity);
  const thresholds = useAppStore((s) => s.thresholds);
  const selectedCellIds = useAppStore((s) => s.selectedCellIds);
  const confidence = useAppStore((s) => s.confidence);

  const cutoff = useMemo(
    () => (image ? effectiveConfidence(useAppStore.getState(), image) : confidence),
    [image, confidence],
  );

  // Non-destructive display filter: hidden low-confidence cells stay in the
  // engine and round-trip on save; they are only omitted from the overlay.
  const visibleCells: CellDTO[] = useMemo(
    () => editor.cells.filter((c) => c.confidence >= cutoff),
    [editor.cells, cutoff],
  );

  const onFit = () => {
    setZoom(1);
    setPan({ x: 0, y: 0 });
  };

  if (!image) {
    return (
      <div className="cc-edit-empty">
        {loading ? "Loading image…" : "No image selected."}
      </div>
    );
  }

  return (
    <div className="cc-edit-root">
      <EditingToolbar editor={editor} />
      <div className="cc-edit-canvas">
        <Viewport
          imageSrc={src}
          sourceWidth={image.widthPx}
          sourceHeight={image.heightPx}
          zoom={zoom}
          pan={pan}
          onZoomChange={setZoom}
          onPanChange={setPan}
          onFit={onFit}
        >
          <MaskOverlay
            cells={visibleCells}
            annotations={editor.annotations}
            thresholds={thresholds}
            overlayMode={overlayMode}
            confidenceCutoff={cutoff}
            showMaskFills={showMaskFills}
            showOutlines={showOutlines}
            maskOpacity={maskOpacity}
            selectedCellIds={selectedCellIds}
          />
          <EditingSurface editor={editor} />
        </Viewport>
      </div>
    </div>
  );
}
