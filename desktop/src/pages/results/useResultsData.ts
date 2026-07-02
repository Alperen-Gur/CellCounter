/**
 * pages/results/useResultsData.ts — loads everything the Results screen needs
 * for the current batch + image, and derives the confidence/ROI-filtered cell
 * list the whole sidebar reads.
 *
 * Mirrors the data plumbing of the Swift `ResultsView` / `ResultsSidebar`:
 *   - `currentBatch` from the store's `currentBatchId`
 *   - the batch's images sorted by `importedAt` (Swift `sortedImages`)
 *   - `currentImage` = images[currentImageIdx] (clamped)
 *   - the image's detection (`getDetection`), ground-truth annotations, and ROIs
 *   - `cells` = detection cells, filtered by effectiveConfidence THEN ROIs
 *     (exactly the Swift `ResultsSidebar.cells` computed property)
 *
 * All reads go through the frozen `PersistencePort` (`getPort()`); no direct
 * Tauri/SQLite here. Feature-owned by feat-results-viewer.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type {
  BatchDTO,
  ImageDTO,
  DetectionDTO,
  GroundTruthDTO,
  CellDTO,
} from "../../kernel/types";
import type { RoiDTO } from "../../kernel/persistence";
import { getPort } from "../../kernel/persistence";
import { useAppStore, effectiveConfidence } from "../../kernel/store/store";

import { applyRoiFilter } from "./roiFilter";
// The seg-npy panel broadcasts this after it replaces an image's detection.
// Import the canonical constant (rather than re-declaring the string) so the
// listener below can never drift from the dispatcher.
import { DETECTION_UPDATED_EVENT } from "./segnpy/SegNpyPanel";

export interface ResultsData {
  /** The open batch, or null while none is selected / still loading. */
  batch: BatchDTO | null;
  /** The batch's images, sorted by importedAt ascending. */
  images: ImageDTO[];
  /** Clamped index into `images`. */
  imageIdx: number;
  /** images[imageIdx], or null when the batch has no images. */
  currentImage: ImageDTO | null;
  /** Persisted detection for the current image (null if none ran). */
  detection: DetectionDTO | null;
  /** Ground-truth annotations for the current image. */
  annotations: GroundTruthDTO[];
  /** ROIs for the current image. */
  rois: RoiDTO[];
  /** Every detection cell (unfiltered) — for the overlay's hidden-tail merge. */
  allCells: CellDTO[];
  /** Cells after confidence + ROI filtering — what the sidebar counts. */
  cells: CellDTO[];
  /** The effective confidence cutoff for the current image. */
  confidenceCutoff: number;
  /** Thresholds for binning: the batch's persisted set, else the live global. */
  thresholds: number[];
  loading: boolean;
  /** Re-read detection + annotations + rois for the current image. */
  reloadImageData: () => Promise<void>;
  /** Re-read just the ROI list (after an ROI edit). */
  reloadRois: () => Promise<void>;
  /** Re-read just the annotations (after an annotate edit). */
  reloadAnnotations: () => Promise<void>;
}

