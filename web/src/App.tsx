import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { decodeImageFiles, releaseImage } from "./app/imageFiles";
import { DebouncedByIdWriter } from "./app/debouncedMetadata";
import { filterCellsByRois } from "./app/roi";
import { analysisIdentities, calibrationForImage } from "./app/provenance";
import type { EditTool, Notice, RouteId, RunState, WorkspaceCell, WorkspaceImage } from "./app/types";
import { ProcessingPanel } from "./components/ProcessingPanel";
import { LinkedMeasurements } from "./components/LinkedMeasurements";
import { DurableQueueRunner, compareMaskVariants, previewKey, recoverJob, retryJob, restoreVariant, type AnalysisJob, type AnalysisPreview, type MaskVariant, type RunSnapshot } from "./app/workflow";
import { CLASSICAL_VERSION } from "./models/ClassicalInference";
import { getPendingUpdate, subscribeUpdates } from "./app/appUpdate";
import { UpdateNotice } from "./components/UpdateNotice";
import { EditDock } from "./components/EditDock";
import { HelpView } from "./views/HelpView";
import { Filmstrip } from "./components/Filmstrip";
import { ExportDialog } from "./components/ExportDialog";
import { ImageStage } from "./components/ImageStage";
import { Inspector, MODEL_OPTIONS, type AnalysisSettings } from "./components/Inspector";
import { NoticeBar } from "./components/NoticeBar";
import { Rail } from "./components/Rail";
import { ShortcutDialog } from "./components/ShortcutDialog";
import { TopBar } from "./components/TopBar";
import { WorkspaceToolbar } from "./components/WorkspaceToolbar";
import { applyCorrection, measureCells } from "./domain/analysis";
import { createBrowserImageSource } from "./domain/source";
import type { AnalysisParameters, CellMeasurement, ImageAnalysis } from "./domain/types";
import { useKeyboard } from "./hooks/useKeyboard";
import { useTheme } from "./hooks/useTheme";
import { decodeTiff } from "./import/tiff";
import { matchGroundTruth } from "./analysis";
import { getModelManifest, MODEL_CATALOG } from "./models/catalog";
import { sha256Hex, verifySha256 } from "./models/hash";
import { BrowserRepository, type WorkspaceImageMetadata } from "./storage/BrowserRepository";
import { InferenceWorkerClient } from "./workers/InferenceWorkerClient";
import { CompareView } from "./views/CompareView";
import { CapabilitiesView } from "./views/CapabilitiesView";
import { LibraryView } from "./views/LibraryView";
import { ModelsView } from "./views/ModelsView";
import { ReviewView } from "./views/ReviewView";
import { SettingsView } from "./views/SettingsView";
import { AnalysisLabView } from "./views/AnalysisLabView";
import "./styles/app.css";

const WelcomeScene = lazy(() => import("./components/WelcomeScene"));

const ORT_VERSION = "1.22.0";
const defaultSettings: AnalysisSettings = {
  modelId: "classical",
  pxPerUm: 1,
  confidence: 0.5,
  diameterUm: 30,
  backgroundSubtract: false,
  watershedSplit: true,
  sourceChannel: -1, projection: "first", thresholdMethod: "otsu", manualThreshold: .5, invert: false, minimumAreaPx: 9,
};

export interface HistoryEntry { cells: WorkspaceCell[]; analysis?: ImageAnalysis; groundTruth: WorkspaceImage["groundTruth"]; rois: WorkspaceImage["rois"]; }
const MAX_LOADED_SOURCES = 2;

export function historySnapshot(image: WorkspaceImage): HistoryEntry {
  return { cells: image.cells, analysis: image.analysis, groundTruth: image.groundTruth, rois: image.rois };
}

function nearestCell(cells: WorkspaceCell[], x: number, y: number): WorkspaceCell | undefined {
  const nearest = cells.reduce<{ cell?: WorkspaceCell; distance: number }>((best, cell) => {
    const distance = Math.hypot(cell.cx - x, cell.cy - y);
    return distance < best.distance ? { cell, distance } : best;
  }, { distance: Number.POSITIVE_INFINITY });
  return nearest.cell && nearest.distance <= nearest.cell.diameterPx / 2 + 6 ? nearest.cell : undefined;
}

function toWorkspaceCell(cell: CellMeasurement): WorkspaceCell {
  return {
    id: cell.id,
    cx: cell.centroidPx.x,
    cy: cell.centroidPx.y,
    diameterPx: cell.equivalentDiameterPx,
    diameterUm: cell.equivalentDiameterUm,
    areaUm2: cell.areaUm2,
    confidence: cell.confidence,
    isManual: cell.origin === "manual",
    reviewed: cell.reviewed,
    contourPx: cell.contourPx.map((point) => [point.x, point.y]),
  };
}

function cellSummary(cell: WorkspaceCell): WorkspaceCell {
  const { contourPx: _contourPx, ...summary } = cell;
  return summary;
}

function demoteWorkspaceImage(image: WorkspaceImage): WorkspaceImage {
  if (image.objectUrl) URL.revokeObjectURL(image.objectUrl);
  return {
    ...image,
    file: new File([], image.fileName, { type: image.sourceMediaType ?? image.file.type }),
    originalFile: undefined,
    objectUrl: "",
    sourceLoaded: false,
    cells: image.cells.map(cellSummary),
    analysis: undefined,
  };
}

export function enforceLoadedSourceLimit(images: WorkspaceImage[], recentIds: readonly string[], maximum = MAX_LOADED_SOURCES): WorkspaceImage[] {
  const keep = new Set(recentIds.slice(0, maximum));
  return images.map((image) => image.sourceLoaded && !keep.has(image.id) ? demoteWorkspaceImage(image) : image);
}

function circleContour(cell: WorkspaceCell) {
  return Array.from({ length: 32 }, (_, index) => {
    const angle = index / 32 * Math.PI * 2;
    return { x: cell.cx + Math.cos(angle) * cell.diameterPx / 2, y: cell.cy + Math.sin(angle) * cell.diameterPx / 2 };
  });
}

function measurements(image: WorkspaceImage, thresholds: readonly number[]): CellMeasurement[] {
  return measureCells(image.cells.map((cell) => ({
    id: cell.id,
    centroidPx: { x: cell.cx, y: cell.cy },
    contourPx: cell.contourPx?.map(([x, y]) => ({ x, y })) ?? circleContour(cell),
    confidence: cell.confidence,
    origin: cell.isManual ? "manual" as const : "model" as const,
  })), { pxPerUm: image.pxPerUm, source: image.calibrationSource ?? "default", confidence: image.calibrationConfidence ?? "low" }, { widthPx: image.width, heightPx: image.height }, thresholds);
}

function analysisParameters(settings: AnalysisSettings): AnalysisParameters {
  return {
    modelId: settings.modelId,
    confidenceThreshold: settings.confidence,
    expectedDiameterUm: settings.diameterUm || null,
    channels: [Math.max(0, settings.sourceChannel ?? -1), 0],
    sourceChannel: settings.sourceChannel ?? -1, projection: settings.projection ?? "first",
    thresholdMethod: settings.thresholdMethod ?? "otsu", manualThreshold: settings.manualThreshold ?? .5,
    invert: settings.invert ?? false, minimumAreaPx: settings.minimumAreaPx ?? 9,
    backgroundSubtract: settings.backgroundSubtract,
    rollingBallRadiusPx: 50,
    watershedSplit: settings.watershedSplit,
    watershedMinDistanceUm: 8,
    sizeThresholdsUm: [20, 30],
  };
}

