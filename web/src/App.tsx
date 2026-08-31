import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { decodeImageFiles, releaseImage } from "./app/imageFiles";
import { DebouncedByIdWriter } from "./app/debouncedMetadata";
import { filterCellsByRois } from "./app/roi";
import { analysisIdentities, calibrationForImage } from "./app/provenance";
import type { EditTool, Notice, RouteId, RunState, WorkspaceCell, WorkspaceImage } from "./app/types";
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

const ORT_VERSION = "1.22.0";
const defaultSettings: AnalysisSettings = {
  modelId: "cp-cyto3",
  pxPerUm: 1,
  confidence: 0.5,
  diameterUm: 30,
  backgroundSubtract: false,
  watershedSplit: true,
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
    channels: [0, 0],
    backgroundSubtract: settings.backgroundSubtract,
    rollingBallRadiusPx: 50,
    watershedSplit: settings.watershedSplit,
    watershedMinDistanceUm: 8,
    sizeThresholdsUm: [20, 30],
  };
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
    cells: analysis?.cells.map(toWorkspaceCell) ?? [],
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
  return { id: image.id, fileName: image.fileName, mediaType: image.file.type || image.sourceMediaType || "application/octet-stream", widthPx: image.width, heightPx: image.height, importedAt: image.importedAt, condition: image.condition, pxPerUm: image.pxPerUm, analysisId: analysisId ?? image.analysisId ?? null, sourceSha256: image.sourceSha256, sourceByteLength: image.sourceByteLength, sourceMediaType: image.sourceMediaType, calibrationSource: image.calibrationSource, calibrationConfidence: image.calibrationConfidence, planeCount: image.planeCount, samplesPerPixel: image.samplesPerPixel, bitsPerSample: image.bitsPerSample, thumbnail: image.thumbnailBlob, groundTruth: image.groundTruth, rois: image.rois, note: image.note, reviewConfidence: image.reviewConfidence, modelId: image.modelId, cellSummaries: image.cells.map(cellSummary) };
}