export function useResultsData(): ResultsData {
  const currentBatchId = useAppStore((s) => s.currentBatchId);
  const currentImageIdx = useAppStore((s) => s.currentImageIdx);
  const globalConfidence = useAppStore((s) => s.confidence);
  const globalThresholds = useAppStore((s) => s.thresholds);

  const [batch, setBatch] = useState<BatchDTO | null>(null);
  const [images, setImages] = useState<ImageDTO[]>([]);
  const [detection, setDetection] = useState<DetectionDTO | null>(null);
  const [annotations, setAnnotations] = useState<GroundTruthDTO[]>([]);
  const [rois, setRois] = useState<RoiDTO[]>([]);
  const [loading, setLoading] = useState(true);

  // Guards against out-of-order async writes when the user switches fast.
  const batchReqRef = useRef(0);
  const imageReqRef = useRef(0);

  // ---- load the batch + its images whenever the batch id changes ----
  useEffect(() => {
    const req = ++batchReqRef.current;
    if (!currentBatchId) {
      setBatch(null);
      setImages([]);
      setLoading(false);
      return;
    }
    setLoading(true);
    const port = getPort();
    void (async () => {
      const b = await port.batch(currentBatchId);
      if (req !== batchReqRef.current) return;
      setBatch(b);
      if (!b) {
        setImages([]);
        setLoading(false);
        return;
      }
      // The batch carries imageIds; resolve to full ImageDTOs and sort by
      // importedAt (Swift `sortedImages`). allImages() is the port's only image
      // read, so we filter to this batch's ids client-side.
      const all = await port.allImages();
      if (req !== batchReqRef.current) return;
      const byId = new Map(all.map((im) => [im.id, im]));
      const ordered = b.imageIds
        .map((id) => byId.get(id))
        .filter((im): im is ImageDTO => im !== undefined)
        .sort((a, c) => (a.importedAt < c.importedAt ? -1 : a.importedAt > c.importedAt ? 1 : 0));
      setImages(ordered);
      setLoading(false);
    })();
  }, [currentBatchId]);

  const imageIdx = useMemo(() => {
    if (images.length === 0) return 0;
    return Math.min(Math.max(0, currentImageIdx), images.length - 1);
  }, [images.length, currentImageIdx]);

  const currentImage = images.length > 0 ? images[imageIdx] : null;
  const currentImageId = currentImage?.id;

  // ---- load detection + annotations + rois for the current image ----
  const loadForImage = useCallback(async (imageId: string | undefined) => {
    const req = ++imageReqRef.current;
    if (!imageId) {
      setDetection(null);
      setAnnotations([]);
      setRois([]);
      return;
    }
    const port = getPort();
    const [det, anns, roiList] = await Promise.all([
      port.getDetection(imageId),
      port.annotations(imageId),
      port.rois(imageId),
    ]);
    if (req !== imageReqRef.current) return;
    setDetection(det);
    setAnnotations(anns);
    setRois(roiList);
  }, []);

  useEffect(() => {
    void loadForImage(currentImageId);
  }, [currentImageId, loadForImage]);

  const reloadImageData = useCallback(
    () => loadForImage(currentImageId),
    [currentImageId, loadForImage],
  );

  // ---- refresh when another surface replaces this image's detection ----
  // SegNpyPanel imports a _seg.npy, re-saves the detection, and dispatches a
  // window `DETECTION_UPDATED_EVENT`. Without this listener the sidebar/overlay
  // keep showing the pre-import cells until the user switches images. Re-read
  // through the existing reload path (single source of truth) so counts, bins,
  // and the overlay all refresh together.
  //
  // Stale-closure guard: the effect depends on `currentImageId` (and on
  // `loadForImage`, which is stable), so it re-subscribes whenever the current
  // image changes — the handler therefore always compares against, and reloads,
  // the up-to-date image. The dispatcher tags the event with the affected
  // `imageId`; we only reload when it matches ours (or when it's absent, to stay
  // safe against future dispatchers that omit it).
  useEffect(() => {
    if (!currentImageId) return;
    const handler = (event: Event) => {
      const detail = (event as CustomEvent<{ imageId?: string }>).detail;
      const targetId = detail?.imageId;
      if (targetId && targetId !== currentImageId) return;
      void loadForImage(currentImageId);
    };
    window.addEventListener(DETECTION_UPDATED_EVENT, handler);
    return () => window.removeEventListener(DETECTION_UPDATED_EVENT, handler);
  }, [currentImageId, loadForImage]);

  const reloadRois = useCallback(async () => {
    if (!currentImageId) return;
    const port = getPort();
    const roiList = await port.rois(currentImageId);
    setRois(roiList);
  }, [currentImageId]);

  const reloadAnnotations = useCallback(async () => {
    if (!currentImageId) return;
    const port = getPort();
    const anns = await port.annotations(currentImageId);
    setAnnotations(anns);
  }, [currentImageId]);

  // ---- derived cell lists (confidence filter → ROI filter) ----
  const allCells = useMemo(() => detection?.cells ?? [], [detection]);

  const confidenceCutoff = useMemo(() => {
    if (!currentImage) return globalConfidence;
    // effectiveConfidence reads the per-image override, else the global slider.
    // `getState()` gives the full frozen store the kernel fn expects; keeping
    // `globalConfidence` in deps recomputes on slider change (and within that
    // render getState().confidence === globalConfidence already holds).
    return effectiveConfidence(useAppStore.getState(), currentImage);
  }, [currentImage, globalConfidence]);

  const thresholds = useMemo(
    () => (batch?.thresholds && batch.thresholds.length > 0 ? batch.thresholds : globalThresholds),
    [batch, globalThresholds],
  );

  const cells = useMemo(() => {
    const confFiltered = allCells.filter((c) => c.confidence >= confidenceCutoff);
    return applyRoiFilter(confFiltered, rois);
  }, [allCells, confidenceCutoff, rois]);

  return {
    batch,
    images,
    imageIdx,
    currentImage,
    detection,
    annotations,
    rois,
    allCells,
    cells,
    confidenceCutoff,
    thresholds,
    loading,
    reloadImageData,
    reloadRois,
    reloadAnnotations,
  };
}
