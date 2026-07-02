/**
 * kernel/store/store.ts — the global zustand store (ARCHITECTURE.md §3.3).
 *
 * Port of `Shared/AppState.swift`. Five slices — params / session / library /
 * processing / error — merged into one `AppStore`. The analysis-params slice
 * persists to `localStorage` (the Swift app used UserDefaults); everything else
 * is in-memory session/derived state.
 *
 * FROZEN CONTRACT (§6.4): the slice *shapes* (the keys pages read/write) are
 * frozen. Setters may be added later without breaking readers.
 *
 * Defaults come straight from `AppState.init` + the ARCHITECTURE spec:
 *   thresholds [20,30] · pxPerUm 2.6 (10× preset) · confidence 0.50 ·
 *   activeModelId "cp-cyto3" · channels [0,0] · manualMarkerDiameterUm 20 ·
 *   backgroundSubtract false · rollingBallRadius 50 · watershedSplit false ·
 *   watershedMinDistanceUm 8 · useGpu true · maxParallel 1.
 */

import { create } from "zustand";
import { persist, createJSONStorage } from "zustand/middleware";

import type { ImageDTO, OverlayMode, EditorMode } from "../types";
import { getPort } from "../persistence";

// ---------------------------------------------------------------------------
// Slice interfaces (FROZEN shapes)
// ---------------------------------------------------------------------------

export interface AnalysisParamsSlice {
  thresholds: number[]; // default [20,30]
  pxPerUm: number; // default 2.6 (10× preset)
  confidence: number; // default 0.50 — analysis filter, not destructive
  activeModelId: string; // default "cp-cyto3"
  channels: [number, number]; // default [0,0]
  manualMarkerDiameterUm: number; // default 20
  backgroundSubtract: boolean;
  rollingBallRadius: number; // 50
  watershedSplit: boolean;
  watershedMinDistanceUm: number; // 8
  useGpu: boolean; // default true
  maxParallel: number; // default 1 (CPU cellpose is CPU-bound)

  setThresholds(t: number[]): void;
  setPxPerUm(v: number): void;
  setConfidence(v: number): void;
  setActiveModelId(id: string): void;
  setChannels(c: [number, number]): void;
  setManualMarkerDiameterUm(v: number): void;
  setBackgroundSubtract(v: boolean): void;
  setRollingBallRadius(v: number): void;
  setWatershedSplit(v: boolean): void;
  setWatershedMinDistanceUm(v: number): void;
  setUseGpu(v: boolean): void;
  setMaxParallel(v: number): void;
}

export interface SessionSlice {
  currentBatchId?: string;
  currentImageIdx: number;
  overlayMode: OverlayMode; // outline | bbox
  showMaskFills: boolean;
  showOutlines: boolean; // Space/X/Z toggles
  maskOpacity: number; // 0..1
  editorMode: EditorMode;
  selectedCellIds: Set<string>;
  zoom: number;
  pan: { x: number; y: number };

  openBatch(id: string): void;
  nextImage(): void;
  prevImage(): void;
  setCurrentImageIdx(idx: number): void;
  setOverlayMode(m: OverlayMode): void;
  setShowMaskFills(v: boolean): void;
  setShowOutlines(v: boolean): void;
  setMaskOpacity(v: number): void;
  setEditorMode(m: EditorMode): void;
  setSelectedCellIds(ids: Set<string>): void;
  setZoom(z: number): void;
  setPan(p: { x: number; y: number }): void;
}

export interface LibrarySlice {
  // cached, refreshed on mutations (mirrors AppState.refreshLibraryStats)
  libraryImageCount: number;
  libraryBatchCount: number;
  reviewQueueCount: number;
  recentBatchIds: string[];
  refreshLibraryStats(): Promise<void>;
}

export interface ProcessingSlice {
  progress: number;
  stageLine: string;
  device: string;
  lastStageUpdateAt: number;

  setProgress(v: number): void;
  setStageLine(line: string): void;
  setDevice(device: string): void;
  resetProcessing(): void;
}

export interface ErrorSlice {
  lastDetectionError?: string;
  showDetectionError: boolean;
  lastCalibrationNote?: string;

  setDetectionError(message: string | undefined): void;
  dismissDetectionError(): void;
  setCalibrationNote(note: string | undefined): void;
}

export type AppStore = AnalysisParamsSlice &
  SessionSlice &
  LibrarySlice &
  ProcessingSlice &
  ErrorSlice;

// ---------------------------------------------------------------------------
// Constants (mirror AppState)
// ---------------------------------------------------------------------------

/** Confidence cutoff used for the Review-queue badge (AppState.reviewQueueConfidenceCutoff). */
export const REVIEW_QUEUE_CONFIDENCE_CUTOFF = 0.65;

/** localStorage key the persisted analysis-params slice is written under. */
const PERSIST_KEY = "cc-store";

// ---------------------------------------------------------------------------
// The store
// ---------------------------------------------------------------------------