export default function App() {
  const [route, setRoute] = useState<RouteId>("workspace");
  const [images, setImages] = useState<WorkspaceImage[]>([]);
  const [activeId, setActiveId] = useState<string>();
  const [settings, setSettings] = useState(defaultSettings);
  const [tool, setTool] = useState<EditTool>("inspect");
  const [selectedCellId, setSelectedCellId] = useState<string>();
  const [mergeCellId, setMergeCellId] = useState<string>();
  const [history, setHistory] = useState<HistoryEntry[]>([]);
  const [redoHistory, setRedoHistory] = useState<HistoryEntry[]>([]);
  const [runState, setRunState] = useState<RunState>("idle");
  const [notice, setNotice] = useState<Notice>();
  const [helpOpen, setHelpOpen] = useState(false);
  const [exportOpen, setExportOpen] = useState(false);
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
    ...cachedModels,
  ]), [cachedModels]);
  const activeImage = images.find((image) => image.id === activeId);
  const model = MODEL_OPTIONS.find((item) => item.id === settings.modelId)!;
  const visibleCells = useMemo(() => activeImage ? filterCellsByRois(activeImage) : [], [activeImage]);
  const meanDiameter = visibleCells.length ? visibleCells.reduce((sum, cell) => sum + cell.diameterUm, 0) / visibleCells.length : 0;
  const truthMetrics = useMemo(() => activeImage ? matchGroundTruth(activeImage.groundTruth, activeImage.cells.map((cell) => ({ id: cell.id, x: cell.cx, y: cell.cy })), 10 * activeImage.pxPerUm) : undefined, [activeImage?.groundTruth, activeImage?.cells, activeImage?.pxPerUm]);

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
      const storedMetadata = await opened.listWorkspaceImages();
      let metadata = storedMetadata;
      if (!metadata.length) {
        // Legacy migration only. Normal startup never clones the full analyses store.
        const [storedAnalyses, batches] = await Promise.all([opened.listAnalyses(), opened.listBatches()]);
        const conditionByAnalysis = new Map(batches.flatMap((batch) => batch.analyses.map((analysis) => [analysis.id, batch.condition] as const)));
        metadata = storedAnalyses.map((analysis): WorkspaceImageMetadata => ({ id: analysis.image.id, fileName: analysis.image.fileName, mediaType: analysis.image.mediaType, widthPx: analysis.image.widthPx, heightPx: analysis.image.heightPx, importedAt: analysis.image.importedAt, condition: conditionByAnalysis.get(analysis.id) ?? "Unassigned", pxPerUm: analysis.calibration.pxPerUm, analysisId: analysis.id, modelId: analysis.model.id, cellSummaries: analysis.cells.map(toWorkspaceCell).map(cellSummary) }));
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
      workerClient.current?.dispose();
      repository.current?.close();
      imageSnapshot.current.forEach(releaseImage);
    };
  }, [flushPendingMetadata]);

  const importImages = useCallback(() => fileInput.current?.click(), []);
  const importFolder = useCallback(() => folderInput.current?.click(), []);
  const onFiles = async (files: FileList | null) => {
    if (!files?.length) return;
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
    setImages((current) => current.map((image) => image.id === activeId ? update(image) : image));
  }, [activeId]);
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

  const run = useCallback(async () => {
    if (!activeImage) { setNotice({ tone: "info", title: "Import an image first.", detail: " Choose a PNG, JPEG, or WebP field of view." }); return; }
    const manifest = getModelManifest(settings.modelId);
    if (!navigator.gpu) { setRunState("error"); setNotice({ tone: "error", title: "WebGPU is unavailable.", detail: " Use a current WebGPU-capable browser and compatible GPU. CellCounter will not silently switch to another engine." }); return; }
    if (manifest.artifact.availability !== "ready" || !readyModels.has(settings.modelId)) {
      setRunState("error");
      setNotice({ tone: "warning", title: `${model.name} is build-gated.`, detail: " This source release intentionally excludes unvalidated weights. Package the exact checksummed artifact before analysis; no fixture or alternate model will run here." });
      return;
    }
    if (typeof Worker === "undefined") { setRunState("error"); setNotice({ tone: "error", title: "Web Workers are unavailable.", detail: " Analysis cannot run safely in this browser." }); return; }
    if (!workerClient.current) workerClient.current = new InferenceWorkerClient(new Worker(new URL("./workers/inference.worker.ts", import.meta.url), { type: "module", name: "cellcounter-inference" }));
    const controller = new AbortController();
    abortController.current = controller;
    setRunState("preparing");
    try {
      const source = createBrowserImageSource(activeImage.file, { id: activeImage.id, fileName: activeImage.fileName, lastModified: activeImage.file.lastModified });
      const parameters = analysisParameters(settings);
      const calibration = calibrationForImage(activeImage);
      const [result, imageSha256] = await Promise.all([
        workerClient.current.analyze({ source, calibration, parameters, signal: controller.signal, onProgress: (progress) => setRunState(progress.stage === "environment" || progress.stage === "model" ? "preparing" : "running") }),
        source.blob.arrayBuffer().then(sha256Hex),
      ]);
      const identities = analysisIdentities(activeImage, imageSha256, result.imageWidth, result.imageHeight);
      const analysis: ImageAnalysis = {
        schemaVersion: 1,
        id: `${activeImage.id}:analysis`,
        image: identities.image,
        calibration,
        parameters,
        model: { id: manifest.id, displayName: manifest.displayName, manifestVersion: manifest.manifestVersion, artifactSha256: manifest.artifact.sha256, runtime: "onnxruntime-web/webgpu", runtimeVersion: ORT_VERSION },
        ranAt: new Date().toISOString(),
        cells: result.cells,
        correctionLog: [],
        imageStats: result.imageStats,
        originalSource: identities.originalSource,
      };
      await repository.current?.putAnalysis(analysis);
      await repository.current?.putWorkspaceImage(workspaceMetadata({ ...activeImage, width: result.imageWidth, height: result.imageHeight, analysis }, analysis.id));
      updateActive((image) => ({ ...image, width: result.imageWidth, height: result.imageHeight, cells: result.cells.map(toWorkspaceCell), modelId: manifest.id, analysisId: analysis.id, analysis }));
      setRunState("complete");
      setNotice({ tone: "success", title: `${result.cells.length} objects measured.`, detail: " Result, calibration, and model provenance were saved locally." });
    } catch (error) {
      if (controller.signal.aborted) { setRunState("idle"); return; }
      setRunState("error");
      setNotice({ tone: "error", title: "Analysis could not complete.", detail: ` ${error instanceof Error ? error.message : String(error)}` });
    } finally { abortController.current = undefined; }
  }, [activeImage, model.name, readyModels, settings, updateActive]);

  const cancel = useCallback(() => {
    abortController.current?.abort();
    abortController.current = undefined;
    setRunState("idle");
    setNotice({ tone: "info", title: "Analysis cancelled.", detail: " The source image and prior result were preserved." });
  }, []);

  const exportResults = useCallback(() => {
    if (!activeImage?.cells.length) { setNotice({ tone: "info", title: "Nothing to export yet.", detail: " Run analysis or add manual objects first." }); return; }
    setExportOpen(true);
  }, [activeImage]);

  const tools: EditTool[] = ["inspect", "add", "remove", "resize", "merge", "split"];
  const keyActions = useMemo(() => ({ importImages, run, cancel, exportResults, setTool: (index: number) => setTool(tools[index] ?? "inspect"), toggleTheme, showHelp: () => setHelpOpen(true) }), [cancel, exportResults, importImages, run, toggleTheme]);
  useKeyboard(keyActions);

  const openImage = async (id: string) => {
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
      const cells = hydrated.cells.map((cell) => cell.id === cellId ? { ...cell, confidence: 1 } : cell);
      const analysis = hydrated.analysis ? { ...hydrated.analysis, cells: hydrated.analysis.cells.map((cell) => cell.id === cellId ? { ...cell, confidence: 1 } : cell) } : undefined;
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

  return (
    <div className="app-shell" onDragOver={(event) => event.preventDefault()} onDrop={(event) => { event.preventDefault(); void onFiles(event.dataTransfer.files); }}>
      <TopBar theme={theme} toggleTheme={toggleTheme} onHelp={() => setHelpOpen(true)} projectName="Local study" />
      <Rail active={route} onChange={setRoute} />
      <input ref={fileInput} className="sr-only" type="file" accept="image/png,image/jpeg,image/webp,image/bmp,image/tiff,.png,.jpg,.jpeg,.webp,.bmp,.tif,.tiff,.ome.tif,.ome.tiff" multiple onChange={(event) => void onFiles(event.target.files)} />
      <input ref={(element) => { folderInput.current = element; element?.setAttribute("webkitdirectory", ""); }} className="sr-only" type="file" accept="image/png,image/jpeg,image/webp,image/bmp,image/tiff,.png,.jpg,.jpeg,.webp,.bmp,.tif,.tiff,.ome.tif,.ome.tiff" multiple onChange={(event) => void onFiles(event.target.files)} />
      <input ref={modelInput} className="sr-only" type="file" accept=".onnx,application/octet-stream" onChange={(event) => void onModelFile(event.target.files)} />
      {route === "workspace" && <>
        <main className="workspace">
          <WorkspaceToolbar image={activeImage} runState={runState} modelLabel={model.name} onImport={importImages} onRun={() => void run()} onCancel={cancel} onExport={exportResults} />
          <ImageStage image={activeImage} tool={tool} selectedCellId={selectedCellId} onTool={(next) => { setTool(next); setMergeCellId(undefined); }} onCellPointer={onStagePointer} onRoi={addRoi} onImport={importImages} canUndo={history.length > 0} onUndo={undo} canRedo={redoHistory.length > 0} onRedo={redo} />
          <Filmstrip images={images} activeId={activeId} onSelect={openImage} onImport={importImages} />
        </main>
        <Inspector image={activeImage} tool={tool} onTool={setTool} onMetadata={updateImageMetadata} truthMetrics={truthMetrics} onClearValidation={clearValidation} settings={settings} onSettings={(next) => { setSettings(next); if (next.pxPerUm !== settings.pxPerUm) updateActive((image) => { const updated = { ...image, pxPerUm: next.pxPerUm, calibrationSource: "manual" as const, calibrationConfidence: "high" as const }; queueMetadataPersistence(updated); return updated; }); }} count={visibleCells.length} meanDiameter={meanDiameter} onModelFile={() => selectModelFile()} onExport={exportResults} modelReady={readyModels.has(settings.modelId)} />
      </>}
      {route === "library" && <LibraryView images={images} activeId={activeId} onOpen={openImage} onRemove={removeImage} onCondition={updateCondition} onImport={importImages} onImportFolder={importFolder} />}
      {route === "review" && <ReviewView images={images} onOpen={(imageId, cellId) => { void openImage(imageId).then(() => setSelectedCellId(cellId)); }} onAccept={(imageId, cellId) => updateReviewCell(imageId, cellId, "accept")} onReject={(imageId, cellId) => updateReviewCell(imageId, cellId, "reject")} onResize={(imageId, cellId) => updateReviewCell(imageId, cellId, "resize")} />}
      {route === "lab" && <AnalysisLabView image={activeImage} images={images} settings={settings} onSettings={(next) => { setSettings(next); if (next.pxPerUm !== settings.pxPerUm) updateActive((image) => { const updated = { ...image, pxPerUm: next.pxPerUm, calibrationSource: "protocol" as const, calibrationConfidence: "high" as const }; queueMetadataPersistence(updated); return updated; }); }} onWorkspace={() => setRoute("workspace")} />}
      {route === "compare" && <CompareView images={images} onLibrary={() => setRoute("library")} />}
      {route === "models" && <ModelsView readyModels={readyModels} onModelFile={selectModelFile} />}
      {route === "capabilities" && <CapabilitiesView />}
      {route === "settings" && <SettingsView theme={theme} onTheme={toggleTheme} onHelp={() => setHelpOpen(true)} />}
      {notice && <NoticeBar notice={notice} onClose={() => setNotice(undefined)} />}
      {exportOpen && activeImage && <ExportDialog image={activeImage} onClose={() => setExportOpen(false)} />}
      <ShortcutDialog open={helpOpen} onClose={() => setHelpOpen(false)} />
    </div>
  );
}