function snapshotFor(settings: AnalysisSettings, image: WorkspaceImage): RunSnapshot {
  const classical = settings.modelId === "classical";
  const manifest = classical ? undefined : getModelManifest(settings.modelId);
  return { parameters: analysisParameters(settings), calibration: calibrationForImage(image), model: classical
    ? { id: "classical", displayName: "Classical threshold + watershed", manifestVersion: CLASSICAL_VERSION, artifactSha256: "not-applicable:bundled-algorithm", runtime: "browser/classical", runtimeVersion: CLASSICAL_VERSION }
    : { id: manifest!.id, displayName: manifest!.displayName, manifestVersion: manifest!.manifestVersion, artifactSha256: manifest!.artifact.sha256, runtime: "onnxruntime-web/webgpu", runtimeVersion: ORT_VERSION } };
}

async function workspaceFromStored(source: Blob, metadata: WorkspaceImageMetadata, analysis?: ImageAnalysis, existingThumbnailUrl?: string): Promise<WorkspaceImage> {
  const storedFile = new File([source], metadata.fileName, { type: metadata.sourceMediaType ?? metadata.mediaType });
  const isTiff = /tiff?/i.test(metadata.sourceMediaType ?? "") || /\.ome\.tiff?$|\.tiff?$/i.test(metadata.fileName);
  const decoded = isTiff ? await decodeTiff(storedFile, metadata.sourceSha256) : undefined;
  const file = decoded?.displayFile ?? storedFile;
  return {
    id: metadata.id,
    file,
    originalFile: isTiff ? storedFile : undefined,
    fileName: metadata.fileName,
    objectUrl: URL.createObjectURL(file),
    thumbnailBlob: metadata.thumbnail,
    thumbnailUrl: existingThumbnailUrl ?? (metadata.thumbnail ? URL.createObjectURL(metadata.thumbnail) : undefined),
    sourceLoaded: true,
    width: metadata.widthPx,
    height: metadata.heightPx,
    importedAt: metadata.importedAt,
    cells: analysis?.cells.map(toWorkspaceCell) ?? [...(metadata.manualCells ?? metadata.cellSummaries ?? [])],
    condition: metadata.condition,
    pxPerUm: metadata.pxPerUm,
    sourceSha256: metadata.sourceSha256,
    sourceByteLength: metadata.sourceByteLength,
    sourceMediaType: metadata.sourceMediaType,
    calibrationSource: metadata.calibrationSource,
    calibrationConfidence: metadata.calibrationConfidence,
    planeCount: metadata.planeCount,
    samplesPerPixel: metadata.samplesPerPixel,
    bitsPerSample: metadata.bitsPerSample,
    groundTruth: [...(metadata.groundTruth ?? [])],
    rois: [...(metadata.rois ?? [])],
    note: metadata.note ?? "",
    reviewConfidence: metadata.reviewConfidence ?? "high",
    modelId: analysis?.model.id,
    analysisId: analysis?.id ?? metadata.analysisId ?? undefined,
    analysis,
  };
}

function workspaceFromMetadata(metadata: WorkspaceImageMetadata, analysis?: ImageAnalysis): WorkspaceImage {
  const placeholder = new File([], metadata.fileName, { type: metadata.mediaType });
  return {
    id: metadata.id,
    file: placeholder,
    fileName: metadata.fileName,
    objectUrl: "",
    thumbnailUrl: metadata.thumbnail ? URL.createObjectURL(metadata.thumbnail) : undefined,
    thumbnailBlob: metadata.thumbnail,
    sourceLoaded: false,
    width: metadata.widthPx,
    height: metadata.heightPx,
    importedAt: metadata.importedAt,
    cells: analysis?.cells.map(toWorkspaceCell) ?? [...(metadata.cellSummaries ?? [])],
    condition: metadata.condition,
    pxPerUm: metadata.pxPerUm,
    modelId: analysis?.model.id ?? metadata.modelId,
    analysisId: analysis?.id ?? metadata.analysisId ?? undefined,
    analysis,
    sourceSha256: metadata.sourceSha256,
    sourceByteLength: metadata.sourceByteLength,
    sourceMediaType: metadata.sourceMediaType,
    calibrationSource: metadata.calibrationSource,
    calibrationConfidence: metadata.calibrationConfidence,
    planeCount: metadata.planeCount,
    samplesPerPixel: metadata.samplesPerPixel,
    bitsPerSample: metadata.bitsPerSample,
    groundTruth: [...(metadata.groundTruth ?? [])],
    rois: [...(metadata.rois ?? [])],
    note: metadata.note ?? "",
    reviewConfidence: metadata.reviewConfidence ?? "high",
  };
}

function workspaceMetadata(image: WorkspaceImage, analysisId = image.analysis?.id ?? null): WorkspaceImageMetadata {
  return { id: image.id, fileName: image.fileName, mediaType: image.file.type || image.sourceMediaType || "application/octet-stream", widthPx: image.width, heightPx: image.height, importedAt: image.importedAt, condition: image.condition, pxPerUm: image.pxPerUm, analysisId: analysisId ?? image.analysisId ?? null, sourceSha256: image.sourceSha256, sourceByteLength: image.sourceByteLength, sourceMediaType: image.sourceMediaType, calibrationSource: image.calibrationSource, calibrationConfidence: image.calibrationConfidence, planeCount: image.planeCount, samplesPerPixel: image.samplesPerPixel, bitsPerSample: image.bitsPerSample, thumbnail: image.thumbnailBlob, groundTruth: image.groundTruth, rois: image.rois, note: image.note, reviewConfidence: image.reviewConfidence, modelId: image.modelId, cellSummaries: image.cells.map(cellSummary), manualCells: !image.analysis && !image.analysisId ? image.cells : undefined };
}