export const useAppStore = create<AppStore>()(
  persist(
    (set, get) => ({
      // ---- AnalysisParamsSlice (persisted) ----
      thresholds: [20, 30],
      pxPerUm: 2.6,
      confidence: 0.5,
      activeModelId: "cp-cyto3",
      channels: [0, 0],
      manualMarkerDiameterUm: 20,
      backgroundSubtract: false,
      rollingBallRadius: 50,
      watershedSplit: false,
      watershedMinDistanceUm: 8,
      useGpu: true,
      maxParallel: 1,

      setThresholds: (t) => set({ thresholds: t }),
      setPxPerUm: (v) => set({ pxPerUm: v }),
      setConfidence: (v) => set({ confidence: v }),
      setActiveModelId: (id) => set({ activeModelId: id }),
      setChannels: (c) => set({ channels: c }),
      setManualMarkerDiameterUm: (v) => set({ manualMarkerDiameterUm: v }),
      setBackgroundSubtract: (v) => set({ backgroundSubtract: v }),
      setRollingBallRadius: (v) => set({ rollingBallRadius: v }),
      setWatershedSplit: (v) => set({ watershedSplit: v }),
      setWatershedMinDistanceUm: (v) => set({ watershedMinDistanceUm: v }),
      setUseGpu: (v) => set({ useGpu: v }),
      setMaxParallel: (v) => set({ maxParallel: v }),

      // ---- SessionSlice (in-memory) ----
      currentBatchId: undefined,
      currentImageIdx: 0,
      overlayMode: "outline",
      showMaskFills: true,
      showOutlines: true,
      maskOpacity: 0.25,
      editorMode: "view",
      selectedCellIds: new Set<string>(),
      zoom: 1,
      pan: { x: 0, y: 0 },

      openBatch: (id) =>
        set({
          currentBatchId: id,
          currentImageIdx: 0,
          selectedCellIds: new Set<string>(),
        }),
      nextImage: () => set({ currentImageIdx: get().currentImageIdx + 1 }),
      prevImage: () =>
        set({ currentImageIdx: Math.max(0, get().currentImageIdx - 1) }),
      setCurrentImageIdx: (idx) => set({ currentImageIdx: Math.max(0, idx) }),
      setOverlayMode: (m) => set({ overlayMode: m }),
      setShowMaskFills: (v) => set({ showMaskFills: v }),
      setShowOutlines: (v) => set({ showOutlines: v }),
      setMaskOpacity: (v) => set({ maskOpacity: v }),
      setEditorMode: (m) => set({ editorMode: m }),
      setSelectedCellIds: (ids) => set({ selectedCellIds: ids }),
      setZoom: (z) => set({ zoom: z }),
      setPan: (p) => set({ pan: p }),

      // ---- LibrarySlice (derived from PersistencePort) ----
      libraryImageCount: 0,
      libraryBatchCount: 0,
      reviewQueueCount: 0,
      recentBatchIds: [],
      refreshLibraryStats: async () => {
        const port = getPort();
        // Mirror AppState.refreshLibraryStats: counts + recent ids + review badge.
        const [imageCount, batchCount, batches, reviewCount] = await Promise.all([
          port.totalImageCount(),
          port.totalBatchCount(),
          port.allBatches(),
          port.uncorrectedCellCount(REVIEW_QUEUE_CONFIDENCE_CUTOFF),
        ]);
        set({
          libraryImageCount: imageCount,
          libraryBatchCount: batchCount,
          recentBatchIds: batches.map((b) => b.id),
          reviewQueueCount: reviewCount,
        });
      },

      // ---- ProcessingSlice (in-memory) ----
      progress: 0,
      stageLine: "",
      device: "",
      lastStageUpdateAt: 0,
      setProgress: (v) => set({ progress: v }),
      setStageLine: (line) =>
        set({ stageLine: line, lastStageUpdateAt: Date.now() }),
      setDevice: (device) => set({ device }),
      resetProcessing: () =>
        set({
          progress: 0,
          stageLine: "",
          device: "",
          lastStageUpdateAt: Date.now(),
        }),

      // ---- ErrorSlice (in-memory) ----
      lastDetectionError: undefined,
      showDetectionError: false,
      lastCalibrationNote: undefined,
      setDetectionError: (message) =>
        set({
          lastDetectionError: message,
          showDetectionError: message !== undefined,
        }),
      dismissDetectionError: () => set({ showDetectionError: false }),
      setCalibrationNote: (note) => set({ lastCalibrationNote: note }),
    }),
    {
      name: PERSIST_KEY,
      storage: createJSONStorage(() => localStorage),
      // Persist ONLY the analysis-params slice (Swift persisted these via
      // UserDefaults). Session/library/processing/error stay in-memory.
      partialize: (state): Pick<
        AnalysisParamsSlice,
        | "thresholds"
        | "pxPerUm"
        | "confidence"
        | "activeModelId"
        | "channels"
        | "manualMarkerDiameterUm"
        | "backgroundSubtract"
        | "rollingBallRadius"
        | "watershedSplit"
        | "watershedMinDistanceUm"
        | "useGpu"
        | "maxParallel"
      > => ({
        thresholds: state.thresholds,
        pxPerUm: state.pxPerUm,
        confidence: state.confidence,
        activeModelId: state.activeModelId,
        channels: state.channels,
        manualMarkerDiameterUm: state.manualMarkerDiameterUm,
        backgroundSubtract: state.backgroundSubtract,
        rollingBallRadius: state.rollingBallRadius,
        watershedSplit: state.watershedSplit,
        watershedMinDistanceUm: state.watershedMinDistanceUm,
        useGpu: state.useGpu,
        maxParallel: state.maxParallel,
      }),
    },
  ),
);

// ---------------------------------------------------------------------------
// effectiveConfidence (mirror AppState.effectiveConfidence)
// ---------------------------------------------------------------------------

/**
 * The confidence cutoff to use when deciding whether `image`'s cells are
 * visible: the per-image `confidenceOverride` wins over the global slider.
 * Mirrors `AppState.effectiveConfidence(for:)`.
 */
export function effectiveConfidence(store: AppStore, image: ImageDTO): number {
  if (image.confidenceOverride !== undefined && image.confidenceOverride !== null) {
    return image.confidenceOverride;
  }
  return store.confidence;
}
