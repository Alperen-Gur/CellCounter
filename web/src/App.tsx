import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore, type SetStateAction } from "react";
import { decodeImageFiles, releaseImage } from "./app/imageFiles";
import { workspaceMetadata } from "./app/imageRecords";
import { ReviewedDatasetPanel } from "./components/ReviewedDatasetPanel";
import { DebouncedByIdWriter } from "./app/debouncedMetadata";
import { filterCellsByRois } from "./app/roi";
import { analysisIdentities, calibrationForImage } from "./app/provenance";
import type { EditTool, Notice, RouteId, RunState, WorkspaceCell, WorkspaceImage } from "./app/types";
import { ProcessingPanel } from "./components/ProcessingPanel";
import { LinkedMeasurements } from "./components/LinkedMeasurements";
import { DurableQueueRunner, compareMaskVariants, previewKey, recoverJob, retryJob, restoreVariant, type AnalysisJob, type AnalysisPreview, type MaskVariant, type RunSnapshot } from "./app/workflow";
import { assertLearnedSourceSettings } from "./models/WebGpuInference";
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
import { runAdvanced } from "./workers/AdvancedWorkerClient";
import { AdvancedPanel } from "./components/AdvancedPanel";
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

const MicroscopyView = lazy(() => import("./views/MicroscopyView").then((module) => ({ default: module.MicroscopyView })));
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

export interface HistoryEntry { cells: WorkspaceCell[]; analysis?: ImageAnalysis; pxPerUm: number; groundTruth: WorkspaceImage["groundTruth"]; rois: WorkspaceImage["rois"]; }
const MAX_LOADED_SOURCES = 2;

export function historySnapshot(image: WorkspaceImage): HistoryEntry {
  return { cells: image.cells, analysis: image.analysis, pxPerUm: image.pxPerUm, groundTruth: image.groundTruth, rois: image.rois };
}
function restoreHistory(image: WorkspaceImage, entry: HistoryEntry): WorkspaceImage {
  const analysis = entry.analysis ? restoreVariant({ id: "history", imageId: image.id, name: "History", createdAt: "", analysis: entry.analysis }, calibrationForImage(image)) : undefined;
  const ratio = entry.pxPerUm / image.pxPerUm;
  const cells = analysis ? analysis.cells.map(toWorkspaceCell) : entry.cells.map((cell) => ({ ...cell, diameterUm: cell.diameterPx / image.pxPerUm, areaUm2: cell.areaPx2 === undefined ? cell.areaUm2 === undefined ? undefined : cell.areaUm2 * ratio ** 2 : cell.areaPx2 / image.pxPerUm ** 2, perimeterUm: cell.perimeterPx === undefined ? cell.perimeterUm === undefined ? undefined : cell.perimeterUm * ratio : cell.perimeterPx / image.pxPerUm }));
  return { ...image, cells, analysis, groundTruth: entry.groundTruth, rois: entry.rois };
}
function sameAnalysisPlane(a: ImageAnalysis, b: ImageAnalysis): boolean {
  const selection = (value: ImageAnalysis) => [value.parameters.sourceTime ?? 0, value.parameters.sourceZ ?? 0, value.parameters.sourceChannel ?? -1, value.parameters.projection ?? "first", value.parameters.channels];
  return a.image.id === b.image.id && a.image.widthPx === b.image.widthPx && a.image.heightPx === b.image.heightPx && a.originalSource?.sha256 === b.originalSource?.sha256 && JSON.stringify(selection(a)) === JSON.stringify(selection(b));
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
    areaUm2: cell.areaUm2, areaPx2: cell.areaPx2, perimeterUm: cell.perimeterUm, perimeterPx: cell.perimeterPx, circularity: cell.circularity, aspectRatio: cell.aspectRatio, solidity: cell.solidity, eccentricity: cell.eccentricity, edgeTouching: cell.edgeTouching, sizeClass: cell.sizeClass,
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
  return images.map((image) => image.sourceLoaded && image.sourcePersisted !== false && !keep.has(image.id) ? demoteWorkspaceImage(image) : image);
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
    sourceChannel: settings.sourceChannel ?? -1, sourceTime: settings.sourceTime ?? 0, sourceZ: settings.sourceZ ?? 0, projection: settings.projection ?? "first", preprocessingPreset: settings.preprocessingPreset ?? "none", taskPreset: settings.taskPreset ?? "countCells",
    thresholdMethod: settings.thresholdMethod ?? "otsu", manualThreshold: settings.manualThreshold ?? .5,
    invert: settings.invert ?? false, minimumAreaPx: settings.minimumAreaPx ?? 9,
    backgroundSubtract: settings.backgroundSubtract,
    rollingBallRadiusPx: settings.rollingBallRadiusPx ?? 50,
    watershedSplit: settings.watershedSplit,
    watershedMinDistanceUm: settings.watershedMinDistanceUm ?? 8,
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
    editRevision: metadata.editRevision, provenance: metadata.provenance, sourceSha256: metadata.sourceSha256,
    sourceByteLength: metadata.sourceByteLength,
    sourceMediaType: metadata.sourceMediaType,
    calibrationSource: metadata.calibrationSource,
    calibrationConfidence: metadata.calibrationConfidence,
    sourceDimensions: metadata.sourceDimensions, channelNames: metadata.channelNames ? [...metadata.channelNames] : undefined, planeCount: metadata.planeCount,
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
    editRevision: metadata.editRevision, provenance: metadata.provenance, sourceSha256: metadata.sourceSha256,
    sourceByteLength: metadata.sourceByteLength,
    sourceMediaType: metadata.sourceMediaType,
    calibrationSource: metadata.calibrationSource,
    calibrationConfidence: metadata.calibrationConfidence,
    sourceDimensions: metadata.sourceDimensions, channelNames: metadata.channelNames ? [...metadata.channelNames] : undefined, planeCount: metadata.planeCount,
    samplesPerPixel: metadata.samplesPerPixel,
    bitsPerSample: metadata.bitsPerSample,
    groundTruth: [...(metadata.groundTruth ?? [])],
    rois: [...(metadata.rois ?? [])],
    note: metadata.note ?? "",
    reviewConfidence: metadata.reviewConfidence ?? "high",
  };
}