export default function App() {
  const [welcomeOpen, setWelcomeOpen] = useState(false);
  const pendingUpdate = useSyncExternalStore(subscribeUpdates, getPendingUpdate);
  const [updating, setUpdating] = useState(false);
  const [route, setRoute] = useState<RouteId>("workspace");
  const [processScope, setProcessScope] = useState<"image" | "all">("image");
  const [navCollapsed, setNavCollapsed] = useState(false);
  const [inspectorOpen, setInspectorOpen] = useState(false);
  const [images, setImages] = useState<WorkspaceImage[]>([]);
  const [activeId, setActiveId] = useState<string>();
  const [settings, setSettings] = useState(() => {
    try { const saved = JSON.parse(localStorage.getItem("cellcounter-setup-v1") ?? "null"); return saved && MODEL_OPTIONS.some((model) => model.id === saved.modelId) && Number.isFinite(saved.pxPerUm) && saved.pxPerUm > 0 ? { ...defaultSettings, ...saved } as AnalysisSettings : defaultSettings; }
    catch { return defaultSettings; }
  });
  const [tool, setTool] = useState<EditTool>("inspect");
  const [selectedCellId, setSelectedCellId] = useState<string>();
  const [mergeCellId, setMergeCellId] = useState<string>();
  const [history, setHistory] = useState<HistoryEntry[]>([]);
  const [redoHistory, setRedoHistory] = useState<HistoryEntry[]>([]);
  const [runState, setRunState] = useState<RunState>("idle");
  const [notice, setNotice] = useState<Notice>();
  const [helpOpen, setHelpOpen] = useState(false);
  const [exportOpen, setExportOpen] = useState(false);
  const [jobs, setJobs] = useState<AnalysisJob[]>([]);
  const [preview, setPreview] = useState<AnalysisPreview>();
  const [showingPreview, setShowingPreview] = useState(false);
  const [variants, setVariants] = useState<MaskVariant[]>([]);
  const [alternativeId, setAlternativeId] = useState<string>();
  const [preparedUrl, setPreparedUrl] = useState<string>();
  const runner = useRef<DurableQueueRunner | undefined>(undefined);
  const busyRef = useRef(false);
  const [cachedModels, setCachedModels] = useState<ReadonlySet<string>>(() => new Set());
  const fileInput = useRef<HTMLInputElement>(null);
  const folderInput = useRef<HTMLInputElement>(null);
  const modelInput = useRef<HTMLInputElement>(null);
  const pendingModelId = useRef<AnalysisSettings["modelId"]>(settings.modelId);
  const abortController = useRef<AbortController | undefined>(undefined);
  const repository = useRef<BrowserRepository | undefined>(undefined);
  const workerClient = useRef<InferenceWorkerClient | undefined>(undefined);
  const imageSnapshot = useRef<WorkspaceImage[]>([]);
  const recentSourceIds = useRef<string[]>([]);
  const metadataWriter = useRef<DebouncedByIdWriter<WorkspaceImage> | undefined>(undefined);
  metadataWriter.current ??= new DebouncedByIdWriter(350, (image) => repository.current?.putWorkspaceImage(workspaceMetadata(image)));
  const { theme, toggleTheme } = useTheme();

  const readyModels = useMemo(() => new Set([
    ...MODEL_CATALOG.filter((manifest) => (manifest.artifact.availability as string) === "ready").map((manifest) => manifest.id),
    ...cachedModels, "classical",
  ]), [cachedModels]);
  const busy = runState === "running" || runState === "preparing";
  const activeImage = images.find((image) => image.id === activeId);
  const matchingPreview = Boolean(activeImage?.sourceSha256 && preview?.imageId === activeImage.id && preview.key === previewKey(activeImage.sourceSha256, snapshotFor(settings, activeImage)));
  const displayAnalysis = showingPreview && preview?.imageId === activeImage?.id ? preview?.analysis : activeImage?.analysis;
  const stageImage = activeImage ? { ...activeImage, objectUrl: preparedUrl ?? activeImage.objectUrl, cells: showingPreview && preview?.imageId === activeImage.id ? preview.analysis.cells.map(toWorkspaceCell) : activeImage.cells } : undefined;
  const alternative = variants.find((variant) => variant.id === alternativeId);
  const variantComparison = useMemo(() => activeImage?.analysis && alternative ? compareMaskVariants(activeImage.analysis, alternative.analysis) : undefined, [activeImage?.analysis, alternative]);
  const visibleCells = useMemo(() => activeImage ? filterCellsByRois(activeImage) : [], [activeImage]);
  const meanDiameter = visibleCells.length ? visibleCells.reduce((sum, cell) => sum + cell.diameterUm, 0) / visibleCells.length : 0;
  const truthMetrics = useMemo(() => activeImage ? matchGroundTruth(activeImage.groundTruth, activeImage.cells.map((cell) => ({ id: cell.id, x: cell.cx, y: cell.cy })), 10 * activeImage.pxPerUm) : undefined, [activeImage?.groundTruth, activeImage?.cells, activeImage?.pxPerUm]);

  useEffect(() => { try { localStorage.setItem("cellcounter-setup-v1", JSON.stringify(settings)); } catch { /* Analysis jobs still record exact settings in IndexedDB. */ } }, [settings]);
  useEffect(() => {
    if (!displayAnalysis?.displayPlane) { setPreparedUrl(undefined); return; }
    const url = URL.createObjectURL(displayAnalysis.displayPlane); setPreparedUrl(url);
    return () => URL.revokeObjectURL(url);
  }, [displayAnalysis?.displayPlane]);

  const flushPendingMetadata = useCallback(() => {
    metadataWriter.current?.flushAll();
  }, []);

  const queueMetadataPersistence = useCallback((image: WorkspaceImage) => {
    metadataWriter.current?.queue(image);
  }, []);

  useEffect(() => {
    window.addEventListener("pagehide", flushPendingMetadata);
    return () => { window.removeEventListener("pagehide", flushPendingMetadata); flushPendingMetadata(); };
  }, [flushPendingMetadata]);

  useEffect(() => { imageSnapshot.current = images; }, [images]);
  useEffect(() => {
    if (!activeImage) return;
    setSettings((current) => current.pxPerUm === activeImage.pxPerUm ? current : { ...current, pxPerUm: activeImage.pxPerUm });
  }, [activeImage?.id, activeImage?.pxPerUm]);
  useEffect(() => {
    let disposed = false;
    void BrowserRepository.open().then(async (opened) => {
      if (disposed) { opened.close(); return; }
      repository.current = opened;
      const recovered = (await opened.listJobs()).map(recoverJob);
      await Promise.all(recovered.map((job) => opened.putJob(job)));
      if (!disposed) setJobs(recovered);
      const storedMetadata = await opened.listWorkspaceImages();
      let metadata = storedMetadata;
      if (!metadata.length) {
        // Legacy migration only. Normal startup never clones the full analyses store.
        const [storedAnalyses, batches] = await Promise.all([opened.listAnalyses(), opened.listBatches()]);
        const conditionByAnalysis = new Map(batches.flatMap((batch) => batch.analyses.map((analysis) => [analysis.id, batch.condition] as const)));
        metadata = storedAnalyses.map((analysis): WorkspaceImageMetadata => ({ id: analysis.image.id, fileName: analysis.image.fileName, mediaType: analysis.image.mediaType, widthPx: analysis.image.widthPx, heightPx: analysis.image.heightPx, importedAt: analysis.image.importedAt, condition: conditionByAnalysis.get(analysis.id) ?? "Unassigned", pxPerUm: analysis.calibration.pxPerUm, analysisId: analysis.id, modelId: analysis.model.id, cellSummaries: analysis.cells.map(toWorkspaceCell).map(cellSummary) }));
      }
      if (!disposed && !metadata.length && !imageSnapshot.current.length) {
        let dismissed = false;
        try { dismissed = localStorage.getItem("cellcounter-welcome-dismissed") === "1"; } catch { /* Storage can be unavailable; opening the workspace remains immediate. */ }
        if (!dismissed) setWelcomeOpen(true);
      }
      const restored = metadata.map((item) => workspaceFromMetadata(item));
      if (!disposed && restored.length) {
        setImages(restored);
        setActiveId(restored[0].id);
        const firstMetadata = metadata[0];
        const [firstSource, firstAnalysis] = await Promise.all([
          opened.getSource(restored[0].id),
          firstMetadata.analysisId ? opened.getAnalysis(firstMetadata.analysisId) : Promise.resolve(null),
        ]);
        const first = firstSource ? await workspaceFromStored(firstSource.blob, firstMetadata, firstAnalysis ?? undefined, restored[0].thumbnailUrl) : restored[0];
        if (!disposed && firstSource) {
          recentSourceIds.current = [first.id];
          setImages((current) => current.map((image) => image.id === first.id ? first : image));
        }
      }
    }).catch((error: unknown) => {
      if (!disposed) setNotice({ tone: "warning", title: "Local project storage is unavailable.", detail: ` ${error instanceof Error ? error.message : String(error)}` });
    });
    return () => {
      disposed = true;
      flushPendingMetadata();
      runner.current?.cancel();
      workerClient.current?.dispose();
      repository.current?.close();
      imageSnapshot.current.forEach(releaseImage);
    };
  }, [flushPendingMetadata]);

  const importImages = useCallback(() => fileInput.current?.click(), []);
  const importFolder = useCallback(() => folderInput.current?.click(), []);
  const onFiles = async (files: FileList | null) => {
    if (!files?.length || busyRef.current) return;
    const decoded = await decodeImageFiles(files);
    const knownDigests = new Set(images.map((image) => image.sourceSha256).filter((digest): digest is string => Boolean(digest)));
    const accepted: WorkspaceImage[] = [];
    let duplicateCount = 0;
    for (const image of decoded.images) {
      if (image.sourceSha256 && knownDigests.has(image.sourceSha256)) { duplicateCount += 1; releaseImage(image); }
      else { accepted.push(image); if (image.sourceSha256) knownDigests.add(image.sourceSha256); }
    }
    if (accepted.length) {
      setImages((current) => [...current, ...accepted]);
      setActiveId(accepted[0].id);
      setRoute("workspace");
      let stored = 0;
      try {
        for (const image of accepted) {
          const sourceFile = image.originalFile ?? image.file;
          await repository.current?.putSource(createBrowserImageSource(sourceFile, { id: image.id, fileName: image.fileName, lastModified: sourceFile.lastModified }));
          await repository.current?.putWorkspaceImage(workspaceMetadata(image));
          stored += 1;
        }
        recentSourceIds.current = [accepted[0].id, ...recentSourceIds.current.filter((id) => id !== accepted[0].id)].slice(0, MAX_LOADED_SOURCES);
        setImages((current) => enforceLoadedSourceLimit(current, recentSourceIds.current));
        setNotice({ tone: "success", title: `${accepted.length} image${accepted.length === 1 ? "" : "s"} imported.`, detail: `${duplicateCount ? ` ${duplicateCount} exact duplicate${duplicateCount === 1 ? " was" : "s were"} skipped.` : ""} Stored privately on this device.` });
      } catch (error) {
        setNotice({ tone: "warning", title: `${accepted.length} images opened; ${stored} persisted.`, detail: ` Local storage stopped safely: ${error instanceof Error ? error.message : String(error)}` });
      }
    }
    else if (duplicateCount) setNotice({ tone: "info", title: "No new images imported.", detail: ` ${duplicateCount} exact duplicate${duplicateCount === 1 ? " was" : "s were"} skipped by SHA-256.` });
    if (decoded.errors.length) setNotice({ tone: "warning", title: "Some files were skipped.", detail: ` ${decoded.errors.join(" ")}` });
    if (fileInput.current) fileInput.current.value = "";
  };

  const updateActive = useCallback((update: (image: WorkspaceImage) => WorkspaceImage) => {
    if (!activeId) return;
    setImages((current) => current.map((image) => {
      if (image.id !== activeId) return image;
      const updated = update(image); queueMetadataPersistence(updated); return updated;
    }));
  }, [activeId, queueMetadataPersistence]);
  const pushHistory = useCallback((image: WorkspaceImage) => {
    setHistory((items) => [...items.slice(-49), historySnapshot(image)]);
    setRedoHistory([]);
  }, []);

  const applyEdit = (image: WorkspaceImage, operation: Parameters<typeof applyCorrection>[1]) => {
    const state = { cells: image.analysis?.cells ?? measurements(image, [20, 30]), log: image.analysis?.correctionLog ?? [] };
    const corrected = applyCorrection(state, operation, { calibration: { pxPerUm: image.pxPerUm, source: image.calibrationSource ?? "default", confidence: image.calibrationConfidence ?? "low" }, imageSize: { widthPx: image.width, heightPx: image.height }, sizeThresholdsUm: [20, 30] });
    const nextAnalysis = image.analysis ? { ...image.analysis, cells: corrected.cells, correctionLog: corrected.log } : undefined;
    if (nextAnalysis) void repository.current?.putAnalysis(nextAnalysis);
    return { ...image, cells: corrected.cells.map(toWorkspaceCell), analysis: nextAnalysis };
  };

  const onStagePointer = (x: number, y: number) => {
    if (!activeImage) return;
    if (showingPreview || busy) { setSelectedCellId(nearestCell(stageImage?.cells ?? [], x, y)?.id); return; }
    const nearest = nearestCell(activeImage.cells, x, y);
    if (tool === "inspect") { setSelectedCellId(nearest?.id); return; }
    if (tool === "ground-truth") {
      pushHistory(activeImage);
      updateActive((image) => {
        const updated = { ...image, groundTruth: [...image.groundTruth, { id: `truth-${crypto.randomUUID()}`, x, y, diameterPx: (settings.diameterUm || 30) * image.pxPerUm }] };
        void repository.current?.putWorkspaceImage(workspaceMetadata(updated));
        return updated;
      });
      return;
    }
    if (tool === "merge" && nearest && !mergeCellId) { setMergeCellId(nearest.id); setSelectedCellId(nearest.id); return; }
    if ((tool === "remove" || tool === "resize" || tool === "merge" || tool === "split") && !nearest) return;
    pushHistory(activeImage);
    const operationId = `correction-${crypto.randomUUID()}`;
    const appliedAt = new Date().toISOString();
    if (tool === "add") {
      updateActive((image) => applyEdit(image, { id: operationId, appliedAt, kind: "add", centerPx: { x, y }, diameterUm: settings.diameterUm || 30 }));
      setSelectedCellId(`${operationId}:cell`);
    } else if (tool === "remove" && nearest) {
      updateActive((image) => applyEdit(image, { id: operationId, appliedAt, kind: "remove", cellIds: [nearest.id] }));
      setSelectedCellId(undefined);
    } else if (tool === "resize" && nearest) {
      updateActive((image) => applyEdit(image, { id: operationId, appliedAt, kind: "resize", cellId: nearest.id, diameterUm: settings.diameterUm || nearest.diameterUm }));
      setSelectedCellId(nearest.id);
    } else if (tool === "merge" && nearest && mergeCellId && nearest.id !== mergeCellId) {
      updateActive((image) => applyEdit(image, { id: operationId, appliedAt, kind: "merge", cellIds: [mergeCellId, nearest.id] }));
      setSelectedCellId(`${operationId}:cell`);
      setMergeCellId(undefined);
    } else if (tool === "split" && nearest) {
      const extent = Math.max(4, nearest.diameterPx);
      updateActive((image) => applyEdit(image, { id: operationId, appliedAt, kind: "split", cellId: nearest.id, line: [{ x, y: y - extent }, { x, y: y + extent }] }));
      setSelectedCellId(`${operationId}:cell-1`);
    }
  };

  const addRoi = (start: { x: number; y: number }, end: { x: number; y: number }, kind: "include" | "exclude") => {
    if (activeImage) pushHistory(activeImage);
    updateActive((image) => {
      const updated = { ...image, rois: [...image.rois, { id: `roi-${crypto.randomUUID()}`, kind, x: Math.min(start.x, end.x), y: Math.min(start.y, end.y), width: Math.abs(end.x - start.x), height: Math.abs(end.y - start.y) }] };
      void repository.current?.putWorkspaceImage(workspaceMetadata(updated));
      return updated;
    });
  };

  const clearValidation = (target: "truth" | "rois") => {
    if (!activeImage) return;
    pushHistory(activeImage);
    updateActive((image) => {
      const updated = target === "truth" ? { ...image, groundTruth: [] } : { ...image, rois: [] };
      void repository.current?.putWorkspaceImage(workspaceMetadata(updated));
      return updated;
    });
  };

  const updateCalibration = (image: WorkspaceImage, pxPerUm: number, source: "manual" | "protocol"): WorkspaceImage => {
    const calibration = { pxPerUm, source, confidence: "high" as const };
    const analysis = image.analysis ? restoreVariant({ id: "calibration", imageId: image.id, name: "Current", createdAt: "", analysis: image.analysis }, calibration) : undefined;
    if (analysis) void repository.current?.putAnalysis(analysis);
    const ratio = image.pxPerUm / pxPerUm;
    return { ...image, pxPerUm, calibrationSource: source, calibrationConfidence: "high", analysis, cells: analysis ? analysis.cells.map(toWorkspaceCell) : image.cells.map((cell) => ({ ...cell, diameterUm: cell.diameterPx / pxPerUm, areaUm2: cell.areaUm2 === undefined ? undefined : cell.areaUm2 * ratio * ratio })) };
  };

  const updateImageMetadata = (patch: Pick<WorkspaceImage, "note" | "reviewConfidence">) => {
    updateActive((image) => {
      const updated = { ...image, ...patch };
      queueMetadataPersistence(updated);
      if (patch.reviewConfidence !== image.reviewConfidence) metadataWriter.current?.flush(updated.id);
      return updated;
    });
  };

  const undo = () => {
    const previous = history.at(-1);
    if (!previous || !activeImage) return;
    setRedoHistory((items) => [...items.slice(-49), historySnapshot(activeImage)]);
    updateActive((image) => {
      if (previous.analysis) void repository.current?.putAnalysis(previous.analysis);
      const updated = { ...image, cells: previous.cells, analysis: previous.analysis, groundTruth: previous.groundTruth, rois: previous.rois };
      void repository.current?.putWorkspaceImage(workspaceMetadata(updated));
      return updated;
    });
    setHistory((items) => items.slice(0, -1));
  };

  const redo = () => {
    const next = redoHistory.at(-1);
    if (!next || !activeImage) return;
    setHistory((items) => [...items.slice(-49), historySnapshot(activeImage)]);
    updateActive((image) => {
      if (next.analysis) void repository.current?.putAnalysis(next.analysis);
      const updated = { ...image, cells: next.cells, analysis: next.analysis, groundTruth: next.groundTruth, rois: next.rois };
      void repository.current?.putWorkspaceImage(workspaceMetadata(updated));
      return updated;
    });
    setRedoHistory((items) => items.slice(0, -1));
  };

  const refreshVariants = useCallback(async (imageId: string) => {
    const saved = await repository.current?.listVariants(imageId);
    if (imageSnapshot.current.find((image) => image.id === imageId)) setVariants(saved ?? []);
  }, []);
  useEffect(() => {
    let disposed = false;
    setPreview(undefined); setShowingPreview(false); setAlternativeId(undefined); setVariants([]);
    if (activeId && repository.current) void Promise.all([repository.current.getPreview(activeId), repository.current.listVariants(activeId)]).then(([savedPreview, savedVariants]) => { if (!disposed) { setPreview(savedPreview ?? undefined); setVariants(savedVariants); } });
    return () => { disposed = true; };
  }, [activeId]);

  const executeImage = useCallback(async (image: WorkspaceImage, frozen: RunSnapshot, signal: AbortSignal): Promise<ImageAnalysis> => {
    if (!repository.current) throw new Error("Local project storage is not ready.");
    const learned = frozen.parameters.modelId !== "classical";
    if (learned && getModelManifest(frozen.parameters.modelId).artifact.availability !== "ready") throw new Error(`${frozen.model.displayName} needs a validated browser artifact. Choose the built-in classical detector to run threshold segmentation.`);
    if (learned && !navigator.gpu) throw new Error("The selected learned model requires WebGPU.");
    if (typeof Worker === "undefined") throw new Error("Web Workers are required for local processing.");
    if (!workerClient.current || workerClient.current.isDisposed) workerClient.current = new InferenceWorkerClient(new Worker(new URL("./workers/inference.worker.ts", import.meta.url), { type: "module", name: "cellcounter-inference" }));
    const storedSource = await repository.current.getSource(image.id);
    if (!storedSource) throw new Error("The original image is missing from local storage. Import it again.");
    const sourceDigest = await sha256Hex(await storedSource.blob.arrayBuffer());
    if (sourceDigest !== image.sourceSha256) throw new Error("Stored source bytes differ from the image recorded in this job.");
    let source = storedSource;
    if (learned && /tiff/i.test(storedSource.mediaType)) {
      const prepared = await decodeTiff(new File([storedSource.blob], storedSource.fileName, { type: storedSource.mediaType }), sourceDigest);
      source = createBrowserImageSource(prepared.displayFile, { id: image.id, fileName: `${image.fileName}::normalized-first-plane.png` });
    }
    const result = await workerClient.current.analyze({ source, calibration: frozen.calibration, parameters: frozen.parameters, signal, onProgress: (progress) => setRunState(progress.stage === "environment" || progress.stage === "model" || progress.stage === "decode" ? "preparing" : "running") });
    if (signal.aborted) throw new DOMException("Analysis cancelled", "AbortError");
    const analysisDigest = source === storedSource ? sourceDigest : await sha256Hex(await source.blob.arrayBuffer());
    const identities = analysisIdentities(image, analysisDigest, result.imageWidth, result.imageHeight);
    return {
      schemaVersion: 1, id: `${image.id}:analysis`,
      image: { ...identities.image, fileName: source.fileName, sha256: analysisDigest, byteLength: source.byteLength, mediaType: source.mediaType },
      calibration: frozen.calibration, parameters: frozen.parameters, model: frozen.model,
      ranAt: new Date().toISOString(), cells: result.cells, correctionLog: [], imageStats: result.imageStats, displayPlane: result.displayPlane,
      workflow: { runCalibration: frozen.calibration },
      originalSource: identities.originalSource ? { ...identities.originalSource, analysisTransform: learned ? identities.originalSource.analysisTransform : "source-channel-projection" } : undefined,
    };
  }, []);

  const saveResult = useCallback(async (imageId: string, analysis: ImageAnalysis) => {
    const repo = repository.current;
    if (!repo) throw new Error("Local storage is unavailable.");
    metadataWriter.current?.flush(imageId);
    const image = imageSnapshot.current.find((candidate) => candidate.id === imageId);
    if (!image) throw new Error("This image was removed from the library.");
    const previous = image.analysis ?? (image.analysisId ? await repo.getAnalysis(image.analysisId) : null);
    if (previous) await repo.putVariant({ id: crypto.randomUUID(), imageId, name: `Before processing · ${new Date().toLocaleString()}`, createdAt: new Date().toISOString(), analysis: previous });
    const updated = { ...image, width: analysis.image.widthPx, height: analysis.image.heightPx, cells: analysis.cells.map(toWorkspaceCell), modelId: analysis.model.id, analysisId: analysis.id, analysis };
    await repo.putAnalysis(analysis);
    await repo.putWorkspaceImage(workspaceMetadata(updated, analysis.id));
    setImages((items) => items.map((item) => item.id === imageId ? { ...item, ...updated, analysis: item.sourceLoaded ? analysis : undefined, cells: item.sourceLoaded ? updated.cells : updated.cells.map(cellSummary) } : item));
  }, []);

  const run = useCallback(async () => {
    if (!activeImage || busyRef.current) return;
    busyRef.current = true;
    const controller = new AbortController(); abortController.current = controller; setRunState("preparing");
    try {
      const frozen = snapshotFor(settings, activeImage);
      const key = previewKey(activeImage.sourceSha256 ?? "", frozen);
      const cached = await repository.current?.getPreview(activeImage.id);
      const analysis = cached?.key === key ? cached.analysis : await executeImage(activeImage, frozen, controller.signal);
      if (controller.signal.aborted) throw new DOMException("Cancelled", "AbortError");
      const next: AnalysisPreview = { id: activeImage.id, imageId: activeImage.id, key, analysis };
      if (!repository.current) throw new Error("Local preview storage is unavailable.");
      await repository.current.putPreview(next);
      setPreview(next); setShowingPreview(true); setRunState("complete");
      setNotice({ tone: "success", title: `${analysis.cells.length} objects in whole-image preview.`, detail: " Preview saved locally. Process this image or the batch to apply it; matching settings reuse the result." });
    } catch (error) {
      setRunState(controller.signal.aborted ? "idle" : "error");
      if (!controller.signal.aborted) setNotice({ tone: "error", title: "Preview could not complete.", detail: ` ${error instanceof Error ? error.message : String(error)}` });
    } finally { busyRef.current = false; abortController.current = undefined; }
  }, [activeImage, executeImage, settings]);

  const processJob = useCallback(async (initial: AnalysisJob) => {
    if (busyRef.current || !repository.current) return;
    busyRef.current = true; setShowingPreview(false); setRunState("preparing");
    const repo = repository.current;
    const queue = new DurableQueueRunner({
      persist: (job) => repo.putJob(job),
      changed: (job) => setJobs((current) => [job, ...current.filter((item) => item.id !== job.id)]),
      process: async (item, frozen, signal) => {
        const image = imageSnapshot.current.find((candidate) => candidate.id === item.imageId);
        if (!image) throw new Error("Image is no longer in the library.");
        if (image.sourceSha256 !== item.sourceSha256) throw new Error("Source identity changed since this job was created.");
        const snapshot = { ...frozen, calibration: item.calibration };
        const key = previewKey(item.sourceSha256, snapshot);
        const cached = await repo.getPreview(image.id);
        const reused = cached?.key === key;
        const analysis = reused ? cached.analysis : await executeImage(image, snapshot, signal);
        if (signal.aborted) throw new DOMException("Cancelled", "AbortError");
        await saveResult(image.id, { ...analysis, workflow: { ...analysis.workflow, jobId: initial.id, previewKey: key, reusedPreview: reused } });
        return { reusedPreview: reused };
      },
    });
    runner.current = queue;
    try {
      const finished = await queue.run(initial);
      setRunState(finished.state === "failed" ? "error" : "complete");
      setNotice({ tone: finished.state === "failed" ? "warning" : "success", title: `${finished.items.filter((item) => item.state === "complete").length} of ${finished.items.length} images completed.`, detail: finished.state === "complete" ? " Results are saved in this browser. Open Review to inspect individual objects." : " Remaining images and their settings are saved. Open Processing to resume or retry." });
      if (activeId) await refreshVariants(activeId);
    } catch (error) {
      setRunState("error"); setNotice({ tone: "error", title: "Processing stopped safely.", detail: ` ${error instanceof Error ? error.message : String(error)} Saved jobs recover paused after reload.` });
    } finally { busyRef.current = false; runner.current = undefined; }
  }, [activeId, executeImage, refreshVariants, saveResult]);

  const processImages = (all: boolean) => {
    if (!activeImage || busyRef.current) return;
    const selected = all ? images : [activeImage];
    const now = new Date().toISOString();
    const job: AnalysisJob = { id: `job-${crypto.randomUUID()}`, createdAt: now, updatedAt: now, state: "paused", settings: snapshotFor(settings, activeImage), items: selected.map((image) => ({ imageId: image.id, fileName: image.fileName, sourceSha256: image.sourceSha256 ?? "", calibration: calibrationForImage(image), state: "pending" })) };
    void processJob(job);
  };

  const saveVariant = async () => {
    if (!activeImage?.analysis || !repository.current || busy) return;
    const name = `Saved mask · ${new Date().toLocaleString()}`;
    await repository.current.putVariant({ id: crypto.randomUUID(), imageId: activeImage.id, name, createdAt: new Date().toISOString(), analysis: activeImage.analysis });
    await refreshVariants(activeImage.id);
  };
  const applyVariant = async () => {
    if (!alternative || !activeImage || busy) return;
    await saveResult(activeImage.id, restoreVariant(alternative, calibrationForImage(activeImage)));
    setShowingPreview(false); setAlternativeId(undefined); await refreshVariants(activeImage.id);
    setNotice({ tone: "success", title: "Alternative mask restored.", detail: " The previous mask remains saved; original run settings and the current measurement calibration are retained." });
  };

  const cancel = useCallback(() => {
    runner.current?.cancel(); abortController.current?.abort();
    workerClient.current?.dispose(); workerClient.current = undefined;
    setNotice({ tone: "info", title: "Cancelling current analysis.", detail: " Previous results remain saved; a processing job pauses for explicit resume." });
  }, []);

  const exportResults = useCallback(() => {
    if (!activeImage?.cells.length) { setNotice({ tone: "info", title: "Nothing to export yet.", detail: " Run analysis or add manual objects first." }); return; }
    setInspectorOpen(false); setExportOpen(true);
  }, [activeImage]);

  const tools: EditTool[] = ["inspect", "add", "remove", "resize", "merge", "split"];
  const keyActions = { disabled: welcomeOpen, route, modalOpen: helpOpen || exportOpen || inspectorOpen, hasImage: Boolean(activeImage?.sourceLoaded), busy, closeDialog: () => { setHelpOpen(false); setExportOpen(false); setInspectorOpen(false); }, undo, redo, canUndo: history.length > 0, canRedo: redoHistory.length > 0, importImages, importFolder, navigate: setRoute, run: () => { if (!readyModels.has(settings.modelId)) return; if (showingPreview && matchingPreview) processImages(processScope === "all"); else void run(); }, cancel, exportResults, setTool: (index: number) => setTool(tools[index] ?? "inspect"), toggleTheme, showHelp: () => setHelpOpen(true) };
  useKeyboard(keyActions);

  const openImage = async (id: string) => {
    if (busyRef.current) return;
    const current = images.find((image) => image.id === id);
    if (current && !current.sourceLoaded && repository.current) {
      try {
        const [source, metadata, analysis] = await Promise.all([
          repository.current.getSource(id),
          repository.current.getWorkspaceImage(id),
          current.analysisId ? repository.current.getAnalysis(current.analysisId) : Promise.resolve(null),
        ]);
        if (source && metadata) {
          const loaded = await workspaceFromStored(source.blob, metadata, analysis ?? undefined, current.thumbnailUrl);
          recentSourceIds.current = [id, ...recentSourceIds.current.filter((item) => item !== id)].slice(0, MAX_LOADED_SOURCES);
          setImages((items) => enforceLoadedSourceLimit(items.map((image) => image.id === id ? loaded : image), recentSourceIds.current));
        }
      } catch (error) {
        setNotice({ tone: "error", title: "Image could not be opened.", detail: ` ${error instanceof Error ? error.message : String(error)}` });
        return;
      }
    } else if (current?.sourceLoaded) {
      recentSourceIds.current = [id, ...recentSourceIds.current.filter((item) => item !== id)].slice(0, MAX_LOADED_SOURCES);
      setImages((items) => enforceLoadedSourceLimit(items, recentSourceIds.current));
    }
    setActiveId(id);
    setRoute("workspace");
    setHistory([]);
    setRedoHistory([]);
    setSelectedCellId(undefined);
  };
  const removeImage = (id: string) => {
    if (busyRef.current) return;
    const removed = images.find((image) => image.id === id);
    if (removed) { releaseImage(removed); void repository.current?.deleteSource(id); void repository.current?.deleteWorkspaceImage(id); if (removed.analysisId) void repository.current?.deleteAnalysis(removed.analysisId); }
    const remaining = images.filter((image) => image.id !== id);
    setImages(remaining);
    if (id === activeId) setActiveId(remaining[0]?.id);
  };
  const updateCondition = (id: string, condition: string) => {
    setImages((items) => items.map((image) => image.id === id ? { ...image, condition } : image));
    const changed = images.find((image) => image.id === id);
    if (changed) void repository.current?.putWorkspaceImage(workspaceMetadata({ ...changed, condition }));
    const grouped = images.filter((image) => (image.id === id ? condition : image.condition) === condition).flatMap((image) => image.analysis ? [image.analysis] : []);
    if (grouped.length) void repository.current?.putBatch({ id: `condition:${condition}`, name: condition, condition, analyses: grouped });
  };
  const updateReviewCell = async (imageId: string, cellId: string, action: "accept" | "reject" | "resize") => {
    const current = images.find((image) => image.id === imageId);
    if (!current) return;
    const storedAnalysis = !current.analysis && current.analysisId ? await repository.current?.getAnalysis(current.analysisId) : null;
    const hydrated = storedAnalysis ? { ...current, cells: storedAnalysis.cells.map(toWorkspaceCell), analysis: storedAnalysis } : current;
    let updated: WorkspaceImage;
    if (action === "accept") {
      const cells = hydrated.cells.map((cell) => cell.id === cellId ? { ...cell, reviewed: true } : cell);
      const analysis = hydrated.analysis ? { ...hydrated.analysis, cells: hydrated.analysis.cells.map((cell) => cell.id === cellId ? { ...cell, reviewed: true } : cell) } : undefined;
      updated = { ...hydrated, cells, analysis };
    } else {
      const operationId = `review-${action}-${crypto.randomUUID()}`;
      updated = applyEdit(hydrated, action === "reject"
        ? { id: operationId, appliedAt: new Date().toISOString(), kind: "remove", cellIds: [cellId] }
        : { id: operationId, appliedAt: new Date().toISOString(), kind: "resize", cellId, diameterUm: settings.diameterUm || 30 });
    }
    if (updated.analysis) await repository.current?.putAnalysis(updated.analysis);
    await repository.current?.putWorkspaceImage(workspaceMetadata(updated));
    const compact = updated.sourceLoaded ? updated : { ...updated, cells: updated.cells.map(cellSummary), analysis: undefined };
    setImages((items) => items.map((image) => image.id === imageId ? compact : image));
  };
  const selectModelFile = (modelId: AnalysisSettings["modelId"] = settings.modelId) => { pendingModelId.current = modelId; modelInput.current?.click(); };
  const onModelFile = async (files: FileList | null) => {
    const file = files?.[0];
    if (!file) return;
    if (pendingModelId.current === "classical") return;
    const manifest = getModelManifest(pendingModelId.current);
    try {
      if (manifest.artifact.availability !== "ready" || manifest.artifact.byteLength <= 0) throw new Error("this manifest is buildRequired; release packaging must pin byte length and digest first");
      const bytes = await file.arrayBuffer();
      if (bytes.byteLength !== manifest.artifact.byteLength) throw new Error(`artifact length mismatch: expected ${manifest.artifact.byteLength}, received ${bytes.byteLength}`);
      await verifySha256(manifest.id, bytes, manifest.artifact.sha256);
      const key = `${manifest.id}@${manifest.manifestVersion}:${manifest.artifact.sha256}`;
      await repository.current?.modelArtifactCache.put(key, bytes);
      setCachedModels((current) => new Set([...current, manifest.id]));
      setNotice({ tone: "success", title: `${manifest.displayName} verified.`, detail: " The exact artifact is cached only on this device." });
    } catch (error) {
      setNotice({ tone: "warning", title: "Model artifact rejected.", detail: ` ${error instanceof Error ? error.message : String(error)} No substitute was selected.` });
    } finally { if (modelInput.current) modelInput.current.value = ""; }
  };

  const openWorkspace = () => {
    try { localStorage.setItem("cellcounter-welcome-dismissed", "1"); } catch { /* The current visit can still continue. */ }
    setWelcomeOpen(false);
  };
  const reloadForUpdate = async () => {
    if (!pendingUpdate || busyRef.current || updating) return;
    setUpdating(true);
    try {
      flushPendingMetadata();
      if (images.length && !repository.current) throw new Error("Local storage is unavailable. Export your work before reloading.");
      await Promise.all(images.map((image) => repository.current!.putWorkspaceImage(workspaceMetadata(image))));
      await pendingUpdate();
    } catch (cause) {
      setNotice({ tone: "error", title: "The update could not be applied.", detail: ` ${cause instanceof Error ? cause.message : String(cause)}` });
    } finally { setUpdating(false); }
  };
  if (welcomeOpen) return <Suspense fallback={<main className="welcome-loading"><h1>CellCounter</h1><p>Preparing the introduction. Your workspace is ready to use.</p><button className="run-button" onClick={openWorkspace}>Open workspace</button></main>}><WelcomeScene onOpen={openWorkspace} /></Suspense>;

  return (
    <div className={`app-shell ${navCollapsed ? "nav-collapsed" : ""} ${route === "workspace" && activeImage ? "with-inspector" : ""}`} onDragOver={(event) => event.preventDefault()} onDrop={(event) => { event.preventDefault(); void onFiles(event.dataTransfer.files); }}>
      <TopBar theme={theme} toggleTheme={toggleTheme} onHelp={() => setRoute("help")} projectName="Local study" />
      <Rail active={route} onChange={(next) => { setRoute(next); setInspectorOpen(false); }} collapsed={navCollapsed} onCollapse={() => setNavCollapsed((value) => !value)} />
      <input ref={fileInput} className="sr-only" type="file" accept="image/png,image/jpeg,image/webp,image/bmp,image/tiff,.png,.jpg,.jpeg,.webp,.bmp,.tif,.tiff,.ome.tif,.ome.tiff" multiple onChange={(event) => void onFiles(event.target.files)} />
      <input ref={(element) => { folderInput.current = element; element?.setAttribute("webkitdirectory", ""); }} className="sr-only" type="file" accept="image/png,image/jpeg,image/webp,image/bmp,image/tiff,.png,.jpg,.jpeg,.webp,.bmp,.tif,.tiff,.ome.tif,.ome.tiff" multiple onChange={(event) => void onFiles(event.target.files)} />
      <input ref={modelInput} className="sr-only" type="file" accept=".onnx,application/octet-stream" onChange={(event) => void onModelFile(event.target.files)} />
      {route === "workspace" && <>
        <main className="workspace">
          <WorkspaceToolbar scope={processScope} onScopeChange={setProcessScope} image={activeImage} imageCount={images.length} runState={runState} previewCount={preview?.analysis.cells.length} previewMatches={matchingPreview} showingPreview={showingPreview} modelReady={readyModels.has(settings.modelId)} onImport={importImages} onRun={() => void run()} onProcess={processImages} onCancel={cancel} onInspector={() => setInspectorOpen(true)} />
          <div className="viewer-shell">
            {activeImage && <div className="viewer-toolbar"><EditDock active={showingPreview || busy ? "inspect" : tool} readOnly={showingPreview || busy} onChange={(next) => { setTool(next); setMergeCellId(undefined); }} canUndo={!busy && !showingPreview && history.length > 0} onUndo={undo} canRedo={!busy && !showingPreview && redoHistory.length > 0} onRedo={redo} /><div className="result-switch" role="group" aria-label="Displayed analysis"><button aria-pressed={!showingPreview} onClick={() => setShowingPreview(false)}>{activeImage.analysis ? "Saved result" : "Source"}</button><button disabled={!preview} aria-pressed={showingPreview} onClick={() => setShowingPreview(true)}>Preview</button></div></div>}
            <ImageStage image={stageImage} alternativeCells={alternative?.analysis.cells.map(toWorkspaceCell)} tool={showingPreview || busy ? "inspect" : tool} selectedCellId={selectedCellId} onCellPointer={onStagePointer} onRoi={addRoi} onImport={importImages} />
          </div>
          {activeImage && <LinkedMeasurements calibrationVerified={Boolean(activeImage.calibrationSource && activeImage.calibrationSource !== "default")} key={activeId} hasLearnedConfidence={displayAnalysis?.model.id !== "classical"} cells={showingPreview ? stageImage?.cells ?? [] : visibleCells} selectedId={selectedCellId} onSelect={setSelectedCellId} />}
          {images.length > 0 && <Filmstrip images={images} activeId={activeId} onSelect={openImage} onImport={importImages} />}
        </main>
        {activeImage && <Inspector image={activeImage} selectedCell={stageImage?.cells.find((cell) => cell.id === selectedCellId)} showingPreview={showingPreview} mobileOpen={inspectorOpen} onClose={() => setInspectorOpen(false)} tool={tool} onTool={setTool} onMetadata={updateImageMetadata} truthMetrics={truthMetrics} onClearValidation={clearValidation} settings={settings} onSettings={(next) => { if (busyRef.current) return; setSettings(next); if (next.pxPerUm !== settings.pxPerUm) updateActive((image) => { const updated = updateCalibration(image, next.pxPerUm, "manual"); queueMetadataPersistence(updated); return updated; }); }} count={showingPreview ? stageImage?.cells.length ?? 0 : visibleCells.length} meanDiameter={showingPreview ? (stageImage?.cells.reduce((sum, cell) => sum + cell.diameterUm, 0) ?? 0) / (stageImage?.cells.length || 1) : meanDiameter} onModelFile={() => selectModelFile()} onExport={exportResults} modelReady={readyModels.has(settings.modelId)}>
          {activeImage && <details className="mask-variants"><summary>Mask variants and recorded run</summary><p>{activeImage.analysis ? `${activeImage.analysis.model.displayName} · ${new Date(activeImage.analysis.ranAt).toLocaleString()} · source channel ${activeImage.analysis.parameters.sourceChannel === -1 ? "luminance" : (activeImage.analysis.parameters.sourceChannel ?? 0) + 1} · projection ${activeImage.analysis.parameters.projection ?? "unknown"} · ${activeImage.analysis.cells.length} detected · ${visibleCells.length} included after ROI filters` : "Original run settings are unknown until this image is processed."}</p><div className="processing-actions"><button disabled={!activeImage.analysis || busy} onClick={() => void saveVariant()}>Save current mask</button><label>Alternative <select value={alternativeId ?? ""} onChange={(event) => setAlternativeId(event.target.value || undefined)}><option value="">Choose a saved mask</option>{variants.map((variant) => <option key={variant.id} value={variant.id}>{variant.name} · {variant.analysis.cells.length} objects</option>)}</select></label><button disabled={!alternative || busy} onClick={() => void applyVariant()}>Apply alternative</button></div>{alternative && <p>{variantComparison ? `${variantComparison.added} added · ${variantComparison.removed} removed · ${variantComparison.changed} changed · ${variantComparison.unchanged} unchanged. ` : ""}Orange contours show the alternative using the same pan and zoom. Applying preserves the current mask and original run metadata.</p>}{activeImage.analysis && <details><summary>Recorded settings</summary><pre>{JSON.stringify({ model: activeImage.analysis.model, parameters: activeImage.analysis.parameters, runCalibration: activeImage.analysis.workflow?.runCalibration ?? activeImage.analysis.calibration, currentCalibration: calibrationForImage(activeImage), job: activeImage.analysis.workflow }, null, 2)}</pre></details>}</details>}
        </Inspector>}
      </>}
      {route === "processing" && <ProcessingPanel image={activeImage} images={images} busy={busy} modelReady={readyModels.has(settings.modelId)} jobs={jobs} onProcess={processImages} onResume={(job, retry) => void processJob(retry ? retryJob(job) : recoverJob(job))} onPause={() => { runner.current?.pause(); setNotice({ tone: "info", title: "Pause requested.", detail: " The current image will finish and save before processing pauses." }); }} onCancel={cancel} onReview={() => setRoute("review")} onAnalyze={() => setRoute("workspace")} />}
      {route === "help" && <HelpView onWelcome={() => setWelcomeOpen(true)} onShortcuts={() => setHelpOpen(true)} onCapabilities={() => setRoute("capabilities")} />}
      {route === "library" && <LibraryView images={images} activeId={activeId} onOpen={openImage} onRemove={removeImage} onCondition={updateCondition} onImport={importImages} onImportFolder={importFolder} />}
      {route === "review" && <ReviewView images={images} onOpen={(imageId, cellId) => { void openImage(imageId).then(() => setSelectedCellId(cellId)); }} onAccept={(imageId, cellId) => updateReviewCell(imageId, cellId, "accept")} onReject={(imageId, cellId) => updateReviewCell(imageId, cellId, "reject")} onResize={(imageId, cellId) => updateReviewCell(imageId, cellId, "resize")} />}
      {route === "lab" && <AnalysisLabView image={activeImage} images={images} settings={settings} onSettings={(next) => { if (busyRef.current) return; setSettings(next); if (next.pxPerUm !== settings.pxPerUm) updateActive((image) => { const updated = updateCalibration(image, next.pxPerUm, "protocol"); queueMetadataPersistence(updated); return updated; }); }} onWorkspace={() => setRoute("workspace")} />}
      {route === "compare" && <CompareView images={images} onLibrary={() => setRoute("library")} />}
      {route === "models" && <ModelsView readyModels={readyModels} onModelFile={selectModelFile} />}
      {route === "capabilities" && <CapabilitiesView />}
      {route === "settings" && <SettingsView theme={theme} onTheme={toggleTheme} onHelp={() => setHelpOpen(true)} />}
      {pendingUpdate && <UpdateNotice busy={busy || updating} onReload={() => void reloadForUpdate()} />}
      {notice && <NoticeBar notice={notice} onClose={() => setNotice(undefined)} />}
      {exportOpen && activeImage && <ExportDialog image={activeImage.analysis?.displayPlane ? { ...activeImage, file: new File([activeImage.analysis.displayPlane], activeImage.fileName, { type: "image/png" }) } : activeImage} onClose={() => setExportOpen(false)} />}
      <ShortcutDialog open={helpOpen} onClose={() => setHelpOpen(false)} />
    </div>
  );
}