export default function App() {
  const [welcomeOpen, setWelcomeOpen] = useState(false);
  const pendingUpdate = useSyncExternalStore(subscribeUpdates, getPendingUpdate);
  const [updating, setUpdating] = useState(false);
  const [route, setRoute] = useState<RouteId>("workspace");
  const [processScope, setProcessScope] = useState<"image" | "all">("image");
  const [navCollapsed, setNavCollapsed] = useState(false);
  const [inspectorOpen, setInspectorOpen] = useState(false);
  const [images, setImageState] = useState<WorkspaceImage[]>([]);
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
  const [sourcePlanePreview, setSourcePlanePreview] = useState<{ imageId: string; blob: Blob }>();
  const [reviewUndo, setReviewUndo] = useState<WorkspaceImage>();
  const [preparedUrl, setPreparedUrl] = useState<{ imageId: string; blob: Blob; url: string }>();
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
  // Async operations read the same revision that event handlers publish, even
  // before React renders a batched update. Evaluate each update exactly once.
  const setImages = useCallback((update: SetStateAction<WorkspaceImage[]>) => {
    const next = typeof update === "function" ? update(imageSnapshot.current) : update;
    imageSnapshot.current = next;
    setImageState(next);
  }, []);
  const recentSourceIds = useRef<string[]>([]);
  const removedImageIds = useRef(new Set<string>());
  const importing = useRef(false);
  const metadataWriter = useRef<DebouncedByIdWriter<WorkspaceImage> | undefined>(undefined);
  metadataWriter.current ??= new DebouncedByIdWriter(350, (image) => {
    if (removedImageIds.current.has(image.id)) return;
    return repository.current?.putWorkspaceResult(workspaceMetadata(image), image.analysis).catch((error: unknown) => {
      setNotice({ tone: "error", title: "Image changes could not be saved.", detail: ` ${error instanceof Error ? error.message : String(error)}` });
    });
  });
  const { theme, toggleTheme } = useTheme();

  const readyModels = useMemo(() => new Set([
    ...MODEL_CATALOG.filter((manifest) => (manifest.artifact.availability as string) === "ready").map((manifest) => manifest.id),
    ...cachedModels, "classical",
  ]), [cachedModels]);
  const busy = runState === "running" || runState === "preparing";
  const activeImage = images.find((image) => image.id === activeId);
  const matchingPreview = Boolean(activeImage?.sourceSha256 && preview?.imageId === activeImage.id && preview.key === previewKey(activeImage.sourceSha256, snapshotFor(settings, activeImage)));
  const displayAnalysis = showingPreview && preview?.imageId === activeImage?.id ? preview?.analysis : activeImage?.analysis;
  const preparedBlob = sourcePlanePreview && sourcePlanePreview.imageId === activeId ? sourcePlanePreview.blob : displayAnalysis?.displayPlane;
  const currentPreparedUrl = preparedUrl && preparedUrl.imageId === activeId && preparedUrl.blob === preparedBlob ? preparedUrl.url : undefined;
  const stageImage = activeImage && (!preparedBlob || currentPreparedUrl) ? { ...activeImage, objectUrl: currentPreparedUrl ?? activeImage.objectUrl, cells: sourcePlanePreview?.imageId === activeImage.id ? [] : showingPreview && preview?.imageId === activeImage.id ? preview.analysis.cells.map(toWorkspaceCell) : activeImage.cells } : undefined;
  const alternative = variants.find((variant) => variant.id === alternativeId);
  const variantResult = useMemo(() => {
    if (!activeImage?.analysis || !alternative) return {};
    if (!sameAnalysisPlane(activeImage.analysis, alternative.analysis)) return { error: "These masks use different source planes, so object comparison is unavailable." };
    try { return { comparison: compareMaskVariants(activeImage.analysis, alternative.analysis) }; }
    catch (cause) { return { error: cause instanceof Error ? cause.message : String(cause) }; }
  }, [activeImage?.analysis, alternative]);
  const variantComparison = variantResult.comparison;
  const visibleCells = useMemo(() => activeImage ? filterCellsByRois(activeImage) : [], [activeImage]);
  const meanDiameter = visibleCells.length ? visibleCells.reduce((sum, cell) => sum + cell.diameterUm, 0) / visibleCells.length : 0;
  const truthResult = useMemo(() => {
    if (!activeImage?.groundTruth.length) return {};
    try { return { metrics: matchGroundTruth(activeImage.groundTruth, activeImage.cells.map((cell) => ({ id: cell.id, x: cell.cx, y: cell.cy })), 10 * activeImage.pxPerUm) }; }
    catch (cause) { return { error: cause instanceof Error ? cause.message : String(cause) }; }
  }, [activeImage?.groundTruth, activeImage?.cells, activeImage?.pxPerUm]);

  useEffect(() => { try { localStorage.setItem("cellcounter-setup-v1", JSON.stringify(settings)); } catch { /* Analysis jobs still record exact settings in IndexedDB. */ } }, [settings]);
  useEffect(() => {
    const blob = preparedBlob;
    if (!blob || !activeId) { setPreparedUrl(undefined); return; }
    const url = URL.createObjectURL(blob); setPreparedUrl({ imageId: activeId, blob, url });
    return () => URL.revokeObjectURL(url);
  }, [preparedBlob, activeId]);

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
    if (!files?.length || busyRef.current || importing.current) return;
    importing.current = true;
    try {
      const decoded = await decodeImageFiles(files);
      const knownDigests = new Set(imageSnapshot.current.filter((image) => !removedImageIds.current.has(image.id)).map((image) => image.sourceSha256).filter((digest): digest is string => Boolean(digest)));
      const accepted: WorkspaceImage[] = [];
      let duplicateCount = 0;
      for (const image of decoded.images) {
        if (image.sourceSha256 && knownDigests.has(image.sourceSha256)) { duplicateCount += 1; releaseImage(image); }
        else { accepted.push({ ...image, sourcePersisted: false }); if (image.sourceSha256) knownDigests.add(image.sourceSha256); }
      }
      if (accepted.length) {
        // Publish only after initial writes settle so edits/deletion cannot race them.
        setNotice({ tone: "info", title: "Saving imported images on this device…" });
        let stored = 0;
        try {
          const opened = repository.current;
          if (!opened) throw new Error("Local storage is unavailable. Keep this page open or export your work before leaving.");
          for (const image of accepted) {
            const sourceFile = image.originalFile ?? image.file;
            await opened.putSource(createBrowserImageSource(sourceFile, { id: image.id, fileName: image.fileName, lastModified: sourceFile.lastModified }));
            await opened.putWorkspaceImage(workspaceMetadata(image));
            stored += 1;
          }
          setNotice({ tone: "success", title: `${accepted.length} image${accepted.length === 1 ? "" : "s"} imported.`, detail: `${duplicateCount ? ` ${duplicateCount} exact duplicate${duplicateCount === 1 ? " was" : "s were"} skipped.` : ""} Stored privately on this device.` });
        } catch (error) {
          setNotice({ tone: "warning", title: `${accepted.length} images opened; ${stored} persisted.`, detail: ` Local storage stopped safely: ${error instanceof Error ? error.message : String(error)}` });
        }
        recentSourceIds.current = [accepted[0].id, ...recentSourceIds.current.filter((id) => id !== accepted[0].id)].slice(0, MAX_LOADED_SOURCES);
        const openedImages = accepted.map((image, index) => ({ ...image, sourcePersisted: index < stored }));
        setImages((current) => enforceLoadedSourceLimit([...current, ...openedImages], recentSourceIds.current));
        setActiveId(accepted[0].id);
        setRoute("workspace");
      }
      else if (duplicateCount) setNotice({ tone: "info", title: "No new images imported.", detail: ` ${duplicateCount} exact duplicate${duplicateCount === 1 ? " was" : "s were"} skipped by SHA-256.` });
      if (decoded.errors.length) setNotice({ tone: "warning", title: "Some files were skipped.", detail: ` ${decoded.errors.join(" ")}` });
    } finally {
      importing.current = false;
      if (fileInput.current) fileInput.current.value = "";
      if (folderInput.current) folderInput.current.value = "";
    }
  };

  const updateActive = useCallback((update: (image: WorkspaceImage) => WorkspaceImage, flush = false) => {
    if (!activeId || removedImageIds.current.has(activeId)) return;
    setImages((current) => current.map((image) => {
      if (image.id !== activeId || removedImageIds.current.has(image.id)) return image;
      const updated = { ...update(image), editRevision: (image.editRevision ?? 0) + 1 };
      queueMetadataPersistence(updated);
      if (flush) metadataWriter.current?.flush(updated.id);
      return updated;
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
    return { ...image, cells: corrected.cells.map(toWorkspaceCell), analysis: nextAnalysis };
  };

  const onStagePointer = (x: number, y: number) => {
    if (!activeImage) return;
    if (sourcePlanePreview?.imageId === activeImage.id) return;
    if (showingPreview || busy) { setSelectedCellId(nearestCell(stageImage?.cells ?? [], x, y)?.id); return; }
    const nearest = nearestCell(activeImage.cells, x, y);
    if (tool === "inspect") { setSelectedCellId(nearest?.id); return; }
    if (tool === "prompt-point") { void refinePrompt({ x, y }); return; }
    if (tool === "freehand" || tool === "prompt-box") return;
    if (tool === "ground-truth") {
      pushHistory(activeImage);
      updateActive((image) => {
        const updated = { ...image, groundTruth: [...image.groundTruth, { id: `truth-${crypto.randomUUID()}`, x, y, diameterPx: (settings.diameterUm || 30) * image.pxPerUm }] };
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
      return updated;
    });
  };

  const clearValidation = (target: "truth" | "rois") => {
    if (!activeImage) return;
    pushHistory(activeImage);
    updateActive((image) => {
      const updated = target === "truth" ? { ...image, groundTruth: [] } : { ...image, rois: [] };
      return updated;
    });
  };

  const updateCalibration = (image: WorkspaceImage, pxPerUm: number, source: "manual" | "protocol"): WorkspaceImage => {
    const calibration = { pxPerUm, source, confidence: "high" as const };
    const analysis = image.analysis ? restoreVariant({ id: "calibration", imageId: image.id, name: "Current", createdAt: "", analysis: image.analysis }, calibration) : undefined;
    const ratio = image.pxPerUm / pxPerUm;
    return { ...image, pxPerUm, calibrationSource: source, calibrationConfidence: "high", analysis, cells: analysis ? analysis.cells.map(toWorkspaceCell) : image.cells.map((cell) => ({ ...cell, diameterUm: cell.diameterPx / pxPerUm, areaUm2: cell.areaUm2 === undefined ? undefined : cell.areaUm2 * ratio * ratio })) };
  };

  const updateImageMetadata = (patch: Pick<WorkspaceImage, "note" | "reviewConfidence">) => {
    updateActive((image) => ({ ...image, ...patch }), patch.reviewConfidence !== activeImage?.reviewConfidence);
  };

  const undo = () => {
    const previous = history.at(-1);
    if (!previous || !activeImage) return;
    setRedoHistory((items) => [...items.slice(-49), historySnapshot(activeImage)]);
    updateActive((image) => {
      return restoreHistory(image, previous);
    });
    setHistory((items) => items.slice(0, -1));
  };

  const redo = () => {
    const next = redoHistory.at(-1);
    if (!next || !activeImage) return;
    setHistory((items) => [...items.slice(-49), historySnapshot(activeImage)]);
    updateActive((image) => {
      return restoreHistory(image, next);
    });
    setRedoHistory((items) => items.slice(0, -1));
  };

  const refreshVariants = useCallback(async (imageId: string) => {
    const saved = await repository.current?.listVariants(imageId);
    if (imageSnapshot.current.find((image) => image.id === imageId)) setVariants(saved ?? []);
  }, []);
  useEffect(() => {
    let disposed = false;
    setSourcePlanePreview(undefined); setPreview(undefined); setShowingPreview(false); setAlternativeId(undefined); setVariants([]);
    if (activeId && repository.current) void Promise.all([repository.current.getPreview(activeId), repository.current.listVariants(activeId)]).then(([savedPreview, savedVariants]) => { if (!disposed) { setPreview(savedPreview ?? undefined); setVariants(savedVariants); } });
    return () => { disposed = true; };
  }, [activeId]);

  const executeImage = useCallback(async (image: WorkspaceImage, frozen: RunSnapshot, signal: AbortSignal): Promise<ImageAnalysis> => {
    if (!repository.current) throw new Error("Local project storage is not ready.");
    const learned = frozen.parameters.modelId !== "classical";
    if (learned && getModelManifest(frozen.parameters.modelId).artifact.availability !== "ready") throw new Error(`${frozen.model.displayName} needs a validated browser artifact. Choose the built-in classical detector to run threshold segmentation.`);
    if (learned) assertLearnedSourceSettings(frozen.parameters);
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

  const assertCurrentImage = useCallback((expected: WorkspaceImage): WorkspaceImage => {
    const current = imageSnapshot.current.find((candidate) => candidate.id === expected.id);
    if (!current || removedImageIds.current.has(expected.id)) throw new Error("This image was removed from the library.");
    if ((current.editRevision ?? 0) !== (expected.editRevision ?? 0) || current.sourceSha256 !== expected.sourceSha256 || current.pxPerUm !== expected.pxPerUm || current.calibrationSource !== expected.calibrationSource || current.calibrationConfidence !== expected.calibrationConfidence) throw new Error("This image changed during processing. Its newer edits were preserved; retry against the current image.");
    return current;
  }, []);

  const saveResult = useCallback(async (expected: WorkspaceImage, analysis: ImageAnalysis) => {
    const imageId = expected.id;
    const repo = repository.current;
    if (!repo) throw new Error("Local storage is unavailable.");
    let image = assertCurrentImage(expected);
    metadataWriter.current?.flush(imageId);
    const previous = image.analysis ?? (image.analysisId ? await repo.getAnalysis(image.analysisId) : null);
    assertCurrentImage(expected);
    if (previous) await repo.putVariant({ id: crypto.randomUUID(), imageId, name: `Before processing · ${new Date().toLocaleString()}`, createdAt: new Date().toISOString(), analysis: previous });
    image = assertCurrentImage(expected);
    const updated = { ...image, editRevision: (image.editRevision ?? 0) + 1, width: analysis.image.widthPx, height: analysis.image.heightPx, cells: analysis.cells.map(toWorkspaceCell), modelId: analysis.model.id, analysisId: analysis.id, analysis };
    await repo.putWorkspaceResult(workspaceMetadata(updated, analysis.id), analysis, { revision: expected.editRevision ?? 0, sourceSha256: expected.sourceSha256 });
    try { assertCurrentImage(expected); }
    catch (cause) { metadataWriter.current?.flush(imageId); throw cause; }
    setImages((items) => items.map((item) => item.id === imageId ? { ...item, ...updated, analysis: item.sourceLoaded ? analysis : undefined, cells: item.sourceLoaded ? updated.cells : updated.cells.map(cellSummary) } : item));
  }, [assertCurrentImage, setImages]);

  const run = useCallback(async () => {
    if (!activeImage || busyRef.current || removedImageIds.current.has(activeImage.id)) return;
    setSourcePlanePreview(undefined); busyRef.current = true;
    const controller = new AbortController(); abortController.current = controller; setRunState("preparing");
    try {
      const frozen = snapshotFor(settings, activeImage);
      const key = previewKey(activeImage.sourceSha256 ?? "", frozen);
      const cached = await repository.current?.getPreview(activeImage.id);
      const analysis = cached?.key === key ? cached.analysis : await executeImage(activeImage, frozen, controller.signal);
      if (controller.signal.aborted) throw new DOMException("Cancelled", "AbortError");
      assertCurrentImage(activeImage);
      const next: AnalysisPreview = { id: activeImage.id, imageId: activeImage.id, key, analysis };
      if (!repository.current) throw new Error("Local preview storage is unavailable.");
      await repository.current.putPreview(next);
      assertCurrentImage(activeImage);
      setPreview(next); setShowingPreview(true); setRunState("complete");
      setNotice({ tone: "success", title: `${analysis.cells.length} objects in whole-image preview.`, detail: " Preview saved locally. Process this image or the batch to apply it; matching settings reuse the result." });
    } catch (error) {
      setRunState(controller.signal.aborted ? "idle" : "error");
      if (!controller.signal.aborted) setNotice({ tone: "error", title: "Preview could not complete.", detail: ` ${error instanceof Error ? error.message : String(error)}` });
    } finally { busyRef.current = false; abortController.current = undefined; }
  }, [activeImage, assertCurrentImage, executeImage, settings]);

  const processJob = useCallback(async (initial: AnalysisJob) => {
    if (busyRef.current || !repository.current) return;
    setSourcePlanePreview(undefined); busyRef.current = true; setShowingPreview(false); setRunState("preparing");
    const repo = repository.current;
    const queue = new DurableQueueRunner({
      persist: (job) => repo.putJob(job),
      changed: (job) => setJobs((current) => [job, ...current.filter((item) => item.id !== job.id)]),
      process: async (item, frozen, signal) => {
        const image = imageSnapshot.current.find((candidate) => candidate.id === item.imageId);
        if (!image || removedImageIds.current.has(image.id)) throw new Error("Image is no longer in the library.");
        if (image.sourceSha256 !== item.sourceSha256) throw new Error("Source identity changed since this job was created.");
        const calibration = calibrationForImage(image);
        if (calibration.pxPerUm !== item.calibration.pxPerUm || calibration.source !== item.calibration.source || calibration.confidence !== item.calibration.confidence) throw new Error("Calibration changed since this job was created. Create a new processing job against the current calibration.");
        const snapshot = { ...frozen, calibration: item.calibration };
        const key = previewKey(item.sourceSha256, snapshot);
        const cached = await repo.getPreview(image.id);
        const reused = cached?.key === key;
        const analysis = reused ? cached.analysis : await executeImage(image, snapshot, signal);
        if (signal.aborted) throw new DOMException("Cancelled", "AbortError");
        await saveResult(image, { ...analysis, workflow: { ...analysis.workflow, jobId: initial.id, previewKey: key, reusedPreview: reused } });
        return { reusedPreview: reused };
      },
    });
    runner.current = queue;
    try {
      const finished = await queue.run(initial);
      setRunState(finished.state === "failed" ? "error" : "complete");
      setNotice({ tone: finished.state === "failed" ? "warning" : "success", title: `${finished.items.filter((item) => item.state === "complete").length} of ${finished.items.length} images completed.`, detail: finished.state === "complete" ? " Results are saved in this browser. Open Review to inspect individual objects." : " Remaining images and their settings are saved. Open Processing to resume or retry." });
      if (activeId) await refreshVariants(activeId);
      if (finished.state === "complete" && initial.settings.parameters.taskPreset && ["markerPositive", "woundClosure"].includes(initial.settings.parameters.taskPreset)) setRoute("lab");
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
    if (!activeImage?.analysis || !repository.current || busyRef.current || removedImageIds.current.has(activeImage.id)) return;
    const name = `Saved mask · ${new Date().toLocaleString()}`;
    await repository.current.putVariant({ id: crypto.randomUUID(), imageId: activeImage.id, name, createdAt: new Date().toISOString(), analysis: activeImage.analysis });
    await refreshVariants(activeImage.id);
  };
  const applyVariant = async () => {
    if (!alternative || !activeImage || busyRef.current || removedImageIds.current.has(activeImage.id)) return;
    busyRef.current = true; setRunState("preparing");
    try {
      await saveResult(activeImage, restoreVariant(alternative, calibrationForImage(activeImage)));
      setShowingPreview(false); setAlternativeId(undefined); await refreshVariants(activeImage.id);
      setRunState("complete");
      setNotice({ tone: "success", title: "Alternative mask restored.", detail: " The previous mask remains saved; original run settings and the current measurement calibration are retained." });
    } catch (error) {
      setRunState("error");
      setNotice({ tone: "error", title: "The alternative mask could not be restored.", detail: ` ${error instanceof Error ? error.message : String(error)}` });
    } finally { busyRef.current = false; }
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

  const tools: EditTool[] = ["inspect", "add", "remove", "resize", "merge", "split", "freehand", "prompt-point", "prompt-box"];
  const keyActions = { disabled: welcomeOpen, route, modalOpen: helpOpen || exportOpen || inspectorOpen, hasImage: Boolean(activeImage?.sourceLoaded), busy, closeDialog: () => { setHelpOpen(false); setExportOpen(false); setInspectorOpen(false); }, undo, redo, canUndo: history.length > 0, canRedo: redoHistory.length > 0, importImages, importFolder, navigate: setRoute, run: () => { if (!readyModels.has(settings.modelId)) return; if (showingPreview && matchingPreview) processImages(processScope === "all"); else void run(); }, cancel, exportResults, setTool: (index: number) => setTool(tools[index] ?? "inspect"), toggleTheme, showHelp: () => setHelpOpen(true) };
  useKeyboard(keyActions);

  const openImage = async (id: string) => {
    if (busyRef.current || removedImageIds.current.has(id)) return;
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
          if (removedImageIds.current.has(id)) { releaseImage(loaded); return; }
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
    if (removedImageIds.current.has(id)) return;
    setActiveId(id);
    setRoute("workspace");
    setHistory([]);
    setRedoHistory([]);
    setSelectedCellId(undefined);
  };
  const removeImage = async (id: string) => {
    if (busyRef.current || removedImageIds.current.has(id)) return;
    const removed = images.find((image) => image.id === id);
    if (!removed) return;
    // A pending edit must not recreate the metadata row after deletion.
    removedImageIds.current.add(id);
    metadataWriter.current?.discard(id);
    try {
      await repository.current?.deleteImage(id);
      releaseImage(removed);
      setImages((current) => current.filter((image) => image.id !== id));
      setActiveId((current) => current === id ? imageSnapshot.current.find((image) => !removedImageIds.current.has(image.id))?.id : current);
      if (id === activeId) { setHistory([]); setRedoHistory([]); setSelectedCellId(undefined); }
    } catch (error) {
      removedImageIds.current.delete(id);
      queueMetadataPersistence(imageSnapshot.current.find((image) => image.id === id) ?? removed);
      setNotice({ tone: "error", title: "The image could not be removed.", detail: ` ${error instanceof Error ? error.message : String(error)}` });
    }
  };
  const updateCondition = (id: string, condition: string) => {
    if (removedImageIds.current.has(id)) return;
    setImages((items) => items.map((image) => {
      if (image.id !== id) return image;
      const changed = { ...image, condition, editRevision: (image.editRevision ?? 0) + 1 };
      queueMetadataPersistence(changed); return changed;
    }));
    const grouped = imageSnapshot.current.filter((image) => image.condition === condition).flatMap((image) => image.analysis ? [image.analysis] : []);
    if (grouped.length) void repository.current?.putBatch({ id: `condition:${condition}`, name: condition, condition, analyses: grouped });
  };
  const updateReviewCell = async (imageId: string, cellId: string, action: "accept" | "reject" | "resize") => {
    const current = images.find((image) => image.id === imageId);
    if (!current || removedImageIds.current.has(imageId)) return;
    const storedAnalysis = !current.analysis && current.analysisId ? await repository.current?.getAnalysis(current.analysisId) : null;
    if (removedImageIds.current.has(imageId)) return;
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
    updated = { ...updated, editRevision: (hydrated.editRevision ?? 0) + 1 };
    if (removedImageIds.current.has(imageId)) return;
    if (!repository.current) throw new Error("Local project storage is unavailable.");
    metadataWriter.current?.flush(imageId);
    await repository.current.putWorkspaceResult(workspaceMetadata(updated), updated.analysis, { revision: hydrated.editRevision ?? 0, sourceSha256: hydrated.sourceSha256 });
    setReviewUndo(hydrated);
    const compact = updated.sourceLoaded ? updated : { ...updated, cells: updated.cells.map(cellSummary), analysis: undefined };
    setImages((items) => items.map((image) => image.id === imageId ? compact : image));
  };
  const undoReviewDecision = async () => {
    if (!reviewUndo || removedImageIds.current.has(reviewUndo.id)) return;
    const repo = repository.current;
    if (!repo) throw new Error("Local project storage is unavailable.");
    metadataWriter.current?.discard(reviewUndo.id);
    const latest = imageSnapshot.current.find((image) => image.id === reviewUndo.id);
    if (!latest || latest.editRevision !== (reviewUndo.editRevision ?? 0) + 1) throw new Error("This image changed after the review decision. Undo the later changes first.");
    const restored = { ...reviewUndo, editRevision: (latest.editRevision ?? 0) + 1 };
    await repo.putWorkspaceResult(workspaceMetadata(restored), restored.analysis, { revision: latest.editRevision ?? 0, sourceSha256: latest.sourceSha256 });
    if (removedImageIds.current.has(reviewUndo.id)) return;
    setImages((items) => items.map((image) => image.id === reviewUndo.id ? { ...restored, file: image.file, originalFile: image.originalFile, objectUrl: image.objectUrl, sourceLoaded: image.sourceLoaded, cells: image.sourceLoaded ? reviewUndo.cells : reviewUndo.cells.map(cellSummary), analysis: image.sourceLoaded ? reviewUndo.analysis : undefined } : image));
    setReviewUndo(undefined);
  };

  const traceContour = (points: Array<{ x: number; y: number }>) => {
    if (!activeImage || busyRef.current || showingPreview || points.length < 3) return;
    pushHistory(activeImage);
    const center = points.reduce((sum, p) => ({ x: sum.x + p.x / points.length, y: sum.y + p.y / points.length }), { x: 0, y: 0 });
    const id = `trace-${crypto.randomUUID()}`;
    try { updateActive((image) => applyEdit(image, { id, appliedAt: new Date().toISOString(), kind: "add", centerPx: center, diameterUm: settings.diameterUm || 30, contourPx: points }), true); setSelectedCellId(`${id}:cell`); }
    catch (error) { setNotice({ tone: "error", title: "Contour could not be added.", detail: ` ${error instanceof Error ? error.message : String(error)}` }); }
  };

  const refinePrompt = async (start: { x: number; y: number }, end?: { x: number; y: number }) => {
    if (!activeImage || busyRef.current || showingPreview || !repository.current) return;
    const image = activeImage, repo = repository.current;
    busyRef.current = true; setRunState("preparing");
    const controller = new AbortController(); abortController.current = controller;
    try {
      const source = await repo.getSource(image.id);
      if (!source) throw new Error("Original source is missing from local storage.");
      const result = await runAdvanced<{ contourPx: Array<{ x: number; y: number }>; centerPx: { x: number; y: number }; diameterUm: number; backend: string }>({ kind: "prompt", source, expectedSourceSha256: image.sourceSha256, parameters: image.analysis?.parameters ?? analysisParameters(settings), calibration: calibrationForImage(image), prompt: { start, end } }, controller.signal);
      if (controller.signal.aborted || removedImageIds.current.has(image.id)) return;
      const current = imageSnapshot.current.find((candidate) => candidate.id === image.id);
      if (!current || current.analysis !== image.analysis || current.pxPerUm !== image.pxPerUm || current.cells !== image.cells) throw new Error("Image changed while the prompt ran. Retry against the current result.");
      const id = `prompt-${crypto.randomUUID()}`;
      const updated = { ...applyEdit(image, { id, appliedAt: new Date().toISOString(), kind: "add", centerPx: result.centerPx, diameterUm: result.diameterUm, contourPx: result.contourPx }), editRevision: (image.editRevision ?? 0) + 1 };
      metadataWriter.current?.flush(image.id);
      await repo.putWorkspaceResult(workspaceMetadata(updated), updated.analysis, { revision: image.editRevision ?? 0, sourceSha256: image.sourceSha256 });
      pushHistory(image); setImages((items) => items.map((candidate) => candidate.id === image.id ? updated : candidate)); setSelectedCellId(`${id}:cell`);
      setNotice({ tone: "success", title: "Prompt contour added.", detail: ` ${result.backend}. Inspect and undo as needed; SAM prompts require a validated learned artifact.` });
    } catch (error) { if (!controller.signal.aborted) setNotice({ tone: "error", title: "Prompt refinement stopped safely.", detail: ` ${error instanceof Error ? error.message : String(error)}` }); }
    finally { busyRef.current = false; setRunState("idle"); abortController.current = undefined; }
  };

  const inspectSourcePlane = async () => {
    if (!activeImage || !repository.current || busyRef.current) return;
    const image = activeImage, controller = new AbortController(); busyRef.current = true; abortController.current = controller; setRunState("preparing");
    try { const source = await repository.current.getSource(image.id); if (!source) throw new Error("Original source is missing."); const result = await runAdvanced<{ blob: Blob; width: number; height: number }>({ kind: "source-preview", source, expectedSourceSha256: image.sourceSha256, parameters: analysisParameters(settings), calibration: calibrationForImage(image) }, controller.signal); if (controller.signal.aborted || removedImageIds.current.has(image.id)) return; if (result.width !== image.width || result.height !== image.height) throw new Error("Selected source plane does not match this image's source coordinates."); setShowingPreview(false); setSelectedCellId(undefined); setSourcePlanePreview({ imageId: image.id, blob: result.blob }); setNotice({ tone: "info", title: "Inspecting the selected original source plane.", detail: " Source-only display uses raw channel/time/Z selection; choose Saved result to return to corrections." }); }
    catch (cause) { if (!controller.signal.aborted) setNotice({ tone: "error", title: "Source preview unavailable.", detail: String(cause) }); }
    finally { busyRef.current = false; abortController.current = undefined; setRunState("idle"); }
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
      if (importing.current || images.some((image) => image.sourcePersisted === false && !removedImageIds.current.has(image.id))) throw new Error("Some image sources have not been saved. Finish importing or export your work before reloading.");
      flushPendingMetadata();
      if (images.length && !repository.current) throw new Error("Local storage is unavailable. Export your work before reloading.");
      await Promise.all(images.filter((image) => !removedImageIds.current.has(image.id)).map((image) => repository.current!.putWorkspaceImage(workspaceMetadata(image))));
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
            {activeImage && <div className="viewer-toolbar"><EditDock active={showingPreview || busy || Boolean(sourcePlanePreview) ? "inspect" : tool} readOnly={showingPreview || busy || Boolean(sourcePlanePreview)} onChange={(next) => { setTool(next); setMergeCellId(undefined); }} canUndo={!busy && !showingPreview && !sourcePlanePreview && history.length > 0} onUndo={undo} canRedo={!busy && !showingPreview && !sourcePlanePreview && redoHistory.length > 0} onRedo={redo} /><div className="result-switch" role="group" aria-label="Displayed analysis"><button aria-pressed={!showingPreview} onClick={() => { setSourcePlanePreview(undefined); setShowingPreview(false); }}>{activeImage.analysis ? "Saved result" : "Source"}</button><button disabled={!preview} aria-pressed={showingPreview} onClick={() => { setSourcePlanePreview(undefined); setShowingPreview(true); }}>Preview</button></div></div>}
            <ImageStage image={stageImage} alternativeCells={!sourcePlanePreview && displayAnalysis && alternative && sameAnalysisPlane(displayAnalysis, alternative.analysis) ? alternative.analysis.cells.map(toWorkspaceCell) : undefined} tool={showingPreview || busy || Boolean(sourcePlanePreview) ? "inspect" : tool} selectedCellId={selectedCellId} onCellPointer={onStagePointer} onTrace={traceContour} onPromptBox={(start, end) => void refinePrompt(start, end)} onRoi={addRoi} onImport={importImages} />
          </div>
          {activeImage && <LinkedMeasurements calibrationVerified={Boolean(activeImage.calibrationSource && activeImage.calibrationSource !== "default")} key={activeId} hasLearnedConfidence={displayAnalysis?.model.id !== "classical"} cells={showingPreview ? stageImage?.cells ?? [] : visibleCells} selectedId={selectedCellId} onSelect={setSelectedCellId} />}
          {images.length > 0 && <Filmstrip images={images} activeId={activeId} onSelect={openImage} onImport={importImages} />}
        </main>
        {activeImage && <Inspector image={activeImage} selectedCell={stageImage?.cells.find((cell) => cell.id === selectedCellId)} showingPreview={showingPreview} mobileOpen={inspectorOpen} onClose={() => setInspectorOpen(false)} tool={tool} onTool={setTool} onSourcePreview={() => void inspectSourcePlane()} onChannelNames={(channelNames) => updateActive((image) => ({ ...image, channelNames }))} onMetadata={updateImageMetadata} truthMetrics={truthResult.metrics} truthError={truthResult.error} onClearValidation={clearValidation} settings={settings} onSettings={(next) => { if (busyRef.current) return; setSettings(next); if (next.pxPerUm !== settings.pxPerUm) updateActive((image) => updateCalibration(image, next.pxPerUm, "manual")); }} count={showingPreview ? stageImage?.cells.length ?? 0 : visibleCells.length} meanDiameter={showingPreview ? (stageImage?.cells.reduce((sum, cell) => sum + cell.diameterUm, 0) ?? 0) / (stageImage?.cells.length || 1) : meanDiameter} onModelFile={() => selectModelFile()} onExport={exportResults} modelReady={readyModels.has(settings.modelId)}>
          <AdvancedPanel image={activeImage} images={images} selectedCellId={selectedCellId} settings={settings} busy={busy} repository={repository.current} onSettings={setSettings} onBeforeSave={(ids) => { for (const id of ids) metadataWriter.current?.flush(id); }} onImages={(updated) => { for (const image of updated) metadataWriter.current?.discard(image.id); setImages((current) => current.map((image) => updated.find((next) => next.id === image.id) ?? image)); }} />
          {activeImage && <details className="mask-variants"><summary>Mask variants and recorded run</summary><p>{activeImage.analysis ? `${activeImage.analysis.model.displayName} · ${new Date(activeImage.analysis.ranAt).toLocaleString()} · source channel ${activeImage.analysis.parameters.sourceChannel === -1 ? "luminance" : (activeImage.analysis.parameters.sourceChannel ?? 0) + 1} · projection ${activeImage.analysis.parameters.projection ?? "unknown"} · ${activeImage.analysis.cells.length} detected · ${visibleCells.length} included after ROI filters` : "Original run settings are unknown until this image is processed."}</p><div className="processing-actions"><button disabled={!activeImage.analysis || busy} onClick={() => void saveVariant()}>Save current mask</button><label>Alternative <select value={alternativeId ?? ""} onChange={(event) => setAlternativeId(event.target.value || undefined)}><option value="">Choose a saved mask</option>{variants.map((variant) => <option key={variant.id} value={variant.id}>{variant.name} · {variant.analysis.cells.length} objects</option>)}</select></label><button disabled={!alternative || busy} onClick={() => void applyVariant()}>Apply alternative</button></div>{alternative && <p>{variantResult.error ? `${variantResult.error} ` : ""}{variantComparison ? `${variantComparison.added} added · ${variantComparison.removed} removed · ${variantComparison.changed} changed · ${variantComparison.unchanged} unchanged. ` : ""}Orange contours show the alternative using the same pan and zoom. Applying preserves the current mask and original run metadata.</p>}{activeImage.analysis && <details><summary>Recorded settings</summary><pre>{JSON.stringify({ model: activeImage.analysis.model, parameters: activeImage.analysis.parameters, runCalibration: activeImage.analysis.workflow?.runCalibration ?? activeImage.analysis.calibration, currentCalibration: calibrationForImage(activeImage), job: activeImage.analysis.workflow }, null, 2)}</pre></details>}</details>}
        </Inspector>}
      </>}
      {route === "microscopy" && <Suspense fallback={<main className="page-view"><p>Opening the local microscopy workspace…</p></main>}><MicroscopyView images={images} repository={repository.current} /></Suspense>}
      {route === "processing" && <ProcessingPanel image={activeImage} images={images} busy={busy} modelReady={readyModels.has(settings.modelId)} jobs={jobs} onProcess={processImages} onResume={(job, retry) => void processJob(retry ? retryJob(job) : recoverJob(job))} onPause={() => { runner.current?.pause(); setNotice({ tone: "info", title: "Pause requested.", detail: " The current image will finish and save before processing pauses." }); }} onCancel={cancel} onReview={() => setRoute("review")} onAnalyze={() => setRoute("workspace")} />}
      {route === "help" && <HelpView onWelcome={() => setWelcomeOpen(true)} onShortcuts={() => setHelpOpen(true)} onCapabilities={() => setRoute("capabilities")} />}
      {route === "library" && <><LibraryView images={images} activeId={activeId} onOpen={openImage} onRemove={removeImage} onCondition={updateCondition} onImport={importImages} onImportFolder={importFolder} /><section className="page-view"><ReviewedDatasetPanel images={images} repository={repository.current} beforeSave={(id) => metadataWriter.current?.flush(id)} onStamp={(id, provenance) => setImages((current) => current.map((image) => image.id === id ? { ...image, provenance } : image))} /></section></>}
      {route === "review" && <ReviewView images={images} onUndo={undoReviewDecision} canUndo={Boolean(reviewUndo)} onOpen={(imageId, cellId) => { void openImage(imageId).then(() => setSelectedCellId(cellId)); }} onAccept={(imageId, cellId) => updateReviewCell(imageId, cellId, "accept")} onReject={(imageId, cellId) => updateReviewCell(imageId, cellId, "reject")} onResize={(imageId, cellId) => updateReviewCell(imageId, cellId, "resize")} />}
      {route === "lab" && <AnalysisLabView key={`${activeId}:${settings.taskPreset ?? "countCells"}`} initialKind={settings.taskPreset === "markerPositive" ? "intensity" : settings.taskPreset === "woundClosure" ? "area" : undefined} image={activeImage} images={images} settings={settings} onSettings={(next) => { if (busyRef.current) return; setSettings(next); if (next.pxPerUm !== settings.pxPerUm) updateActive((image) => updateCalibration(image, next.pxPerUm, "protocol")); }} onWorkspace={() => setRoute("workspace")} />}
      {route === "compare" && <CompareView images={images} onLibrary={() => setRoute("library")} />}
      {route === "models" && <ModelsView readyModels={readyModels} onModelFile={selectModelFile} />}
      {route === "capabilities" && <CapabilitiesView />}
      {route === "settings" && <SettingsView theme={theme} onTheme={toggleTheme} onHelp={() => setHelpOpen(true)} />}
      {pendingUpdate && <UpdateNotice busy={busy || updating} onReload={() => void reloadForUpdate()} />}
      {notice && <NoticeBar notice={notice} onClose={() => setNotice(undefined)} />}
      {exportOpen && activeImage && <ExportDialog image={activeImage.analysis?.displayPlane ? { ...activeImage, originalFile: activeImage.originalFile ?? activeImage.file, file: new File([activeImage.analysis.displayPlane], activeImage.fileName, { type: "image/png" }) } : activeImage} onClose={() => setExportOpen(false)} />}
      <ShortcutDialog open={helpOpen} onClose={() => setHelpOpen(false)} />
    </div>
  );
}
