import { useCallback, useContext, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { open, save } from "@tauri-apps/plugin-dialog";
import {
  DEFAULT_ANALYSIS, updateAnalysisParameters, type AnalysisParameters, type ProjectSnapshot, type WorkbenchCell,
  type WorkbenchSummary, type WorkbenchJob,
} from "../../../../shared/workbench/protocol";
import WorkbenchAutomation from "./WorkbenchAutomation";
import WorkbenchImageSelector, { WorkbenchImageProvider } from "./WorkbenchImageSelector";
import WorkbenchCatalogueBrowser, { WorkbenchCatalogueProvider } from "./WorkbenchCatalogueBrowser";
import { adoptSnapshotCatalogues, mergeCatalogueEntry, type CatalogueEntry, type CatalogueRef } from "../../../../shared/workbench/catalogueProtocol";
import WorkbenchHistory from "./WorkbenchHistory";
import WorkbenchProjectStorage from "./WorkbenchProjectStorage";
import type { ImagePage, MeasurementPage, PackageRestoreResult, StorageUpgradeResult } from "../../../../shared/workbench/pagingProtocol";
import type { WorkbenchImage } from "../../../../shared/workbench/protocol";
import WorkbenchVolumePanel from "./WorkbenchVolumePanel";
import type { LineageExportArguments, LineageExportFormat, LineageExportResult } from "../../../../shared/workbench/lineageProtocol";
import WorkbenchExtensions from "./WorkbenchExtensions";
import WorkbenchAssays from "./WorkbenchAssays";
import WorkbenchFreshness from "./WorkbenchFreshness";
import WorkbenchStatistics from "./WorkbenchStatistics";
import type { StatisticsActions } from "../../../../shared/workbench/statisticsProtocol";
import type { AssaySeriesActions } from "../../../../shared/workbench/assaySeriesProtocol";
import WorkbenchMigration from "./WorkbenchMigration";
import WorkbenchAgentAccess from "./WorkbenchAgentAccess";
import useWorkbenchSession from "./useWorkbenchSession";
import type { ProjectChanges, SessionNavigation, SessionSelection } from "../../../../shared/workbench/sessionProtocol";
import WorkbenchWorkspace from "./WorkbenchWorkspace";
import { loadWorkflowDocument } from "../../kernel/workflow/workflowDocuments";
import WorkbenchModels from "./WorkbenchModels";
import PlaneSegmentationParameters from "./PlaneSegmentationParameters";
import WorkbenchPreprocessing from "./WorkbenchPreprocessing";
import WorkbenchReview from "./WorkbenchReview";
import WorkbenchSources from "./WorkbenchSources";
import WorkbenchOmero from "./WorkbenchOmero";
import WorkbenchStorage from "./WorkbenchStorage";
import WorkbenchLibrary from "./WorkbenchLibrary";
import type { LibraryActions } from "../../../../shared/workbench/libraryProtocol";
import type { StorageActions, ZarrSource } from "../../../../shared/workbench/storageProtocol";
import WorkbenchRegistration from "./WorkbenchRegistration";
import WorkbenchExports from "./WorkbenchExports";
import WorkbenchLabelImport from "./WorkbenchLabelImport";
import WorkbenchComparison from "./WorkbenchComparison";
import WorkbenchAnnotations from "./WorkbenchAnnotations";
import WorkbenchTaskNavigation, { WORKBENCH_TASKS, WorkbenchTaskSection, type WorkbenchTask } from "./WorkbenchTaskNavigation";
import WorkbenchComposite from "./WorkbenchComposite";
import type { CompositeExportArguments, CompositeExportFormat, CompositeExportResult } from "../../../../shared/workbench/compositeProtocol";
import type { DisplayPreset, DisplayPresetMutation, DisplayPresetFileActions, DisplayPresetExportResult } from "../../../../shared/workbench/displayPresetProtocol";
import type { DisplayRevisionTransition } from "./displayRevision";
import type { DistributedActions, DistributionMutationOperation, RestoredDistributedTask } from "../../../../shared/workbench/distributionProtocol";
import type { RefreshActions, RefreshExportResult, RefreshJob, RefreshMutationOperation } from "../../../../shared/workbench/refreshProtocol";
import { workflowHasExport, type CreateWorkflowJob, type GraphControlActions, type GraphNodePreview, type PreviewGraphNode, type SaveWorkflow } from "../../../../shared/workbench/graphProtocol";
import type { WorkbenchWorkflow } from "../../../../shared/workbench/protocol";
import type { LibraryMigration, MigrationActions, MigrationCapture } from "../../../../shared/workbench/migrationProtocol";
import type { WorkspaceActions, WorkspaceDescriptor, WorkspaceDetail, WorkspaceOutput } from "../../../../shared/workbench/workspaceProtocol";
import type { AnnotationRecord, AnnotationExportArguments, AnnotationExportFormat, AnnotationExportResult } from "../../../../shared/workbench/annotationProtocol";
import type { ImageExportFormat, ImageExportResult } from "../../../../shared/workbench/exportProtocol";
import type { VolumeWorkflowConfiguration } from "../../../../shared/workbench/volumeProtocol";
import type { PackageInspection } from "../../../../shared/workbench/extensionProtocol";
import type { SweepExportArguments, SweepExportFormat, SweepExportResult, WorkbenchSweep } from "../../../../shared/workbench/sweepProtocol";
import { activeJobWorker, type JobWorker } from "../../../../shared/workbench/workerProtocol";
import { legacyLibraryLocations, request, requestResponse } from "../../kernel/workbench/client";
import { WORKBENCH_ACTION_EVENT, takeWorkbenchAction } from "../../components/workbenchNavigation";
import { WorkbenchVisibility } from "../../components/WorkbenchVisibility";
import "./workbench.css";

const PROJECT_KEY = "cellcounter.workbench.project.v1";
const RESTORE_KEY = "cellcounter.workbench.restore.v1";
const format = (value: number | null | undefined) =>
  value == null ? "—" : value.toLocaleString(undefined, { maximumFractionDigits: 3 });

function displayScienceIdentity(value: ProjectSnapshot): string {
  // These are the only inspection fields a preset write may change. Everything
  // else, including untyped future scientific fields, must remain identical.
  const metadata = new Set(["project", "projectRevision", "history", "displayPresets", "imageExports", "storage", "cataloguePages", "selectedCatalogueEntries"]);
  return JSON.stringify({
    project: Object.fromEntries(Object.entries(value.project).filter(([key]) => key !== "revision" && key !== "updatedAt")),
    state: Object.fromEntries(Object.entries(value).filter(([key]) => !metadata.has(key))),
  });
}

export default function WorkbenchPage() {
  if (!("__TAURI_INTERNALS__" in window)) return <section className="workbench workbench-empty" aria-labelledby="workbench-preview-title">
    <h1 id="workbench-preview-title">Microscopy workbench</h1>
    <p>This is a browser preview of the desktop interface. Shared projects, Python analysis, the installed command line and MCP connections require the installed application.</p>
    <p><a className="cc-btn" href="#/workspace">Open the browser workspace demo</a></p>
    <p>The demo keeps its own local documents and supports a limited set of browser operations.</p>
  </section>;
  return <WorkbenchProjectPage />;
}

function WorkbenchProjectPage() {
  const visible = useContext(WorkbenchVisibility);
  const [path, setPath] = useState(() => localStorage.getItem(PROJECT_KEY) ?? "");
  const [snapshot, setSnapshot] = useState<ProjectSnapshot>();
  const [imageId, setImageId] = useState("");
  const [preview, setPreview] = useState("");
  const [cells, setCells] = useState<WorkbenchCell[]>([]);
  const [draft, setDraft] = useState<WorkbenchCell[] | null>(null);
  const [draftTotal, setDraftTotal] = useState<number>();
  const [parameters, setParameters] = useState<AnalysisParameters>({ ...DEFAULT_ANALYSIS });
  const [calibration, setCalibration] = useState("");
  const [selected, setSelected] = useState<number[]>([]);
  const [page, setPage] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [status, setStatus] = useState("");
  const [summary, setSummary] = useState<WorkbenchSummary>();
  const [tool, setTool] = useState<"select" | "polygon">("select");
  const [polygon, setPolygon] = useState<[number, number][]>([]);
  const [mode, setMode] = useState<"projection" | "volume">("projection");
  const [task, setCurrentTask] = useState<WorkbenchTask>("preparation");
  const taskEpoch = useRef(0);
  const setTask = useCallback((next: WorkbenchTask) => {
    taskEpoch.current++;
    setCurrentTask(next);
  }, []);
  const [tiledAnalysisTarget, setTiledAnalysisTarget] = useState<HTMLDivElement | null>(null);
  const [tiledMeasurementsTarget, setTiledMeasurementsTarget] = useState<HTMLDivElement | null>(null);
  const [tiledExportTarget, setTiledExportTarget] = useState<HTMLDivElement | null>(null);
  const [volumeCalibrationTarget, setVolumeCalibrationTarget] = useState<HTMLDivElement | null>(null);
  const [volumeMeasurementsTarget, setVolumeMeasurementsTarget] = useState<HTMLDivElement | null>(null);
  const [volumeContextTarget, setVolumeContextTarget] = useState<HTMLDivElement | null>(null);
  const [volumeCalibrationEditing, setVolumeCalibrationEditing] = useState(false);
  const [importRequested, setImportRequested] = useState(false);
  const libraryImportRef = useRef<HTMLDivElement>(null);
  const agentAccessRef = useRef<HTMLDivElement>(null);
  const [volumeWorkflow, setVolumeWorkflow] = useState<VolumeWorkflowConfiguration>();
  const [volumeEditing, setVolumeEditing] = useState(false);
  const [annotationEditing, setAnnotationEditing] = useState(false);
  const [workspaceEditing, setWorkspaceEditing] = useState(false);
  const [measurementPage, setMeasurementPage] = useState<MeasurementPage<WorkbenchCell>>();
  const [measurementCursors, setMeasurementCursors] = useState<(string | undefined)[]>([undefined]);
  const [maskOverlay, setMaskOverlay] = useState("");
  const [selectedCells, setSelectedCells] = useState<WorkbenchCell[]>([]);
  const [packageToRestore, setPackageToRestore] = useState<PackageInspection>();
  const [packageRestore, setPackageRestore] = useState<{ path: string; result: PackageRestoreResult }>();
  const [rememberedRestorePath, setRememberedRestorePath] = useState(() => localStorage.getItem(RESTORE_KEY) ?? "");
  const [restoreRunning, setRestoreRunning] = useState(false);
  const stopAfterRestore = useRef(false);
  const restoreRef = useRef(packageRestore); restoreRef.current = packageRestore;
  const [displayTransition, setDisplayTransition] = useState<DisplayRevisionTransition>();
  const [navigation, setNavigation] = useState<SessionNavigation>();
  const [workspaceSelection, setWorkspaceSelection] = useState("");
  const alive = useRef(true);
  const locked = useRef(false);
  const actionTail = useRef<Promise<void>>(Promise.resolve());
  const queuedActions = useRef(0);
  const viewEpoch = useRef(0);
  const loadedView = useRef<{ revision: number | undefined; imageId: string; path: string;
    previewReady: boolean; measurementsReady: boolean; overlayReady: boolean; completedAt?: number; navigationId?: string } | undefined>(undefined);
  const stopAfterUnit = useRef(false);
  const [runningJobId, setRunningJobId] = useState("");
  const [runningSweepId, setRunningSweepId] = useState("");
  const [runningRefreshId, setRunningRefreshId] = useState("");
  const [runningMigration, setRunningMigration] = useState(false);
  const stopAfterMigrationUnit = useRef(false);
  const stopAfterSweepUnit = useRef(false);
  const stopAfterRefreshUnit = useRef(false);
  const current = useRef({ path, imageId, snapshot });
  current.current = { path, imageId, snapshot };
  const cataloguePins = useRef<{ projectId?: string; refs: CatalogueRef[] }>({ refs: [] });
  const image = snapshot?.images.find((item) => item.id === imageId);
  const volumeMode = mode === "volume" || (image?.timeCount ?? 1) > 1;
  const displayed = draft ?? cells;
  const projectionMaskEditing = draft !== null || polygon.length > 0 || selected.length > 0;
  const projectionCalibrationEditing = Boolean(image && (calibration === "" ? null : Number(calibration)) !== image.pxPerUm);
  const projectionEditing = projectionMaskEditing || projectionCalibrationEditing;
  const editing = useRef(false);
  const workspaceDraftActive = useRef(false);
  workspaceDraftActive.current = workspaceEditing;
  const workspaceScienceBlocked = useRef(false);
  workspaceScienceBlocked.current = annotationEditing || volumeCalibrationEditing || (volumeMode ? volumeEditing : projectionEditing);
  editing.current = workspaceEditing || workspaceScienceBlocked.current;

  const readSnapshot = async (projectPath: string, selectedId?: string, revision?: number): Promise<ProjectSnapshot> => {
    const refs = projectPath === current.current.path && cataloguePins.current.projectId === current.current.snapshot?.project.id ? cataloguePins.current.refs : [];
    const next = adoptSnapshotCatalogues(await request<ProjectSnapshot>(projectPath, "project.snapshot", {
      selectedImageIds: selectedId ? [selectedId] : [], selectedCatalogueEntries: refs,
    }, revision));
    if (!selectedId && (next.imageCount ?? 0) > 0) {
      const first = await request<ImagePage>(projectPath, "image.list", { archiveScope: "all", limit: 1 }, next.project.revision);
      next.images = first.images;
    }
    return next;
  };
  const adoptCatalogue = (ref: CatalogueRef, entry: CatalogueEntry, identity: string) => {
    const active = current.current;
    if (!active.snapshot || `${active.snapshot.project.id}:${active.snapshot.project.revision}` !== identity) return;
    const next = mergeCatalogueEntry(active.snapshot, ref.catalogue, entry);
    current.current = { ...active, snapshot: next }; setSnapshot(next);
  };
  const refresh = useCallback(async (projectPath: string, preferredId?: string) => {
    const chosen = preferredId ?? (current.current.path === projectPath ? current.current.imageId : "");
    const next = await readSnapshot(projectPath, chosen);
    if (!alive.current) return;
    viewEpoch.current++; loadedView.current = undefined;
    setDisplayTransition(undefined); setNavigation(undefined);
    setPath(projectPath); localStorage.setItem(PROJECT_KEY, projectPath);
    const selectedId = next.images.find(item => item.id === chosen)?.id ?? next.images[0]?.id ?? "";
    setSnapshot(next); setImageId(selectedId);
    current.current = { path: projectPath, imageId: selectedId, snapshot: next };
    setSummary(undefined);
  }, []);
  const selectProjectImage = async (selectedId: string) => {
    const active = current.current;
    if (!active.snapshot || editing.current) throw new Error("Save or discard local drafts before changing the selected image.");
    const value = selectedId ? (await request<{ image: WorkbenchImage }>(active.path, "image.get", { imageId: selectedId }, active.snapshot.project.revision)).image : undefined;
    if (!alive.current || current.current.path !== active.path || current.current.snapshot?.project.revision !== active.snapshot.project.revision) return;
    const next = { ...active.snapshot, images: value ? [value] : [] };
    setSnapshot(next); setImageId(value?.id ?? "");
    current.current = { path: active.path, snapshot: next, imageId: value?.id ?? "" };
  };

  const adoptPresetRevision = async (projectPath: string, selectedId: string, before: ProjectSnapshot,
    operation: DisplayRevisionTransition["operation"], committedRevision: number | undefined, startedAt: number): Promise<boolean> => {
    const fromRevision = before.project.revision;
    let next: ProjectSnapshot | undefined;
    if (committedRevision === fromRevision + 1) {
      try { next = await readSnapshot(projectPath, selectedId, committedRevision); }
      catch { /* A concurrent revision or an unavailable inspection requires ordinary invalidation. */ }
    }
    const selectedImage = before.images.find((item) => item.id === selectedId);
    if (!alive.current || current.current.path !== projectPath) return false;
    if (!next || next.project.revision !== committedRevision || !selectedImage ||
      current.current.imageId !== selectedId || current.current.snapshot?.project.revision !== fromRevision ||
      displayScienceIdentity(before) !== displayScienceIdentity(next)) {
      await refresh(projectPath, current.current.imageId);
      return false;
    }
    // Cancel pending plane reads. Only already-complete data gets the new token.
    viewEpoch.current++;
    const loaded = loadedView.current;
    loadedView.current = loaded?.revision === fromRevision && loaded.path === projectPath && loaded.imageId === selectedId &&
      loaded.previewReady && loaded.measurementsReady && loaded.overlayReady && loaded.completedAt !== undefined && loaded.completedAt <= startedAt
      ? { ...loaded, revision: committedRevision } : undefined;
    setDisplayTransition({ fromRevision, toRevision: committedRevision!, startedAt, operation,
      projectId: before.project.id, imageId: selectedId, sourceHash: selectedImage.sourceHash });
    setSnapshot(next);
    current.current = { path: projectPath, imageId: selectedId, snapshot: next };
    setSummary(undefined);
    return true;
  };

  const run = useCallback((action: () => Promise<void>, quiet = false) => {
    if (!alive.current) return Promise.resolve();
    queuedActions.current++;
    locked.current = true;
    if (!quiet) setBusy(true);
    // Native file pickers may return while a focus refresh is still pending.
    // Serialize explicit actions so their requested mutation is never dropped.
    const next = actionTail.current.then(async () => {
      try {
        if (!alive.current) return;
        if (!quiet) { setError(""); setStatus(""); }
        await action();
      } catch (cause) { if (alive.current && !quiet) setError(cause instanceof Error ? cause.message : String(cause)); }
      finally {
        queuedActions.current--;
        locked.current = queuedActions.current > 0;
        if (alive.current) setBusy(locked.current);
      }
    });
    actionTail.current = next;
    return next;
  }, []);

  useEffect(() => {
    alive.current = true;
    const saved = localStorage.getItem(PROJECT_KEY);
    if (saved) void run(() => refresh(saved));
    return () => { alive.current = false; viewEpoch.current++; };
  }, [refresh, run]);

  useEffect(() => {
    if (volumeMode) { loadedView.current = undefined; viewEpoch.current++; return; }
    if (busy) return;
    const requested = navigation?.selection.imageId === imageId && navigation.selection.target !== "volume" ? navigation : undefined;
    if (loadedView.current?.revision === snapshot?.project.revision && loadedView.current?.imageId === imageId && loadedView.current?.path === path && loadedView.current?.navigationId === requested?.id) return;
    const selectedParameters = { ...(image?.parameters ?? { ...DEFAULT_ANALYSIS, ...image?.preferredSourceParameters }), ...(requested ? { channel: requested.selection.channel ?? 0 } : {}) };
    const needsMeasurements = !!image && (image.analysisRevision != null || (image.cellCount != null && image.status !== "imported")) &&
      (!requested || (image.parameters?.channel ?? 0) === selectedParameters.channel);
    loadedView.current = { revision: snapshot?.project.revision, imageId, path, previewReady: false, measurementsReady: !needsMeasurements, overlayReady: !needsMeasurements, navigationId: requested?.id };
    const epoch = ++viewEpoch.current;
    setPreview(""); setMaskOverlay(""); setCells([]); setSelectedCells([]); setMeasurementPage(undefined); setMeasurementCursors([undefined]); setDraft(null); setSelected([]); setPolygon([]); setPage(0);
    if (!image || !path) return;
    setParameters(selectedParameters);
    setCalibration(image.pxPerUm == null ? "" : String(image.pxPerUm));
    void request<{ dataUrl: string }>(path, "image.preview", { imageId, ...(requested ? { parameters: selectedParameters } : {}) }, snapshot?.project.revision).then((result) => {
      if (alive.current && viewEpoch.current === epoch) {
        setPreview(result.dataUrl);
        if (loadedView.current) {
          loadedView.current.previewReady = true;
          if (loadedView.current.measurementsReady && loadedView.current.overlayReady) loadedView.current.completedAt = performance.now();
        }
      }
    }).catch((cause) => {
      if (alive.current && viewEpoch.current === epoch) setError(String(cause));
    });
    if (needsMeasurements) {
      void request<{ maskDataUrl: string }>(path, "mask.overlay", { imageId, maxSize: 1536 }, snapshot?.project.revision).then(result => {
        if (alive.current && viewEpoch.current === epoch) {
          setMaskOverlay(result.maskDataUrl);
          if (loadedView.current) {
            loadedView.current.overlayReady = true;
            if (loadedView.current.previewReady && loadedView.current.measurementsReady) loadedView.current.completedAt = performance.now();
          }
        }
      }).catch(cause => { if (alive.current && viewEpoch.current === epoch) setError(String(cause)); });
      void request<MeasurementPage<WorkbenchCell>>(path, "measurements.page", { imageId, limit: 100, includeContours: false }, snapshot?.project.revision).then((result) => {
        if (alive.current && viewEpoch.current === epoch) {
          setCells(result.cells); setMeasurementPage(result); setMeasurementCursors([undefined, ...(result.nextCursor ? [result.nextCursor] : [])]);
          if (loadedView.current) {
            loadedView.current.measurementsReady = true;
            if (loadedView.current.previewReady && loadedView.current.overlayReady) loadedView.current.completedAt = performance.now();
          }
        }
      }).catch((cause) => {
        if (alive.current && viewEpoch.current === epoch) setError(String(cause));
      });
    }
  }, [imageId, path, snapshot, busy, volumeMode, navigation?.id]); // explicit refresh reloads saved science

  useEffect(() => {
    let active = true;
    setSelectedCells([]);
    if (!imageId || !path || !selected.length || draft !== null || volumeMode) return;
    void request<{ cells: WorkbenchCell[] }>(path, "measurements.lookup", {
      imageId, labelIds: selected, includeContours: true,
    }, snapshot?.project.revision).then(result => { if (active) setSelectedCells(result.cells); })
      .catch(cause => { if (active) setError(String(cause)); });
    return () => { active = false; };
  }, [imageId, path, snapshot?.project.revision, selected, draft, volumeMode]);

  const changeMeasurementPage = (nextPage: number) => {
    if (draft !== null) { setPage(nextPage); return; }
    void run(async () => {
      const active = current.current;
      if (!active.snapshot || active.imageId !== imageId) return;
      const cursor = measurementCursors[nextPage];
      if (nextPage > 0 && !cursor) return;
      const value = await request<MeasurementPage<WorkbenchCell>>(active.path, "measurements.page", {
        imageId: active.imageId, limit: 100, includeContours: false, ...(cursor ? { cursor } : {}),
      }, active.snapshot.project.revision);
      if (current.current.path !== active.path || current.current.snapshot?.project.revision !== value.sourceRevision || current.current.imageId !== value.imageId) return;
      setCells(value.cells); setMeasurementPage(value); setPage(nextPage);
      setMeasurementCursors(previous => [...previous.slice(0, nextPage + 1), ...(value.nextCursor ? [value.nextCursor] : [])]);
    });
  };

  const mutate = async (operation: string, args: Record<string, unknown>) => {
    const active = current.current;
    if (!active.snapshot) throw new Error("Open a project first.");
    if (workspaceDraftActive.current) throw new Error("Save or discard the layer workspace draft in Images & preparation before changing other project results.");
    const boundedCells = ["analysis.run", "volume.analysis.run", "calibration.set", "mask.edit", "mask.undo", "volume.calibration.set",
      "volume.mask.edit", "volume.mask.undo", "model.run", "plugin.run", "mask.import.run"].includes(operation);
    const result = await request<{ derivedImageId?: string; imageId?: string }>(active.path, operation,
      boundedCells ? { ...args, cellLimit: 200 } : args, active.snapshot.project.revision);
    const preferred = ["preprocessing.run", "registration.apply"].includes(operation) ? result.derivedImageId
      : ["image.duplicate", "plugin.read", "source.extract", "zarr.extract", "omero.import.run"].includes(operation) ? result.imageId : active.imageId;
    await refresh(active.path, preferred ?? active.imageId);
  };

  const activeWorkflowProject = () => {
    const active = current.current;
    if (!active.snapshot) throw new Error("Open a project before saving or running a workflow.");
    if (editing.current) throw new Error("Save or discard pending scientific edits before saving or running a workflow.");
    if (active.snapshot.jobWorkers?.some(activeJobWorker))
      throw new Error("Stop background execution after its current checkpoint before changing workflows or batches.");
    return { ...active, snapshot: active.snapshot };
  };
  const saveWorkflow: SaveWorkflow = (operation, args, accepted) => run(async () => {
    const active = activeWorkflowProject();
    const result = await request<{ workflow: WorkbenchWorkflow }>(active.path, operation, args, active.snapshot.project.revision);
    await refresh(active.path, active.imageId);
    accepted(result.workflow);
    setStatus(`Saved ${result.workflow.name} · version ${result.workflow.version}. Existing batches keep their original versions.`);
  });
  const createWorkflowJob: CreateWorkflowJob = (workflow, imageIds, timeIndices) => run(async () => {
    const active = activeWorkflowProject();
    if (!imageIds.length)
      throw new Error("Select current source images before creating a batch.");
    let exportDestination: string | null = null;
    if (workflowHasExport(workflow)) {
      const stem = workflow.name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").trim().slice(0, 120) || "analysis-batch";
      exportDestination = await save({ title: "Choose a new batch export file", defaultPath: `${stem}.zip`,
        filters: [{ name: "Analysis package", extensions: ["zip"] }] });
      if (!exportDestination) return;
    }
    await request(active.path, "job.create", { workflowId: workflow.id, workflowVersion: workflow.version, imageIds,
      ...(timeIndices ? { timeIndices } : {}), ...(exportDestination ? { exportDestination } : {}) }, active.snapshot.project.revision);
    await refresh(active.path, active.imageId);
    setStatus(`Created a batch from ${workflow.name} · version ${workflow.version}. Use the batch or Background execution controls to run it.`);
  });
  const previewGraphNode: PreviewGraphNode = (args, accepted) => run(async () => {
    const active = current.current;
    if (!active.snapshot) throw new Error("Open a project before previewing a workflow node.");
    if (active.snapshot.jobWorkers?.some(activeJobWorker))
      throw new Error("Stop background execution after its current checkpoint before calculating a node preview.");
    const result = await request<GraphNodePreview>(active.path, "job.graph.node.preview", args, active.snapshot.project.revision);
    if (current.current.path !== active.path || current.current.snapshot?.project.revision !== active.snapshot.project.revision) return;
    accepted(result);
    setStatus(result.mode === "retained-measurements" ? "Showing saved measurements from the selected branch input."
      : "Node preview calculated without saving results or advancing the batch.");
  });

  const requireMigrationAccess = () => {
    if (editing.current) throw new Error("Save or discard pending scientific edits before opening migration dialogs or changing projects.");
    if (current.current.snapshot?.jobWorkers?.some(activeJobWorker))
      throw new Error("Stop background execution after its current checkpoint before importing an existing library.");
  };
  const activeWorkspaceProject = (expectedRevision: number) => {
    const active = current.current;
    if (!active.snapshot) throw new Error("Open a project before editing its layer workspaces.");
    if (workspaceScienceBlocked.current) throw new Error("Save or discard pending mask, calibration or annotation edits before changing workspace versions.");
    if (active.snapshot.jobWorkers?.some(activeJobWorker)) throw new Error("Stop background execution after its current checkpoint before changing workspace versions.");
    if (active.snapshot.project.revision !== expectedRevision) throw new Error("The project changed after these workspace settings were loaded. Preserve or discard the draft and load the current workspace before applying it.");
    return { ...active, snapshot: active.snapshot };
  };
  const workspaceActions: WorkspaceActions = {
    exportDraft: (document, expectedRevision) => run(async () => {
      activeWorkspaceProject(expectedRevision);
      const bytes = new TextEncoder().encode(JSON.stringify(document));
      if (bytes.length > 32 * 1024 * 1024) throw new Error("Workspace draft metadata exceeds the supported 32 MiB file bound. The open draft is retained.");
      const outPath = await save({ title: "Save a copy of workspace draft metadata and journals", defaultPath: "workspace-draft.json", filters: [{ name: "Shared workspace metadata", extensions: ["json"] }] });
      if (outPath) { await invoke("export_workspace_bytes", { outPath, bytes: Array.from(bytes), noOverwrite: true }); setStatus("Draft metadata copied to JSON. This copy does not embed source pixels; the current project retains its source bindings."); }
    }),
    openExisting: selected => run(async () => {
      requireMigrationAccess();
      const document = await loadWorkflowDocument<unknown>("workspace");
      if (!document) throw new Error("No saved local library workspace is available. Choose a previously exported workspace JSON instead.");
      const bytes = new TextEncoder().encode(JSON.stringify(document));
      if (bytes.length > 32 * 1024 * 1024) throw new Error("The existing local workspace exceeds the 32 MiB portable document limit. The original remains untouched.");
      const outPath = await save({ title: "Copy the existing local workspace for previewed project import", defaultPath: "existing-library-workspace.json", filters: [{ name: "Portable workspace", extensions: ["json"] }] });
      if (!outPath) return;
      await invoke("export_workspace_bytes", { outPath, bytes: Array.from(bytes), noOverwrite: true }); selected(outPath);
      setStatus("Existing local workspace copied. Preview its import before retaining a new workspace; the original is preserved.");
    }),
    exportOutput: (output, artifactId, expectedRevision) => run(async () => {
      const active = activeWorkspaceProject(expectedRevision);
      const artifact = output.files.find(item => item.id === artifactId);
      if (!artifact) throw new Error("Choose an artifact from the retained workspace output.");
      const extension = artifact.kind === "presentation-gif" ? "gif" : artifact.kind === "semantic-label-tiff" ? "tif" : artifact.kind.includes("json") || artifact.kind === "microscopy-workspace" ? "json" : "bin";
      const destination = await save({ title: "Export exact retained workspace artifact", defaultPath: `${artifact.kind}-${output.id.slice(0, 8)}.${extension}` });
      if (!destination) return;
      await request(active.path, "workspace.output.export", { outputId: output.id, artifactId, destination }, expectedRevision);
      await refresh(active.path, active.imageId); setStatus("Exact retained workspace artifact exported. Historical output bytes remain unchanged.");
    }),
    commit: async (operation, args, expectedRevision) => {
      let accepted: { value: WorkspaceDetail; revision: number } | undefined;
      await run(async () => {
        const active = activeWorkspaceProject(expectedRevision);
        const response = await requestResponse<{ workspace: WorkspaceDescriptor }>(active.path, operation, args, expectedRevision);
        if (response.revision === undefined) throw new Error("The workspace commit did not return its project revision. Preserve the draft and refresh the project.");
        const value = await request<WorkspaceDetail>(active.path, "workspace.get", { workspaceId: response.result.workspace.id }, response.revision);
        accepted = { value, revision: response.revision };
        await refresh(active.path, active.imageId);
        setStatus("Workspace version retained. Previous source bindings, journals and outputs remain in project history.");
      });
      return accepted;
    },
    export: (workspaceId, expectedRevision, render) => run(async () => {
      const active = activeWorkspaceProject(expectedRevision);
      if (workspaceDraftActive.current) throw new Error("Save the workspace draft before exporting its retained state.");
      let revision = expectedRevision;
      let output: WorkspaceOutput | undefined;
      if (render) {
        const response = await requestResponse<{ output: WorkspaceOutput }>(active.path, render.kind === "semantic" ? "semantic.render" : "animation.render",
          { workspaceId, ...(render.kind === "semantic" ? { layerId: render.id } : { planId: render.id, width: 512, height: 512 }) }, revision);
        if (response.revision === undefined) throw new Error("The retained render did not return its project revision. Refresh before exporting it.");
        revision = response.revision; output = response.result.output;
        await refresh(active.path, active.imageId);
      }
      const artifact = output?.files.find(item => item.kind === (render?.kind === "semantic" ? "semantic-label-tiff" : "presentation-gif"));
      if (render && !artifact) throw new Error("The retained render did not return its requested export artifact. Inspect saved workspace outputs before retrying.");
      const extension = render?.kind === "semantic" ? "tif" : render?.kind === "animation" ? "gif" : "json";
      const destination = await save({ title: "Export saved workspace output", defaultPath: `workspace-${render?.kind ?? "project"}.${extension}`,
        filters: [{ name: render?.kind === "semantic" ? "Semantic class TIFF" : render?.kind === "animation" ? "Presentation GIF" : "Portable workspace", extensions: [extension] }] });
      if (!destination) return;
      await request(active.path, output ? "workspace.output.export" : "workspace.export",
        { ...(output ? { outputId: output.id, artifactId: artifact!.id } : { workspaceId }), destination }, revision);
      await refresh(active.path, active.imageId);
      setStatus("Retained workspace output exported to a new file.");
    }),
    importGeometry: async (expectedRevision) => {
      let value: Partial<import("../../../../shared/microscopy/types").WorkspaceLayer> | undefined;
      await run(async () => {
        activeWorkspaceProject(expectedRevision);
        const path = await open({ title: "Import a vector geometry layer into the workspace draft", multiple: false, filters: [{ name: "Geometry JSON", extensions: ["json"] }] });
        if (typeof path === "string") value = JSON.parse(await invoke<string>("import_workspace_project", { path }));
      });
      return value;
    },
    mutate: <T,>(operation: Parameters<WorkspaceActions["mutate"]>[0], args: Record<string, unknown>, expectedRevision: number, accepted?: (value: T) => void) => run(async () => {
      const active = activeWorkspaceProject(expectedRevision);
      const result = await request<T>(active.path, operation, args, expectedRevision);
      accepted?.(result);
      await refresh(active.path, active.imageId);
      setStatus("Workspace operation saved. Canonical source pixels and instance-mask history remain independently bound.");
    }),
    chooseImport: (selected) => run(async () => {
      requireMigrationAccess();
      const chosen = await open({ title: "Choose a layer workspace JSON", multiple: false, filters: [{ name: "Workspace JSON", extensions: ["json"] }] });
      if (typeof chosen === "string") selected(chosen);
    }),
    import: (args, expectedRevision, accepted) => run(async () => {
      const active = activeWorkspaceProject(expectedRevision);
      const result = await request<{ workspace: WorkspaceDescriptor }>(active.path, "workspace.import.run", args, expectedRevision);
      accepted(result.workspace);
      await refresh(active.path, active.imageId);
      setStatus("Layer workspace imported as a new saved identity. Attach each unavailable source explicitly.");
    }),
    replaceDocument: (workspaceId, expectedRevision) => run(async () => {
      const active = activeWorkspaceProject(expectedRevision);
      const chosen = await open({ title: "Replace saved workspace metadata with a validated JSON document", multiple: false,
        filters: [{ name: "Shared workspace document", extensions: ["json"] }] });
      if (typeof chosen !== "string") return;
      await request(active.path, "workspace.document.set", { workspaceId, path: chosen }, expectedRevision);
      await refresh(active.path, active.imageId);
      setStatus("Validated workspace metadata saved as a new version. Previous workspace versions remain retained.");
    }),
  };
  const migrationActions: MigrationActions = {
    useExistingLibrary: (selected) => run(async () => {
      requireMigrationAccess();
      const locations = await legacyLibraryLocations();
      if (!locations.databaseExists) throw new Error("This installation has no existing library database. Choose a library folder or an already captured archive.");
      selected(locations.libraryRoot);
    }),
    chooseLibrary: (selected) => run(async () => {
      requireMigrationAccess();
      const directory = await open({ title: "Choose the existing Windows library folder", directory: true, multiple: false });
      if (typeof directory === "string") selected(directory);
    }),
    capture: (sourceDirectory, accepted) => run(async () => {
      requireMigrationAccess();
      const destination = await save({ title: "Save a new library archive", defaultPath: "CellCounter-library-archive.json",
        filters: [{ name: "Library archive", extensions: ["json"] }] });
      if (!destination) return;
      const result = await request<MigrationCapture>("", "migration.library.capture", { platform: "windows", sourceDirectory, destination });
      accepted(result);
      setStatus(`Captured ${result.imageCount} image records and ${result.recordCount} records. Preview the archive before creating a shared project.`);
    }),
    chooseArchive: (selected) => run(async () => {
      requireMigrationAccess();
      const chosen = await open({ title: "Choose a captured library archive", multiple: false,
        filters: [{ name: "Library archive", extensions: ["json"] }] });
      if (typeof chosen === "string") selected(chosen);
    }),
    create: (archivePath, plan, name) => run(async () => {
      requireMigrationAccess();
      const stem = name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").trim().slice(0, 120) || "Imported library";
      const destination = await save({ title: "Choose a new project folder for the imported library", defaultPath: `${stem}.ccproject` });
      if (!destination) return;
      await request(destination, "migration.library.run", { path: archivePath, previewFingerprint: plan.previewFingerprint, imageIds: plan.selectedImageIds, name });
      await refresh(destination);
      setTask("preparation");
      setStatus("New import project prepared. Continue the bounded import checkpoints to retain evidence files and source images.");
    }),
    control: (operation) => run(async () => {
      requireMigrationAccess();
      const active = current.current;
      if (!active.snapshot) throw new Error("Open the migration project before changing its import state.");
      const result = await request<{ migration: LibraryMigration }>(active.path, operation, {}, active.snapshot.project.revision);
      await refresh(active.path, active.imageId);
      setStatus(`Library import ${result.migration.status} · ${result.migration.progress.completed}/${result.migration.progress.total} checkpoints.`);
    }),
    runRemaining: () => run(async () => {
      requireMigrationAccess();
      stopAfterMigrationUnit.current = false; setRunningMigration(true);
      try {
        while (alive.current) {
          const active = current.current;
          if (!active.snapshot) break;
          const result = await request<{ migration: LibraryMigration }>(active.path, "migration.library.advance", {}, active.snapshot.project.revision);
          await refresh(active.path, active.imageId);
          setStatus(`Library import ${result.migration.status} · ${result.migration.progress.completed}/${result.migration.progress.total} checkpoints.`);
          if (!["pending", "running"].includes(result.migration.status)) break;
          if (stopAfterMigrationUnit.current) {
            const latest = current.current;
            await request(latest.path, "migration.library.pause", {}, latest.snapshot?.project.revision);
            await refresh(latest.path, latest.imageId);
            setStatus("Library import paused after the completed checkpoint. Retained files remain available.");
            break;
          }
        }
      } finally { if (alive.current) setRunningMigration(false); }
    }),
    stopAfterCheckpoint: () => { stopAfterMigrationUnit.current = true; },
  };

  const chooseProject = (create: boolean) => run(async () => {
    if (editing.current) throw new Error("Save or discard local drafts before changing projects.");
    const chosen = create
      ? await save({ title: "Create analysis project folder", defaultPath: "Experiment.ccproject" })
      : await open({ title: "Open analysis project folder", directory: true, multiple: false });
    if (typeof chosen !== "string") return;
    if (create) {
      const name = chosen.split(/[\\/]/).pop()?.replace(/\.ccproject$/, "") || "Experiment";
      await request(chosen, "project.create", { name });
    }
    await refresh(chosen);
    setStatus(create ? "Project created." : "Project opened.");
  });

  const importImages = () => run(async () => {
    if (!current.current.snapshot) {
      setTask("preparation"); setImportRequested(true);
      setStatus("Create or open a project, then import your images into that project.");
      return;
    }
    if (editing.current) throw new Error("Save or discard local drafts before importing images.");
    const files = await open({
      title: "Import microscopy images", multiple: true,
      filters: [{ name: "Images", extensions: ["png", "jpg", "jpeg", "tif", "tiff", "bmp"] }],
    });
    if (!files) return;
    await mutate("image.import", { paths: Array.isArray(files) ? files : [files] });
    setImportRequested(false); setStatus("Images copied into the project.");
  });

  const choosePackage = () => run(async () => {
    const chosen = await open({ title: "Inspect analysis package", multiple: false,
      filters: [{ name: "Analysis package", extensions: ["zip"] }] });
    if (typeof chosen !== "string") return;
    setPackageToRestore(await request<PackageInspection>("", "package.inspect", { path: chosen }));
  });

  const retainRestore = (destination: string, result: PackageRestoreResult) => {
    const value = { path: destination, result }; restoreRef.current = value;
    if (alive.current) { setPackageRestore(value); setRememberedRestorePath(destination); }
    localStorage.setItem(RESTORE_KEY, destination);
  };
  const storageActionAllowed = () => {
    if (editing.current || current.current.snapshot?.jobWorkers?.some(activeJobWorker))
      throw new Error("Save or discard local drafts and stop background project work before changing storage or restoring a package.");
  };
  const restorePackage = () => run(async () => {
    storageActionAllowed();
    if (!packageToRestore) return;
    const destination = await save({ title: "Restore into a new project folder", defaultPath: `${packageToRestore.package.name}-restored.ccproject` });
    if (!destination) return;
    if (packageToRestore.package.format === 2) {
      const result = await request<PackageRestoreResult>(destination, "package.restore.start", { path: packageToRestore.package.path });
      retainRestore(destination, result); setPackageToRestore(undefined);
      setStatus("Restore checkpoint created. Continue with bounded artifact checkpoints; the current project remains open.");
    } else {
      await request(destination, "package.restore", { path: packageToRestore.package.path });
      await refresh(destination); setPackageToRestore(undefined);
      setStatus("Legacy package restored into a new project. Retained executable code remains disabled.");
    }
  });
  const reopenRestore = (destination?: string) => run(async () => {
    storageActionAllowed();
    const chosen = destination ?? await open({ title: "Open retained partial restore folder", directory: true, multiple: false });
    if (typeof chosen !== "string") return;
    retainRestore(chosen, await request<PackageRestoreResult>(chosen, "package.restore.get"));
  });
  const advanceRestore = (remaining: boolean) => run(async () => {
    storageActionAllowed();
    let value = restoreRef.current; if (!value) return;
    stopAfterRestore.current = false; setRestoreRunning(true);
    try {
      do {
        if (stopAfterRestore.current || !alive.current || !["pending", "running"].includes(value.result.restore.status)) break;
        const result: PackageRestoreResult = await request<PackageRestoreResult>(value.path, "package.restore.advance", { expectedRestoreRevision: value.result.restore.restoreRevision });
        retainRestore(value.path, result); value = { path: value.path, result };
        if (alive.current) setStatus(`Restored ${result.restore.progress.completed} / ${result.restore.progress.total} checkpoints.`);
      } while (remaining);
      if (alive.current && value.result.restore.status === "completed") setStatus("Package restoration completed. Open the completed project when ready.");
    } finally { if (alive.current) setRestoreRunning(false); }
  });
  const controlRestore = (operation: "cancel" | "resume") => run(async () => {
    storageActionAllowed(); const value = restoreRef.current; if (!value) return;
    retainRestore(value.path, await request<PackageRestoreResult>(value.path, `package.restore.${operation}`, { expectedRestoreRevision: value.result.restore.restoreRevision }));
  });
  const upgradeStorage = (previewFingerprint: string, expectedRevision: number, accepted: (value: StorageUpgradeResult) => void) => run(async () => {
    const active = activeWorkflowProject();
    if (active.snapshot.project.revision !== expectedRevision) throw new Error("The project changed. Preview the storage upgrade again.");
    const result = await request<StorageUpgradeResult>(active.path, "project.storage.upgrade.run", { previewFingerprint }, expectedRevision);
    await refresh(active.path, active.imageId); accepted(result);
    setStatus(`Indexed storage retained. Original store recovery copy: ${result.recoveryPath}`);
  });

  const analyze = (commit: boolean) => run(async () => {
    if (!image) return;
    if (commit) {
      await mutate("analysis.run", { imageId, parameters, cellLimit: 200 });
      setStatus("Analysis saved. Measurements use the saved label mask.");
    } else {
      viewEpoch.current++;
      const result = await request<{ cells: WorkbenchCell[]; cellCount: number; dataUrl: string; overlayDataUrl: string }>(
        path, "analysis.preview", { imageId, parameters, cellLimit: 200 }, snapshot?.project.revision);
      setDraft(result.cells); setDraftTotal(result.cellCount); setPreview(result.overlayDataUrl); setSelected([]); setPage(0);
      setStatus("Preview is not saved. Run analysis to save these masks.");
    }
  });

  const updateParameters = (update: Partial<AnalysisParameters>) => {
    setParameters(old => updateAnalysisParameters(old, update));
    // Hide derived geometry until preview/run so it cannot be mistaken for the new settings.
    setDraft([]); setDraftTotal(undefined); setPreview(""); setSelected([]); setPolygon([]);
    setStatus("Settings changed. Preview or run analysis to show matching masks.");
  };

  const selectCell = (id: number) => setSelected((old) =>
    old.includes(id) ? old.filter((value) => value !== id) : old.length < 1000 ? [...old, id] : old);

  const selectTask = (next: WorkbenchTask) => {
    if (document.querySelector("dialog[open]")) return;
    setTask(next);
  };

  const shellActions = useRef({ importImages, chooseProject });
  shellActions.current = { importImages, chooseProject };
  useEffect(() => {
    const handle = () => {
      const action = takeWorkbenchAction();
      if (!action) return;
      if (document.querySelector("dialog[open]")) {
        setStatus("Close the open dialog before using a Workbench navigation command.");
        return;
      }
      if (action.kind === "task") { setTask(action.task); return; }
      if (action.kind === "agent-access" || action.kind === "library-import") {
        if (action.kind === "library-import") setTask("preparation");
        const element = action.kind === "library-import" ? libraryImportRef.current : agentAccessRef.current;
        const details = element?.querySelector("details");
        if (details) details.open = true;
        element?.scrollIntoView({ block: "start" });
        return;
      }
      if (action.kind === "import") { setTask("preparation"); void shellActions.current.importImages(); return; }
      if (editing.current) { setStatus("Save or discard local drafts before changing projects."); return; }
      void shellActions.current.chooseProject(action.kind === "new-project");
    };
    window.addEventListener(WORKBENCH_ACTION_EVENT, handle);
    handle();
    return () => window.removeEventListener(WORKBENCH_ACTION_EVENT, handle);
  }, []);

  const discardProjectionDraft = () => run(async () => {
    const active = current.current;
    const selectedImage = active.snapshot?.images.find((item) => item.id === active.imageId);
    if (!selectedImage) return;
    const result = await request<{ dataUrl: string }>(active.path, "image.preview", { imageId: active.imageId },
      active.snapshot?.project.revision);
    if (!alive.current || current.current.imageId !== active.imageId || current.current.path !== active.path) return;
    viewEpoch.current++;
    setPreview(result.dataUrl); setDraft(null); setPolygon([]); setSelected([]); setTool("select");
    setParameters(selectedImage.parameters ?? { ...DEFAULT_ANALYSIS, ...selectedImage.preferredSourceParameters });
    setCalibration(selectedImage.pxPerUm == null ? "" : String(selectedImage.pxPerUm));
    setStatus("2D drafts cleared. Saved masks and settings are unchanged.");
  });

  const runJob = (jobId: string) => run(async () => {
    stopAfterUnit.current = false;
    setRunningJobId(jobId);
    try {
      while (alive.current) {
        const active = current.current;
        if (!active.snapshot) return;
        const result = await request<{ job: WorkbenchJob }>(active.path, "job.advance", { jobId }, active.snapshot.project.revision);
        await refresh(active.path, active.imageId);
        if (!["running", "pending"].includes(result.job.status)) {
          setStatus(result.job.status === "completed" ? "Batch completed." : `Batch ${result.job.status}.`);
          return;
        }
        if (stopAfterUnit.current) {
          await mutate("job.pause", { jobId });
          setStatus("Batch paused after saving the current step.");
          return;
        }
      }
    } finally { if (alive.current) setRunningJobId(""); }
  });

  const runSweep = (sweepId: string) => run(async () => {
    stopAfterSweepUnit.current = false;
    setRunningSweepId(sweepId);
    try {
      while (alive.current) {
        const active = current.current;
        if (!active.snapshot) return;
        const result = await request<{ sweep: WorkbenchSweep }>(active.path, "sweep.advance", { sweepId },
          active.snapshot.project.revision);
        await refresh(active.path, active.imageId);
        if (!["pending", "running"].includes(result.sweep.status)) {
          setStatus(result.sweep.status === "completed" ? "Parameter sweep completed." : `Parameter sweep ${result.sweep.status}.`);
          return;
        }
        if (stopAfterSweepUnit.current) {
          await mutate("sweep.pause", { sweepId });
          setStatus("Parameter sweep paused after saving the current checkpoint.");
          return;
        }
      }
    } finally { if (alive.current) setRunningSweepId(""); }
  });

  const workerProgress = (workers: JobWorker[]) => {
    const active = current.current;
    if (active.snapshot) {
      const activeWorkers = workers.filter(activeJobWorker);
      const next = { ...active.snapshot, jobWorkers: workers, activeJobWorkers: activeWorkers, activeWorkerCount: activeWorkers.length };
      current.current = { ...active, snapshot: next }; setSnapshot(next);
    }
    if (workers.some(activeJobWorker) || locked.current || editing.current || document.querySelector("dialog[open]")) return;
    const revision = Math.max(-1, ...workers.map((worker) => worker.lastRevision ?? -1));
    if (active.snapshot && revision > active.snapshot.project.revision)
      void run(() => refresh(active.path, active.imageId));
  };

  const observeChanges = async (changes: ProjectChanges, startedAt: number): Promise<boolean> => {
    const before = current.current;
    if (!before.snapshot || editing.current || document.querySelector("dialog[open]")) return false;
    const next = await readSnapshot(before.path, before.imageId);
    if (!alive.current || current.current.path !== before.path || current.current.snapshot?.project.id !== before.snapshot.project.id ||
      current.current.snapshot?.project.revision !== before.snapshot.project.revision || editing.current || document.querySelector("dialog[open]")) return false;
    if (next.project.id !== before.snapshot.project.id || next.project.revision < before.snapshot.project.revision) {
      setError("The project identity or revision changed unexpectedly. Open the project again after preserving local drafts.");
      return false;
    }
    if (next.project.revision === before.snapshot.project.revision) return true;
    const selectedBefore = before.snapshot.images.find(item => item.id === before.imageId);
    const selectedAfter = next.images.find(item => item.id === before.imageId);
    const sameImage = !!selectedBefore && !!selectedAfter && JSON.stringify(selectedBefore) === JSON.stringify(selectedAfter);
    // A worker may create many checkpoints. Adopt progress, then wait until its
    // selected science settles before reloading that image's pixels/masks.
    if (!sameImage && next.jobWorkers?.some(activeJobWorker)) {
      setSnapshot(old => old?.project.id === next.project.id ? { ...old, jobWorkers: next.jobWorkers } : old);
      return false;
    }
    viewEpoch.current++;
    if (sameImage) {
      const loaded = loadedView.current;
      loadedView.current = loaded?.revision === before.snapshot.project.revision && loaded.imageId === before.imageId && loaded.path === before.path &&
        loaded.previewReady && loaded.measurementsReady && loaded.overlayReady && loaded.completedAt !== undefined && loaded.completedAt <= startedAt
        ? { ...loaded, revision: next.project.revision } : undefined;
      setDisplayTransition({ operation: "project.observe", fromRevision: before.snapshot.project.revision, toRevision: next.project.revision,
        startedAt, projectId: next.project.id, imageId: before.imageId, sourceHash: selectedAfter!.sourceHash });
    } else {
      loadedView.current = undefined; setDisplayTransition(undefined); setNavigation(undefined);
    }
    const selectedId = selectedAfter ? before.imageId : next.images[0]?.id ?? "";
    current.current = { path: before.path, imageId: selectedId, snapshot: next };
    setSnapshot(next); setImageId(selectedId); setSummary(undefined);
    if (changes.events.length) setStatus(`Updated to saved revision ${next.project.revision}.`);
    return true;
  };

  const sessionSelection: SessionSelection = {
    task,
    ...(image ? { imageId: image.id, target: volumeMode ? "volume" as const : "plane" as const,
      channel: volumeMode ? volumeWorkflow?.imageId === imageId ? volumeWorkflow.channel : image.preferredVolumeSelection?.channel ?? 0 : parameters.channel,
      ...(volumeMode ? { timeIndex: volumeWorkflow?.imageId === imageId ? volumeWorkflow.timeIndex : image.preferredVolumeSelection?.timeIndex ?? 0,
        plane: volumeWorkflow?.imageId === imageId ? volumeWorkflow.plane ?? "xy" : "xy" as const,
        index: volumeWorkflow?.imageId === imageId ? volumeWorkflow.index ?? 0 : 0 } : {}) } : {}),
    ...(workspaceSelection && snapshot?.workspaces?.some(item => item.id === workspaceSelection) ? { workspaceId: workspaceSelection } : {}),
  };
  const sessionState = useRef({ selection: sessionSelection, blockedReason: "" });
  sessionState.current = { selection: sessionSelection, blockedReason: !visible ? "Return to Workbench before applying requested navigation." : editing.current ? "Save or discard local scientific drafts first."
    : document.querySelector("dialog[open]") ? "Close the open dialog first."
    : snapshot?.jobWorkers?.some(activeJobWorker) ? "Background execution is active; navigation waits for its checkpoint work to settle." : "" };
  const synchronization = useWorkbenchSession({
    state: () => ({ path: current.current.path, projectId: current.current.snapshot?.project.id,
      revision: current.current.snapshot?.project.revision, selection: sessionState.current.selection, busy: locked.current,
      blockedReason: editing.current ? "Save or discard local scientific drafts first." : sessionState.current.blockedReason,
      workers: current.current.snapshot?.jobWorkers ?? [], trainingActive: (current.current.snapshot?.activeTrainingJobCount ?? 0) > 0 }),
    enqueue: action => run(action, true), observe: observeChanges, workers: workerProgress,
    activity: value => {
      const active = current.current; if (!active.snapshot) return;
      const next = adoptSnapshotCatalogues({ ...active.snapshot,
        activeJobWorkers: value.activeJobWorkers, activeTrainingJobs: value.activeTrainingJobs,
        activeWorkerCount: value.activeWorkerCount, activeTrainingJobCount: value.activeTrainingJobCount,
        jobWorkers: active.snapshot.jobWorkers?.filter(worker => !activeJobWorker(worker)),
        trainingJobs: active.snapshot.trainingJobs?.filter(job => !["queued", "starting", "running", "cancelling"].includes(job.status)),
      });
      current.current = { ...active, snapshot: next }; setSnapshot(next);
    },
    navigate: async requested => {
      const active = current.current;
      const epoch = taskEpoch.current;
      const requestedTask = requested.selection.task;
      const commitTask = requestedTask ? () => {
        if (taskEpoch.current !== epoch || current.current.path !== active.path ||
          current.current.snapshot?.project.id !== active.snapshot?.project.id) return;
        setTask(requestedTask);
        setStatus(`Opened ${WORKBENCH_TASKS.find(item => item.id === requestedTask)?.label} for ${requested.actor.name}.`);
      } : undefined;
      if (!visible) return { outcome: "deferred", reason: "Return to Workbench before applying requested navigation." };
      if (requestedTask && Object.keys(requested.selection).every(key => key === "task")) {
        if (document.querySelector("dialog[open]")) return { outcome: "deferred", reason: "Close the open dialog before changing tasks." };
        return { outcome: "applied", commit: commitTask };
      }
      if (!active.snapshot || editing.current || document.querySelector("dialog[open]"))
        return { outcome: "deferred", reason: "Save or discard local drafts and close open dialogs before navigating." };
      if (active.snapshot.jobWorkers?.some(activeJobWorker)) return { outcome: "deferred", reason: "Wait for background execution to settle or stop it after its checkpoint." };
      const target = requested.selection;
      const targetImage = target.imageId ? (await request<{ image: WorkbenchImage }>(active.path, "image.get", { imageId: target.imageId }, active.snapshot.project.revision)).image : undefined;
      if (target.workspaceId) {
        const value = await request<{ entry: CatalogueEntry }>(active.path, "project.catalogue.get", { catalogue: "workspaces", entryId: target.workspaceId }, active.snapshot.project.revision);
        adoptCatalogue({ catalogue: "workspaces", entryId: target.workspaceId }, value.entry, `${active.snapshot.project.id}:${active.snapshot.project.revision}`);
      }
      if (target.imageId && !targetImage) return { outcome: "refused", reason: "The requested image is unavailable in this saved project." };
      if (targetImage) {
        if ((target.channel ?? 0) >= targetImage.channels || (target.timeIndex ?? 0) >= (targetImage.timeCount || 1))
          return { outcome: "refused", reason: "The requested channel or time point is outside this acquisition." };
        if (target.target !== "volume" && (targetImage.timeCount || 1) > 1)
          return { outcome: "refused", reason: "This time-series image requires an explicit volume target and time index." };
        const length = target.plane === "xz" ? targetImage.height : target.plane === "yz" ? targetImage.width : targetImage.zCount || 1;
        if ((target.index ?? 0) >= length) return { outcome: "refused", reason: "The requested orthogonal slice is outside this acquisition." };
        const next = { ...current.current.snapshot!, images: [targetImage] };
        setSnapshot(next); setImageId(targetImage.id);
        current.current = { ...active, imageId: targetImage.id, snapshot: next };
        setMode(target.target === "volume" ? "volume" : "projection");
      }
      setNavigation(requested);
      setStatus(`Navigation requested by ${requested.actor.name} applied to this view.`);
      return { outcome: "applied", commit: commitTask };
    },
  });
  const stopWorker = async (workerId: string) => {
    const activePath = current.current.path;
    await request(activePath, "job.worker.stop", { workerId });
    if (alive.current && current.current.path === activePath)
      setStatus("Stop requested. The worker will save its current step before pausing.");
  };

  const storageActions: StorageActions = {
    run,
    mutate: <T,>(operation: string, args: Record<string, unknown>, accepted?: (result: T) => void) => run(async () => {
      const active = activeWorkflowProject();
      const result = await request<T & { imageId?: string }>(active.path, operation, args, active.snapshot.project.revision);
      await refresh(active.path, operation === "zarr.extract" ? result.imageId ?? active.imageId : active.imageId);
      accepted?.(result);
      setStatus(operation === "tiled.analysis.worker.start" ? "Tiled processing started in the shared background worker. Stop after a checkpoint to pause safely."
        : operation === "tiled.analysis.create" ? "Tiled analysis saved. Run the next checkpoint or start background execution."
          : "Chunked source or tiled checkpoint updated. Retained source evidence remains available.");
    }),
    chooseDirectory: (operation, sourceId, accepted) => run(async () => {
      const active = activeWorkflowProject();
      const selected = await open({ title: operation === "zarr.import" ? "Choose an OME-Zarr image group" : "Relocate the identical OME-Zarr source", directory: true, multiple: false });
      if (typeof selected !== "string") return;
      const result = await request<{ source: ZarrSource }>(active.path, operation, { path: selected, ...(sourceId ? { sourceId } : {}) }, active.snapshot.project.revision);
      await refresh(active.path, active.imageId); accepted?.(result.source);
      setStatus(operation === "zarr.import" ? "Chunked source metadata retained. Select its resolution level and acquisition plane."
        : "Source relocated after matching metadata and retained scientific read identities.");
    }),
    stopWorker,
    exportResults: (analysis, format) => run(async () => {
      const active = activeWorkflowProject();
      const currentAnalysis = active.snapshot.tiledAnalyses?.find(item => item.id === analysis.id);
      if (currentAnalysis?.status !== "completed") throw new Error("Complete the tiled analysis before exporting its verified results.");
      const stem = analysis.name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").trim().slice(0, 120) || "tiled-analysis";
      const destination = await save({ title: `Export ${format.name}`, defaultPath: `${stem}-${format.id}.${format.extension}`, filters: [{ name: format.name, extensions: [format.extension] }] });
      if (!destination) return;
      const result = await request<{ destination: string }>(active.path, "tiled.analysis.export", { analysisId: analysis.id, format: format.id, destination }, active.snapshot.project.revision);
      await refresh(active.path, active.imageId); setStatus(`Tiled results exported to ${result.destination}. Exact labels, source identities and processing provenance are retained.`);
    }),
  };

  const graphControls: GraphControlActions = {
    run,
    mutate: (operation, args, expectedRevision) => run(async () => {
      const active = activeWorkflowProject();
      if (active.snapshot.project.revision !== expectedRevision) throw new Error("The saved graph inputs changed. Read the gate or preview the continuation again.");
      await request(active.path, operation, args, expectedRevision);
      await refresh(active.path, active.imageId);
      setStatus(operation === "job.graph.continue.run" ? "Created an independent corrected continuation. Its remaining checkpoints use the existing batch controls."
        : operation.endsWith("recommend") ? "Recommendation retained; the review gate remains closed." : "Review decision retained. Use the existing batch controls to continue an approved job.");
    }),
    chooseExport: accepted => run(async () => {
      activeWorkflowProject();
      const destination = await save({ title: "Choose a new corrected-continuation package", defaultPath: "corrected-continuation.zip", filters: [{ name: "Analysis package", extensions: ["zip"] }] });
      if (destination) accepted(destination);
    }),
    openInput: binding => run(async () => {
      const active = activeWorkflowProject();
      const selectedImage = (await request<{ image: WorkbenchImage }>(active.path, "image.get", { imageId: binding.imageId }, active.snapshot.project.revision)).image;
      const selection = binding.selection;
      if (!selectedImage || !selection) throw new Error("This exact branch input is unavailable. Read the saved job again.");
      if (selection.channel >= selectedImage.channels || (selection.target === "volume" && selection.timeIndex >= selectedImage.timeCount))
        throw new Error("The retained branch selection is outside the current source grid.");
      const next = { ...active.snapshot, images: [selectedImage] };
      setSnapshot(next); setImageId(selectedImage.id); current.current = { ...active, imageId: selectedImage.id, snapshot: next };
      setMode(selection.target === "volume" ? "volume" : "projection");
      setNavigation({ id: crypto.randomUUID(), status: "applied", observedProjectRevision: active.snapshot.project.revision,
        requestedAt: new Date().toISOString(), actor: { kind: "human", name: "Windows workbench" },
        selection: { imageId: selectedImage.id, target: selection.target, channel: selection.channel,
          ...(selection.target === "volume" ? { timeIndex: selection.timeIndex, plane: "xy", index: 0 } : {}) } });
      setTask("segmentation"); setStatus("Opened the retained branch selection. Save corrections, then return to Workflows to preview a corrected continuation.");
    }),
  };

  const libraryActions: LibraryActions = {
    run,
    mutate: (operation, args, expectedRevision, accepted) => run(async () => {
      const active = activeWorkflowProject();
      if (active.snapshot.project.revision !== expectedRevision)
        throw new Error("The library changed after these settings were read. Preserve the draft, then reload its saved metadata before applying.");
      const result = await request<Parameters<NonNullable<typeof accepted>>[0]>(active.path, operation, args, expectedRevision);
      await refresh(active.path, active.imageId);
      accepted?.(result);
    }),
    chooseSource: accepted => run(async () => {
      activeWorkflowProject();
      const chosen = await open({ title: "Choose the exact original acquisition file", multiple: false, directory: false });
      if (typeof chosen === "string") accepted(chosen);
    }),
    selectImage: selectedId => run(async () => {
      activeWorkflowProject();
      await selectProjectImage(selectedId);
    }),
  };

  const exportImage = (format: ImageExportFormat, args: Record<string, unknown>) => run(async () => {
    const active = current.current;
    if (!active.snapshot) return;
    const selectedImage = active.snapshot.images.find((item) => item.id === args.imageId);
    if (!selectedImage) return;
    const stem = selectedImage.name.replace(/\.[^.]+$/, "").replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_");
    const extension = format.extension.replace(/^\./, "");
    const destination = await save({
      title: `Export ${format.name}`, defaultPath: `${stem}-${format.id}.${extension}`,
      filters: [{ name: format.name, extensions: [extension.split(".").at(-1) ?? extension] }],
    });
    if (!destination) return;
    const result = await request<ImageExportResult>(active.path, "image.export", { ...args, destination },
      active.snapshot.project.revision);
    await refresh(active.path, active.imageId);
    setStatus(`${format.name} saved to ${result.destination}`);
  });

  const exportComposite = (format: CompositeExportFormat, args: CompositeExportArguments) => run(async () => {
    const active = current.current;
    if (!active.snapshot) return;
    if (editing.current) throw new Error("Save or discard pending scientific edits before exporting the channel display.");
    if (active.snapshot.jobWorkers?.some(activeJobWorker))
      throw new Error("Stop the background worker after its current checkpoint before exporting the channel display.");
    const selectedImage = active.snapshot.images.find((item) => item.id === args.imageId);
    if (!selectedImage || active.imageId !== args.imageId) throw new Error("Select the rendered image again before exporting its channel display.");
    const stem = selectedImage.name.replace(/\.[^.]+$/, "").replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").slice(0, 120) || "image";
    const slice = args.target === "volume" ? `-time-${args.timeIndex + 1}-${args.plane}-${args.index + 1}` : `-${args.sourceParameters.zProjection}`;
    const destination = await save({ title: `Export ${format.name}`, defaultPath: `${stem}${slice}-composite.${format.extension}`,
      filters: [{ name: format.name, extensions: [format.extension] }] });
    if (!destination) return;
    const result = await request<CompositeExportResult>(active.path, "image.composite.export", { ...args, destination },
      active.snapshot.project.revision);
    await refresh(active.path, active.imageId);
    setStatus(`Rendered channel display saved to ${result.destination}`);
  });

  const mutateDisplayPreset: DisplayPresetMutation = (operation, args, accepted) => run(async () => {
    const active = current.current;
    if (!active.snapshot) throw new Error("Open a project before saving display presets.");
    if (editing.current) throw new Error("Save or discard pending scientific edits before changing saved display presets.");
    if (active.snapshot.jobWorkers?.some(activeJobWorker))
      throw new Error("Stop the background worker after its current checkpoint before changing saved display presets.");
    const startedAt = performance.now();
    const response = await requestResponse<{ preset: DisplayPreset }>(active.path, operation, args, active.snapshot.project.revision);
    const preserved = await adoptPresetRevision(active.path, active.imageId, active.snapshot, operation, response.revision, startedAt);
    const result = response.result;
    accepted(result);
    const action = operation === "display.preset.import.run" ? "Imported" : operation === "display.preset.archive"
      ? result.preset.archived ? "Archived" : "Restored" : "Saved";
    setStatus(`${action} display preset ${result.preset.name}. ${preserved ? "Current displays, channel settings and scientific selection are preserved."
      : "The display revision could not be retained; channel settings are preserved, but render the display again."}`);
  });

  const displayPresetFiles: DisplayPresetFileActions = {
    chooseImport: (selected) => run(async () => {
      const active = current.current;
      if (!active.snapshot) throw new Error("Open a project before importing display presets.");
      if (editing.current) throw new Error("Save or discard pending scientific edits before choosing a preset file.");
      if (active.snapshot.jobWorkers?.some(activeJobWorker))
        throw new Error("Stop the background worker after its current checkpoint before importing a display preset.");
      const chosen = await open({ title: "Import display preset JSON", multiple: false,
        filters: [{ name: "CellCounter display preset JSON", extensions: ["json"] }] });
      if (typeof chosen === "string") selected(chosen);
    }),
    exportPreset: (format, args, name) => run(async () => {
      const active = current.current;
      if (!active.snapshot) throw new Error("Open a project before exporting display presets.");
      if (editing.current) throw new Error("Save or discard pending scientific edits before exporting a display preset.");
      if (active.snapshot.jobWorkers?.some(activeJobWorker))
        throw new Error("Stop the background worker after its current checkpoint before exporting a display preset.");
      const stem = name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").trim().slice(0, 120) || "display-preset";
      const extension = format.extension.replace(/^\./, "");
      const destination = await save({ title: "Export display preset version",
        defaultPath: `${stem}-v${args.version}.${extension}`,
        filters: [{ name: format.name, extensions: [extension.split(".").at(-1) ?? extension] }] });
      if (!destination) return;
      const startedAt = performance.now();
      const response = await requestResponse<DisplayPresetExportResult>(active.path, "display.preset.export", { ...args, destination },
        active.snapshot.project.revision);
      const preserved = await adoptPresetRevision(active.path, active.imageId, active.snapshot, "display.preset.export", response.revision, startedAt);
      setStatus(`Display preset version ${args.version} saved to ${response.result.destination}. ${preserved ? "Current displays and channel settings are preserved."
        : "The display revision could not be retained; render the channel display again."}`);
    }),
  };

  const activeResultRefreshProject = () => {
    const active = current.current;
    if (!active.snapshot) throw new Error("Open a project before refreshing saved results.");
    if (editing.current) throw new Error("Save or discard pending scientific edits before creating or running a result refresh.");
    if (active.snapshot.jobWorkers?.some(activeJobWorker))
      throw new Error("Stop the background worker after its current checkpoint before changing a result refresh.");
    return { ...active, snapshot: active.snapshot };
  };
  const refreshActions: RefreshActions = {
    mutate: <T,>(operation: RefreshMutationOperation, args: Record<string, unknown>, accepted?: (result: T) => void) => run(async () => {
      const active = activeResultRefreshProject();
      const result = await request<T>(active.path, operation, args, active.snapshot.project.revision);
      await refresh(active.path, active.imageId);
      accepted?.(result);
      setStatus(operation === "refresh.create" ? "Result refresh plan saved. Run its checkpoints from Measurements."
        : operation === "refresh.worker.start" ? "Result refresh started in a local background worker."
          : "Result refresh updated. Corrected masks and predecessor results remain unchanged.");
    }),
    run: (refreshId) => run(async () => {
      const initial = activeResultRefreshProject();
      stopAfterRefreshUnit.current = false;
      setRunningRefreshId(refreshId);
      try {
        while (alive.current) {
          const active = current.current;
          if (!active.snapshot || active.path !== initial.path || active.snapshot.project.id !== initial.snapshot.project.id)
            throw new Error("The active project changed. Reopen the refresh plan to continue its saved checkpoints.");
          const result = await request<{ refresh: RefreshJob }>(active.path, "refresh.advance", { refreshId }, active.snapshot.project.revision);
          await refresh(active.path, active.imageId);
          if (!["pending", "running"].includes(result.refresh.status)) {
            setStatus(result.refresh.status === "completed"
              ? `Result refresh execution completed.${result.refresh.skipped.length ? ` ${result.refresh.skipped.length} blocked results were skipped; coverage remains incomplete.` : ""}`
              : `Result refresh ${result.refresh.status}. Saved checkpoints remain available.`);
            return;
          }
          if (stopAfterRefreshUnit.current) {
            await mutate("refresh.pause", { refreshId });
            setStatus("Result refresh paused after saving its current checkpoint.");
            return;
          }
        }
      } finally { if (alive.current) setRunningRefreshId(""); }
    }),
    stop: () => { stopAfterRefreshUnit.current = true; },
    stopWorker,
    exportReport: (format, refreshId, name) => run(async () => {
      const active = activeResultRefreshProject();
      const stem = name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").trim().slice(0, 120) || "result-refresh";
      const extension = format.extension.replace(/^\./, "");
      const destination = await save({ title: "Export result refresh report", defaultPath: `${stem}-${format.id}.${extension}`,
        filters: [{ name: format.name, extensions: [extension.split(".").at(-1) ?? extension] }] });
      if (!destination) return;
      const result = await request<RefreshExportResult>(active.path, "refresh.export", { refreshId, format: format.id, destination },
        active.snapshot.project.revision);
      await refresh(active.path, active.imageId);
      setStatus(`Refresh report saved to ${result.destination}. Includes all checkpoints, skipped blockers and result replacement links.`);
    }),
  };

  const captureModelEnvironment = (modelId: string) => run(async () => {
    const active = current.current;
    if (!active.snapshot) throw new Error("Open a project before recording a model environment.");
    if (editing.current) throw new Error("Save or discard pending scientific edits before recording a model environment.");
    if (active.snapshot.jobWorkers?.some(activeJobWorker) || active.snapshot.trainingJobs?.some((job) =>
      ["queued", "starting", "running", "cancelling"].includes(job.status)))
      throw new Error("Stop active batch and training workers before recording a model environment.");
    const model = active.snapshot.models?.find((item) => item.id === modelId);
    if (!model?.enabled) throw new Error("Enable the registered trusted model before invoking its interpreter to capture an environment.");
    await request(active.path, "model.environment.capture", { modelId }, active.snapshot.project.revision);
    await refresh(active.path, active.imageId);
    setStatus(`Recorded the saved Python interpreter’s package metadata for ${model.name}. Previous environment records remain available.`);
  });

  const activeDistributionProject = () => {
    const active = current.current;
    if (!active.snapshot) throw new Error("Open a project before preparing distributed work.");
    if (editing.current) throw new Error("Save or discard pending scientific edits before changing distributed work or opening package dialogs.");
    if (active.snapshot.jobWorkers?.some(activeJobWorker))
      throw new Error("Stop the background worker after its current checkpoint before changing distributed work.");
    return { ...active, snapshot: active.snapshot };
  };
  const distributedActions: DistributedActions = {
    mutate: <T,>(operation: DistributionMutationOperation, args: Record<string, unknown>, accepted?: (result: T) => void) => run(async () => {
      const active = activeDistributionProject();
      const result = await request<T>(active.path, operation, args, active.snapshot.project.revision);
      await refresh(active.path, active.imageId);
      accepted?.(result);
      setStatus(operation === "distribution.create" ? "Distributed work saved. Export the task bundles from Workflows."
        : "Task result collected as a separate project. Original image masks and biological assignments are unchanged.");
    }),
    chooseResult: (selected) => run(async () => {
      activeDistributionProject();
      const chosen = await open({ title: "Choose a completed distributed task result", multiple: false,
        filters: [{ name: "Completed analysis package", extensions: ["zip"] }] });
      if (typeof chosen === "string") selected(chosen);
    }),
    prepare: (allowRuntimeDifferences) => run(async () => {
      const active = activeDistributionProject();
      const { task } = await request<{ task: RestoredDistributedTask | null }>(active.path, "distribution.task.get", {}, active.snapshot.project.revision);
      if (!task) throw new Error("This project is not a restored distributed task. Restore a task bundle before preparing it.");
      if (task.prepared) throw new Error("This task already has a job. Use the existing batch controls to run or resume it.");
      let exportDestination: string | null = null;
      if (task.requirements.requiresExportDestination) {
        const stem = task.workflow.name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").trim().slice(0, 120) || "distributed-task";
        exportDestination = await save({ title: "Choose the task workflow’s export destination",
          defaultPath: `${stem}-workflow-export.zip`, filters: [{ name: "Analysis package", extensions: ["zip"] }] });
        if (!exportDestination) return;
      }
      await request(active.path, "distribution.task.prepare", { allowRuntimeDifferences,
        ...(exportDestination ? { exportDestination } : {}) }, active.snapshot.project.revision);
      await refresh(active.path, active.imageId);
      setStatus("Task job prepared. Use the existing batch or background execution controls to run it.");
    }),
    exportPackage: (options) => run(async () => {
      const active = activeDistributionProject();
      if (options.kind === "completed-task") {
        const { task } = await request<{ task: RestoredDistributedTask | null }>(active.path, "distribution.task.get", {}, active.snapshot.project.revision);
        if (!task?.prepared || task.job?.status !== "completed" || task.job.outputsCurrent !== true)
          throw new Error("Complete the prepared task with current results before exporting its returned-result package.");
      }
      const stem = options.name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").trim().slice(0, 160) || "distributed-work";
      const title = options.kind === "task-bundle" ? "Export task bundle" : options.kind === "collected-result"
        ? "Export collected result project" : "Export completed task result";
      const destination = await save({ title, defaultPath: `${stem}.zip`, filters: [{ name: "Analysis package", extensions: ["zip"] }] });
      if (!destination) return;
      const operation = options.kind === "completed-task" ? "project.export" : options.kind === "task-bundle"
        ? "distribution.bundle.export" : "distribution.result.export";
      const args = options.kind === "completed-task" ? { destination }
        : { distributionId: options.distributionId, taskId: options.taskId, destination };
      await request(active.path, operation, args, active.snapshot.project.revision);
      await refresh(active.path, active.imageId);
      setStatus(`${title} saved to ${destination}.${options.kind === "task-bundle"
        ? " Restore it as a new project on the receiving computer, then explicitly prepare its job." : ""}`);
    }),
  };

  const exportAnnotation = (format: AnnotationExportFormat, args: AnnotationExportArguments, annotationName: string) => run(async () => {
    const active = current.current;
    if (!active.snapshot) return;
    const selectedImage = active.snapshot.images.find((item) => item.id === args.imageId);
    if (!selectedImage) return;
    const safeName = (value: string, limit: number) => value.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").trim().slice(0, limit);
    const imageStem = safeName(selectedImage.name.replace(/\.[^.]+$/, ""), 100) || "image";
    const annotationStem = safeName(annotationName, 80) || "annotation";
    const extension = format.extension.replace(/^\./, "");
    const destination = await save({
      title: `Export ${format.name}`, defaultPath: `${imageStem}-${annotationStem}-${format.id}.${extension}`,
      filters: [{ name: format.name, extensions: [extension.split(".").at(-1) ?? extension] }],
    });
    if (!destination) return;
    const result = await request<AnnotationExportResult>(active.path, "annotation.export", { ...args, destination },
      active.snapshot.project.revision);
    await refresh(active.path, active.imageId);
    setStatus(`${format.name} saved to ${result.destination} · geometry revision ${result.geometryRevision}`);
  });

  const exportLineage = (format: LineageExportFormat, args: LineageExportArguments) => run(async () => {
    const active = current.current;
    if (!active.snapshot) return;
    if (editing.current) throw new Error("Save or discard pending image edits before exporting lineage results.");
    const selectedImage = active.snapshot.images.find((item) => item.id === args.imageId);
    if (!selectedImage) return;
    const stem = selectedImage.name.replace(/\.[^.]+$/, "").replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").slice(0, 120) || "image";
    const destination = await save({
      title: `Export ${format.name}`,
      defaultPath: `${stem}-channel-${args.channel + 1}-${format.id}.${format.extension}`,
      filters: [{ name: format.name, extensions: [format.extension] }],
    });
    if (!destination) return;
    const result = await request<LineageExportResult>(active.path, "lineage.export", { ...args, destination },
      active.snapshot.project.revision);
    await refresh(active.path, active.imageId);
    setStatus(`${format.name} saved to ${result.destination} · graph revision ${result.graphRevision}`);
  });

  const chooseLabelFile = (selected: (path: string) => void) => run(async () => {
    const chosen = await open({ title: "Import exact object labels", multiple: false,
      filters: [{ name: "Integer labels", extensions: ["tif", "tiff", "npy"] }] });
    if (typeof chosen === "string") selected(chosen);
  });

  const chooseAnnotationFile = (selected: (path: string) => void) => run(async () => {
    if (editing.current) return;
    const chosen = await open({ title: "Import annotation geometry", multiple: false,
      filters: [{ name: "CellCounter annotation JSON", extensions: ["json"] }] });
    if (typeof chosen === "string") selected(chosen);
  });

  const chooseSweepDirectory = (selected: (path: string) => void) => run(async () => {
    const chosen = await open({ title: "Choose parameter sweep export folder", directory: true, multiple: false });
    if (typeof chosen === "string") selected(chosen);
  });

  const exportSweepResults = (format: SweepExportFormat, args: SweepExportArguments, name: string) => run(async () => {
    const active = current.current;
    if (!active.snapshot) return;
    if (editing.current) throw new Error("Save or discard pending image edits before exporting sweep results.");
    if (active.snapshot.jobWorkers?.some(activeJobWorker))
      throw new Error("Stop the background worker after its current checkpoint before exporting sweep results.");
    const stem = name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").trim().slice(0, 120) || "parameter-sweep";
    const extension = format.extension.replace(/^\./, "");
    const destination = await save({
      title: `Export ${format.name}`, defaultPath: `${stem}-${format.id}.${extension}`,
      filters: [{ name: format.name, extensions: [extension.split(".").at(-1) ?? extension] }],
    });
    if (!destination) return;
    const result = await request<SweepExportResult>(active.path, "sweep.export", { ...args, destination },
      active.snapshot.project.revision);
    await refresh(active.path, active.imageId);
    setStatus(`${format.name} saved to ${result.destination} · includes all sweep inputs`);
  });

  const mutateRecord = <T,>(operation: string, args: Record<string, unknown>, accepted: (result: T) => void) => run(async () => {
      const active = activeWorkflowProject();
      const result = await request<T>(active.path, operation, args, active.snapshot.project.revision);
      await refresh(active.path, active.imageId);
      accepted(result);
    });
  const statisticsActions: StatisticsActions = {
    run,
    mutate: mutateRecord,
    exportReport: (format, report) => run(async () => {
      const active = activeWorkflowProject();
      if (!active.snapshot.statisticsRuns?.some(value => value.id === report.id))
        throw new Error("Choose a statistical result retained in this project before exporting.");
      const stem = report.name.replace(/[<>:\"/\\|?*\u0000-\u001f]/g, "_").trim().slice(0, 120) || "statistical-result";
      const extension = format.extension.replace(/^\./, "");
      const destination = await save({ title: `Export ${format.name}`, defaultPath: `${stem}-${format.id}.${extension}`,
        filters: [{ name: format.name, extensions: [extension] }] });
      if (!destination) return;
      const result = await request<{ destination: string }>(active.path, "statistics.export", {
        runId: report.id, format: format.id, destination,
      }, active.snapshot.project.revision);
      await refresh(active.path, active.imageId);
      setStatus(`Retained statistical report saved to ${result.destination}.`);
    }),
  };
  const assaySeriesActions: AssaySeriesActions = {
    run, mutate: mutateRecord,
    exportReport: (format, retained) => run(async () => {
      const active = activeWorkflowProject();
      const stem = retained.name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").trim().slice(0, 120) || "scratch-series";
      const destination = await save({ title: `Export ${format.name}`, defaultPath: `${stem}.${format.extension}`,
        filters: [{ name: format.name, extensions: [format.extension] }] });
      if (!destination) return;
      const result = await request<{ destination: string }>(active.path, "assay.series.export", {
        runId: retained.runId, format: format.id, destination,
      }, active.snapshot.project.revision);
      await refresh(active.path, active.imageId);
      setStatus(`Retained series report saved to ${result.destination}.`);
    }),
  };

  const editAnnotation = (operation: string, args: Record<string, unknown>, accepted: (annotation: AnnotationRecord) => void) => run(async () => {
    const active = current.current;
    if (!active.snapshot) return;
    const result = await request<{ annotation: AnnotationRecord }>(active.path, operation, args, active.snapshot.project.revision);
    await refresh(active.path, active.imageId);
    accepted(result.annotation);
    setStatus(operation === "annotation.import.run" ? "Annotation imported with a new identity." : "Annotation change saved.");
  });

  return <WorkbenchCatalogueProvider snapshot={snapshot}
    read={(operation, args) => request(path, operation, args, snapshot?.project.revision)} onAdopt={adoptCatalogue}
    onPins={refs => { cataloguePins.current = { projectId: current.current.snapshot?.project.id, refs }; }}>
    <WorkbenchImageProvider projectId={snapshot?.project.id ?? ""} revision={snapshot?.project.revision ?? 0}
    images={snapshot?.images ?? []} read={(operation, args) => request(path, operation, args, snapshot?.project.revision)}>
    <section className="workbench" aria-label="Analysis workbench">
    <header className="workbench-heading">
      <div><h1>{snapshot?.project.name ?? "Analysis workbench"}</h1>
        <p>Import, inspect, segment, correct and export a shared analysis project.</p></div>
      <div className="workbench-actions">
        <button className="cc-btn" disabled={busy || editing.current} onClick={() => void chooseProject(true)}>New project</button>
        <button className="cc-btn" disabled={busy || editing.current} onClick={() => void chooseProject(false)}>Open project</button>
        <button className="cc-btn" disabled={busy || editing.current} onClick={() => void choosePackage()}>Restore package</button>
        <button className="cc-btn" disabled={busy || !snapshot || editing.current} onClick={() => void run(() => refresh(path))}>Refresh project</button>
      </div>
    </header>
    {error ? <div className="workbench-error" role="alert"><p>{error}</p>
      {error.includes("(revision-conflict)") ? <p>The saved project changed. Preserve any pending edits, then refresh the project before retrying.</p> : null}
    </div> : null}
    <p className="workbench-status" role="status">{busy ? runningMigration ? status || "Importing the next library checkpoint…" : "Working…"
      : status || (snapshot ? `Saved revision ${snapshot.project.revision}` : "Create or open a project to begin.")}</p>
    <div ref={agentAccessRef}><WorkbenchAgentAccess path={snapshot ? path : ""} busy={busy}
      writeBlocked={editing.current || Boolean(snapshot?.jobWorkers?.some(activeJobWorker))} run={run}
      chooseFolder={accepted => run(async () => {
        const selected = await open({ directory: true, multiple: false, title: "Choose an allowed source or export folder" });
        if (typeof selected === "string") accepted(selected);
      })} /></div>
    {snapshot ? <details className="workbench-agent-access"><summary>Shared project connection{ synchronization.notice ? " · update pending" : "" }</summary>
      <p>Committed agent and worker changes are observed every five seconds and when this window gains focus. Local drafts defer scientific refresh and image navigation; changing tasks keeps drafts intact.</p>
      {synchronization.session ? <><p>Desktop session: <code>{synchronization.session.id}</code></p>
        <p>Session revision {synchronization.session.sessionRevision} · observed project revision {synchronization.session.observedProjectRevision}</p>
        {synchronization.session.navigation ? <p>Navigation: {synchronization.session.navigation.status}{synchronization.session.navigation.reason ? ` · ${synchronization.session.navigation.reason}` : ""}</p> : null}</> : <p>Registering this desktop view…</p>}
      <p>Session names and actors are local coordination metadata, not proof of identity or client liveness.</p>
      {synchronization.error ? <p className="workbench-error" role="alert">{synchronization.error}</p> : null}
      <button className="cc-btn" disabled={busy} onClick={() => void synchronization.observe()}>Check shared project now</button>
    </details> : null}
    {synchronization.notice ? <p className="workbench-status" role="status">{synchronization.notice}</p> : null}
    <div ref={libraryImportRef} hidden={Boolean(snapshot) && task !== "preparation"}><WorkbenchMigration snapshot={snapshot} busy={busy} writeBlocked={editing.current} running={runningMigration}
      actions={migrationActions} readProjectless={(operation, args) => request("", operation, args)}
      readProject={(operation, args) => request(path, operation, args, snapshot?.project.revision)} /></div>
    <div hidden={Boolean(snapshot) && task !== "preparation"}>
      <WorkbenchOmero busy={busy} canImport={Boolean(snapshot)} writeBlocked={editing.current || Boolean(snapshot?.jobWorkers?.some(activeJobWorker))}
        actions={{ run, chooseFile: (title, accepted) => run(async () => {
          const file = await open({ title, multiple: false, directory: false });
          if (typeof file === "string") await accepted(file);
        }), importRegion: args => run(async () => {
          activeWorkflowProject();
          await mutate("omero.import.run", args);
          setStatus("Imported exact raw OMERO pixels with server, selection and calibration provenance.");
        }) }} />
    </div>
    <div hidden={Boolean(snapshot) && task !== "export" && !packageToRestore && !packageRestore}><WorkbenchProjectStorage snapshot={snapshot} busy={busy} writeBlocked={editing.current || Boolean(snapshot?.jobWorkers?.some(activeJobWorker))}
      selectedPackage={packageToRestore} restore={packageRestore} running={restoreRunning} rememberedRestorePath={rememberedRestorePath}
      run={run} read={(operation, args) => request(path, operation, args, snapshot?.project.revision)}
      upgrade={upgradeStorage} choosePackage={choosePackage} dismissPackage={() => setPackageToRestore(undefined)} startRestore={restorePackage}
      reopenRestore={reopenRestore} advanceRestore={advanceRestore} stopRestore={() => { stopAfterRestore.current = true; setStatus("Stopping restoration after the current verified checkpoint."); }}
      controlRestore={controlRestore} openCompleted={() => run(async () => {
        storageActionAllowed(); const value = restoreRef.current; if (!value || value.result.restore.status !== "completed") return;
        const saved = await request<PackageRestoreResult>(value.path, "package.restore.get");
        retainRestore(value.path, saved); if (saved.restore.status === "completed") await refresh(value.path);
      })} /></div>
    {snapshot ? <>
      <details className="workbench-project-details"><summary>Project details</summary>
        <p className="workbench-project-path">{path}</p><p>{snapshot.imageCount ?? snapshot.images.length} images · saved revision {snapshot.project.revision}</p>
      </details>
      <div className="workbench-selection-context" aria-label="Current image and analysis context">
        <div><span className="workbench-context-label">Selected image</span><strong>{image?.name ?? "No image selected"}</strong>
          {image ? <span>{image.width} × {image.height} pixels · {image.channels} channels · {image.zCount || 1} Z planes · {image.timeCount || 1} time points</span> : null}
          {image ? <span>{volumeMode ? `3D / time · time ${(volumeWorkflow?.imageId === imageId ? volumeWorkflow.timeIndex : 0) + 1} · analysis channel ${(volumeWorkflow?.imageId === imageId ? volumeWorkflow.channel : 0) + 1}`
            : `2D · analysis channel ${parameters.channel + 1} · ${parameters.zProjection} Z projection`}</span> : null}
        </div>
      <div className="workbench-actions" aria-label="Analysis dimension">
        <button className="cc-btn" disabled={busy || editing.current || (image?.timeCount ?? 1) > 1}
          aria-pressed={!volumeMode} onClick={() => setMode("projection")}>2D projection</button>
        <button className="cc-btn" disabled={busy || editing.current} aria-pressed={volumeMode}
          onClick={() => setMode("volume")}>3D / time</button>
        {(image?.timeCount ?? 1) > 1 ? <span>Time series use individual 3D frames.</span> : null}
      </div>
      </div>
      <div ref={setVolumeContextTarget} />
      {importRequested ? <p className="workbench-draft-notice">Your project is ready. <button type="button" className="cc-btn" disabled={busy || editing.current} onClick={() => void importImages()}>Import images…</button></p> : null}
      {editing.current ? <p className="workbench-draft-notice">Selections and drafts stay active when you switch tasks.
        Finish or clear them before changing image, analysis mode or project.
        {annotationEditing ? " Annotation changes are in Measurements." : ""}
        {workspaceEditing ? " Layer workspace changes are in Images." : ""}
        {(volumeMode ? volumeCalibrationEditing : projectionCalibrationEditing) ? " Calibration changes are in Images." : ""}
        {(volumeMode ? volumeEditing : projectionMaskEditing) ? " Mask edits and selections are in Segmentation." : ""}
      </p> : null}
      <WorkbenchTaskNavigation selected={task} onSelect={selectTask} pending={{
        ...(annotationEditing ? { measurements: "Unsaved annotation" } : {}),
        ...((workspaceEditing || volumeCalibrationEditing || (!volumeMode && projectionCalibrationEditing)) ? { preparation: "Unsaved image settings" } : {}),
        ...((volumeMode ? volumeEditing : projectionMaskEditing) ? { segmentation: "Draft or selection active" } : {}),
        ...((runningJobId || runningSweepId || snapshot.jobWorkers?.some(activeJobWorker)) ? { workflows: "Running" } : {}),
      }} />
      <div className="workbench-layout" aria-busy={busy}>
        <aside className="workbench-images" aria-label="Project images">
          <h2>Project images <span>{snapshot.imageCount ?? snapshot.images.length}</span></h2>
          <button className="cc-btn" disabled={busy || editing.current} onClick={() => void importImages()}>Import images…</button>
          {(snapshot.imageCount ?? 0) === 0 ? <p>Import a TIFF or ordinary image. The original is preserved in the project.</p> : null}
          <WorkbenchImageSelector key={snapshot.project.id} label="Selected image" initialOpen selectedIds={imageId ? [imageId] : []}
            disabled={busy || editing.current} onChange={ids => void run(() => selectProjectImage(ids[0] ?? ""))} />
          {image ? <p>{image.cellCount == null ? image.status : `${image.cellCount} saved 2D objects`}{image.volumeFrameCount ? ` · ${image.volumeFrameCount} analyzed volumes` : ""}</p> : null}
        </aside>
        <div className="workbench-task-content">
        <WorkbenchTaskSection task="segmentation" active={task}>
        <div ref={setTiledAnalysisTarget} />
        <div className="workbench-actions">
          <button className="cc-btn" disabled={busy || !image || editing.current} onClick={() => void run(() =>
            mutate("image.duplicate", { imageId, name: `${image?.name.slice(0, 160)} · mask layer` }))}>New mask layer</button>
          <button className="cc-btn" disabled={busy || !image || editing.current} onClick={() => void run(() =>
            mutate("image.duplicate", { imageId, name: `${image?.name.slice(0, 160)} · variant`, copyAnalysis: true }))}>Duplicate saved masks</button>
        </div>
        <div className="workbench-analysis-layout">
        {volumeMode ? image ? <WorkbenchVolumePanel key={`${snapshot.project.id}:${image.id}`} image={image}
          revision={snapshot.project.revision} busy={busy}
          runRead={run} temporalWriteBlocked={!!snapshot.jobWorkers?.some(activeJobWorker)}
          exportLineage={exportLineage}
          exportComposite={exportComposite} compositeExportBlocked={editing.current || !!snapshot.jobWorkers?.some(activeJobWorker)}
          mutatePreset={mutateDisplayPreset} presetFiles={displayPresetFiles} displayTransition={displayTransition}
          navigation={navigation} calibrationTarget={volumeCalibrationTarget} measurementsTarget={volumeMeasurementsTarget}
          contextTarget={volumeContextTarget} onCalibrationEditingChange={setVolumeCalibrationEditing}
          read={(operation, args) => request(path, operation, args, snapshot.project.revision)}
          act={(operation, args) => run(() => {
            if (operation.startsWith("temporal.") || operation.startsWith("lineage.") || operation.startsWith("tracks.")) activeWorkflowProject();
            return mutate(operation, args);
          })}
          onWorkflowChange={setVolumeWorkflow} onEditingChange={setVolumeEditing} /> : <p>Choose an image to inspect.</p> : <>
        <div className="workbench-viewer">
          {image ? <WorkbenchComposite image={image} revision={snapshot.project.revision} busy={busy}
            selection={{ target: "plane", sourceParameters: { zProjection: parameters.zProjection } }}
            exportBlocked={editing.current || !!snapshot.jobWorkers?.some(activeJobWorker)}
            mutatePreset={mutateDisplayPreset} presetFiles={displayPresetFiles} displayTransition={displayTransition}
            read={(operation, args) => request(path, operation, args, snapshot.project.revision)} exportComposite={exportComposite}>
          {(composite) =>
          <div className="workbench-stage">
            {image && preview ? <svg viewBox={`0 0 ${image.width} ${image.height}`} tabIndex={0}
              aria-label={`${image.name}, ${draft === null ? "saved analysis" : "unsaved preview"}`}
              onKeyDown={(event) => {
                if (event.key === "Escape") {
                  event.preventDefault(); setPolygon([]); setSelected([]); return;
                }
                if (busy || draft !== null || image.analysisRevision == null || event.repeat) return;
                if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "z" && !event.shiftKey) {
                  event.preventDefault(); void run(() => mutate("mask.undo", { imageId }));
                } else if (event.key === "Delete" || event.key === "Backspace") {
                  if (tool === "polygon" && polygon.length) {
                    event.preventDefault(); setPolygon((old) => old.slice(0, -1));
                  } else if (tool === "select" && selected.length) {
                    event.preventDefault(); void run(() => mutate("mask.edit", { imageId, action: "delete", labelIds: selected }));
                  }
                } else if (event.key === "Enter" && tool === "polygon" && polygon.length >= 3) {
                  event.preventDefault(); void run(() => mutate("mask.edit", { imageId, action: "polygon", polygon }));
                }
              }}
              onClick={(event) => {
                event.currentTarget.focus();
                if (busy || draft !== null) return;
                const matrix = event.currentTarget.getScreenCTM();
                if (!matrix) return;
                const point = new DOMPoint(event.clientX, event.clientY).matrixTransform(matrix.inverse());
                if (point.x < 0 || point.x >= image.width || point.y < 0 || point.y >= image.height) return;
                if (tool === "polygon") setPolygon((old) => [...old, [point.x, point.y]]);
                else if (image.analysisRevision != null) void run(async () => {
                  const value = await request<{ labelId: number }>(path, "mask.pick", { imageId, x: point.x, y: point.y }, snapshot.project.revision);
                  if (value.labelId > 0 && current.current.imageId === imageId) selectCell(value.labelId);
                });
              }}>
              <image href={draft === null ? composite?.dataUrl ?? preview : preview} width={image.width} height={image.height} preserveAspectRatio="none"
                style={composite ? { imageRendering: "pixelated" } : undefined} />
              {draft === null && maskOverlay ? <image href={maskOverlay} width={image.width} height={image.height} preserveAspectRatio="none" pointerEvents="none" style={{ imageRendering: "pixelated" }} /> : null}
              {(draft === null ? selectedCells : displayed.slice(0, 5000)).map((cell) => <path key={cell.labelId}
                d={(cell.contoursPx ?? (cell.contourPx ? [cell.contourPx] : [])).map((loop) =>
                  loop.length ? `M${loop.map((point) => point.join(",")).join("L")}Z` : "").join("")}
                fillRule="evenodd" className={selected.includes(cell.labelId) ? "selected" : ""}
                vectorEffect="non-scaling-stroke"
                onClick={(event) => { if (tool === "select" && !busy) { event.stopPropagation(); selectCell(cell.labelId); } }} />)}
              {polygon.length ? <polyline points={polygon.map((point) => point.join(",")).join(" ")}
                stroke="#ffcd38" fill="none" strokeWidth="2" vectorEffect="non-scaling-stroke" /> : null}
            </svg> : <p>{image ? draft !== null && !preview ? "Preview or run analysis for the current settings." : "Loading image…" : "Choose an image to inspect."}</p>}
          </div>
          }
          </WorkbenchComposite> : <div className="workbench-stage"><p>Choose an image to inspect.</p></div>}
          {draft === null ? <p>The complete saved mask overlay is displayed. Click any source object to select its exact label; measurement pages do not restrict correction scope. {selected.length} selected (up to 1,000).</p> : null}
          {draft !== null && draftTotal !== undefined && draftTotal > displayed.length ? <p>Complete preview masks are displayed; the temporary table contains the first {displayed.length} of {draftTotal} objects. Save analysis to read every object through the paged table.</p> : null}
          {draft !== null && displayed.length > 5000 ? <p>Showing the first 5,000 object outlines. All measurements remain in the exported analysis.</p> : null}
          <div className="workbench-actions">
            <button className="cc-btn" aria-pressed={tool === "select"} disabled={busy} onClick={() => { setTool("select"); setPolygon([]); }}>Select</button>
            <button className="cc-btn" aria-pressed={tool === "polygon"} disabled={busy || draft !== null || image?.analysisRevision == null}
              onClick={() => { setTool("polygon"); setPolygon([]); }}>Draw object</button>
            <button className="cc-btn" disabled={busy || polygon.length < 3 || draft !== null}
              onClick={() => void run(() => mutate("mask.edit", { imageId, action: "polygon", polygon }))}>Save polygon</button>
            <button className="cc-btn" disabled={busy || polygon.length < 3 || selected.length !== 1 || draft !== null}
              onClick={() => void run(() => mutate("mask.edit", { imageId, action: "polygon", polygon, labelId: selected[0] }))}>Replace selected with polygon</button>
            <button className="cc-btn" disabled={busy || draft !== null || !selected.length}
              onClick={() => void run(() => mutate("mask.edit", { imageId, action: "delete", labelIds: selected }))}>Delete selected</button>
            <button className="cc-btn" disabled={busy || draft !== null || selected.length < 2}
              onClick={() => void run(() => mutate("mask.edit", { imageId, action: "merge", labelIds: selected }))}>Merge selected</button>
            <button className="cc-btn" disabled={busy || draft !== null || !image?.analysisRevision}
              onClick={() => void run(() => mutate("mask.undo", { imageId }))}>Undo mask edit</button>
            <button className="cc-btn" disabled={busy || !image || !projectionEditing}
              onClick={() => void discardProjectionDraft()}>Discard 2D drafts and selection</button>
          </div>
          {tool === "polygon" ? <p>Click around an object, then save the polygon. Enter saves, Backspace removes the last point and Escape clears. Switching to Select clears the draft.</p> : null}
          <div className="workbench-table">
            <table><caption>{draft === null ? "Saved measurements" : "Preview measurements"} · {draft === null ? measurementPage?.total ?? 0 : draftTotal ?? displayed.length} objects</caption>
              <thead><tr><th>Select</th><th>Object</th><th>Area px²</th><th>Area µm²</th><th>Diameter µm</th><th>Mean intensity</th></tr></thead>
              <tbody>{(draft === null ? displayed : displayed.slice(page * 100, (page + 1) * 100)).map((cell) => <tr key={cell.labelId}>
                <td><input type="checkbox" aria-label={`Select object ${cell.labelId}`} disabled={busy}
                  checked={selected.includes(cell.labelId)} onChange={() => selectCell(cell.labelId)} /></td>
                <td>{cell.labelId}</td><td>{format(cell.areaPx)}</td><td>{format(cell.areaUm2)}</td>
                <td>{format(cell.diameterUm)}</td><td>{format(cell.meanIntensity)}</td>
              </tr>)}</tbody>
            </table>
          </div>
          <div className="workbench-actions">
            <button className="cc-btn" disabled={busy || page === 0 || (draft === null && measurementPage?.sourceRevision !== snapshot.project.revision)} onClick={() => changeMeasurementPage(page - 1)}>Previous 100</button>
            <span>Page {page + 1}</span>
            {draft === null ? <button className="cc-btn" disabled={busy || !image?.analysisRevision} onClick={() => changeMeasurementPage(0)}>Refresh measurement pages</button> : null}
            <button className="cc-btn" disabled={busy || (draft === null ? !measurementPage?.nextCursor || measurementPage.sourceRevision !== snapshot.project.revision : (page + 1) * 100 >= displayed.length)} onClick={() => changeMeasurementPage(page + 1)}>Next 100</button>
          </div>
          {draft === null && measurementPage && measurementPage.sourceRevision !== snapshot.project.revision ? <p>The saved project revision changed. Refresh measurement pages to start a new cursor sequence; selected labels are retained.</p> : null}
        </div>
        <aside className="workbench-inspector" aria-label="Analysis settings">
          <h2>Segmentation</h2>
          <fieldset disabled={busy || !image}>
            <PlaneSegmentationParameters values={parameters} onChange={updateParameters} />
            <label>Channel<select value={parameters.channel} onChange={(event) => updateParameters({ channel: Number(event.target.value) })}>
              {Array.from({ length: image?.channels ?? 1 }, (_, index) => <option key={index} value={index}>Channel {index + 1}</option>)}</select></label>
            <label>Z projection<select value={parameters.zProjection} onChange={(event) => updateParameters({ zProjection: event.target.value as AnalysisParameters["zProjection"] })}>
              <option value="max">Maximum</option><option value="mean">Mean</option><option value="middle">Middle plane</option></select></label>
            <div className="workbench-actions">
              <button className="cc-btn" onClick={() => void analyze(false)}>Preview</button>
              <button className="cc-btn workbench-primary" onClick={() => void analyze(true)}>Run analysis</button>
            </div>
          </fieldset>

        </aside>
        </>}
        </div>
      <WorkbenchLabelImport key={`label-import-${snapshot.project.id}`} image={image} revision={snapshot.project.revision}
        parameters={parameters} busy={busy} volumeMode={volumeMode}
        volume={volumeWorkflow?.imageId === imageId ? volumeWorkflow : undefined}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)}
        act={(operation, args) => run(() => mutate(operation, args))} chooseFile={chooseLabelFile} />
      <WorkbenchModels key={`models-${snapshot.project.id}`} snapshot={snapshot} imageId={imageId}
        chooseFile={(title, selected) => run(async () => {
          const chosen = await open({ title, multiple: false });
          if (typeof chosen === "string") selected(chosen);
        })}
        captureEnvironment={captureModelEnvironment} environmentWriteBlocked={editing.current || !!snapshot.jobWorkers?.some(activeJobWorker)}
        parameters={parameters} busy={busy} volumeMode={volumeMode}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)}
        act={(operation, args) => run(() => mutate(operation, args))} />
      </WorkbenchTaskSection>
      <WorkbenchTaskSection task="export" active={task}>
      <div ref={setTiledExportTarget} />
      <WorkbenchCatalogueBrowser catalogues={["imageExports", "workspaceOutputs", "labelImports"]} title="Retained export and import records" disabled={busy} />
      <section className="workbench-project-results" aria-label="Project results">
          <h2>Project results</h2>
          <div className="workbench-actions">
            <button className="cc-btn" disabled={busy} onClick={() => void run(async () => {
              setSummary(await request<WorkbenchSummary>(path, "summary.get", {}, snapshot.project.revision));
            })}>Summarize project</button>
            <button className="cc-btn" disabled={busy} onClick={() => void run(async () => {
              const destination = await save({ title: "Export analysis package", defaultPath: `${snapshot.project.name}.zip`,
                filters: [{ name: "Analysis package", extensions: ["zip"] }] });
              if (destination) { await mutate("project.export", { destination }); setStatus(`Analysis package saved to ${destination}`); }
            })}>Export package</button>
          </div>
          <WorkbenchExports image={image} parameters={parameters} busy={busy} volumeMode={volumeMode}
            volume={volumeWorkflow?.imageId === imageId ? volumeWorkflow : undefined}
            read={(operation, args) => request("", operation, args)} exportImage={exportImage} />
          {summary ? <div className="workbench-summary">
            <p>2D analyses: {summary.cellCount} objects across {summary.analyzedImageCount} of {summary.imageCount} images.</p>
            <ul>{summary.images.map((item) => <li key={item.imageId}>
              <strong>{item.name}</strong>: {format(item.cellCount)} objects · {format(item.totalAreaUm2)} µm²
            </li>)}</ul>
            {summary.volumes?.frameCount ? <>
              <p>3D analyses: {summary.volumes.cellCount} object observations across {summary.volumes.frameCount} time/channel frames.
                Time points are not biological replicates.</p>
              <ul>{summary.volumes.frames.map((frame) => <li key={`${frame.imageId}:${frame.timeIndex}:${frame.channel}`}>
                <strong>{frame.name}</strong> · time {frame.timeIndex + 1} · channel {frame.channel + 1}: {frame.cellCount} objects · {format(frame.volumeUm3)} µm³
              </li>)}</ul>
            </> : null}
          </div> : null}
          <WorkbenchHistory revision={snapshot.project.revision} read={(operation, args) => request(path, operation, args, snapshot.project.revision)} />
      </section>
      </WorkbenchTaskSection>
      <WorkbenchTaskSection task="preparation" active={task}>
      <section className="workbench-image-calibration" aria-label="Selected image calibration">
        <div ref={setVolumeCalibrationTarget} />
        {!volumeMode ? <>
          <h2>Calibration</h2>
          <fieldset disabled={busy || !image || projectionMaskEditing || annotationEditing || workspaceEditing}>
            <label>Pixels per micrometre<input type="number" min="0" step="any" value={calibration}
              placeholder="Unknown" onChange={(event) => setCalibration(event.target.value)} /></label>
            <button className="cc-btn" disabled={!Number.isFinite(Number(calibration)) || Number(calibration) <= 0}
              onClick={() => void run(() => mutate("calibration.set", { imageId, pxPerUm: Number(calibration) }))}>Apply calibration</button>
            <button type="button" className="cc-btn" disabled={!projectionCalibrationEditing}
              onClick={() => setCalibration(image?.pxPerUm == null ? "" : String(image.pxPerUm))}>Discard calibration changes</button>
            <p>Physical measurements remain unavailable until calibration is supplied.</p>
          </fieldset></> : null}
      </section>
      <WorkbenchCatalogueBrowser catalogues={["collections", "largeSources", "zarrSources", "tiledAnalyses", "workspaces", "workspaceOutputs"]} title="Browse saved preparation records" disabled={busy} />
      {!image ? <p>Import images using the image list, or extract a region from a large TIFF below.</p> : <div className="workbench-actions">
        <button type="button" className="cc-btn" onClick={() => selectTask("segmentation")}>Segment selected image</button>
      </div>}
      <WorkbenchSources key={`sources-${snapshot.project.id}`} snapshot={snapshot} busy={busy}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)}
        act={(operation, args) => run(() => mutate(operation, args))} />
      <WorkbenchStorage key={`storage-${snapshot.project.id}`} snapshot={snapshot} busy={busy}
        writeBlocked={editing.current} actions={storageActions} analysisTarget={tiledAnalysisTarget} measurementsTarget={tiledMeasurementsTarget} exportTarget={tiledExportTarget} activeTask={task}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)} />
      <WorkbenchLibrary key={`library-${snapshot.project.id}`} snapshot={snapshot} imageId={imageId} busy={busy}
        writeBlocked={editing.current || !!snapshot.jobWorkers?.some(activeJobWorker)} actions={libraryActions}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)} />
      <WorkbenchPreprocessing key={`preprocessing-${snapshot.project.id}`} image={image} revision={snapshot.project.revision}
        parameters={parameters} busy={busy} volumeMode={volumeMode}
        volume={volumeWorkflow?.imageId === imageId ? volumeWorkflow : undefined}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)}
        act={(operation, args) => run(() => mutate(operation, args))} />
      <WorkbenchRegistration key={`registration-${snapshot.project.id}`} snapshot={snapshot} imageId={imageId} busy={busy}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)}
        act={(operation, args) => run(() => mutate(operation, args))} />
      <WorkbenchWorkspace key={`workspace-${snapshot.project.id}`} snapshot={snapshot} imageId={imageId} busy={busy}
        writeBlocked={workspaceScienceBlocked.current} onEditingChange={setWorkspaceEditing}
        navigation={navigation} onSelectionChange={setWorkspaceSelection}
        selection={volumeMode ? { target: "volume", timeIndex: volumeWorkflow?.imageId === imageId ? volumeWorkflow.timeIndex : 0,
          channel: volumeWorkflow?.imageId === imageId ? volumeWorkflow.channel : 0 }
          : { target: "plane", channel: parameters.channel, zProjection: parameters.zProjection }}
        actions={workspaceActions} read={(operation, args) => request(path, operation, args, snapshot.project.revision)} />
      </WorkbenchTaskSection>
      <WorkbenchTaskSection task="workflows" active={task}>
      <WorkbenchFreshness key={`freshness-${snapshot.project.id}`} snapshot={snapshot} imageId={imageId} busy={busy}
        writeBlocked={editing.current} runningRefreshId={runningRefreshId} actions={refreshActions}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)} />
      <WorkbenchCatalogueBrowser catalogues={["workflows", "jobs", "sweeps", "distributions", "jobWorkers", "refreshJobs", "plugins", "adaptationDatasets", "models", "trainingJobs", "specimens", "plates", "assignments", "experimentLayouts", "experimentApplications", "acquisitionSessions", "experimentExclusions"]} title="Browse saved workflows and experiment records" disabled={busy} />
      <WorkbenchAutomation key={snapshot.project.id} snapshot={snapshot} imageId={imageId} parameters={parameters} busy={busy}
        volumeMode={volumeMode} volume={volumeWorkflow?.imageId === imageId ? volumeWorkflow : undefined}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)}
        act={(operation, args) => run(() => mutate(operation, args))}
        runJob={runJob} stopJob={() => { stopAfterUnit.current = true; }}
        runningJobId={runningJobId}
        chooseSweepDirectory={chooseSweepDirectory} runSweep={runSweep}
        stopSweep={() => { stopAfterSweepUnit.current = true; }} runningSweepId={runningSweepId}
        exportSweepResults={exportSweepResults}
        distributedActions={distributedActions} distributedWriteBlocked={editing.current}
        saveWorkflow={saveWorkflow} createWorkflowJob={createWorkflowJob}
        previewGraphNode={previewGraphNode} graphControls={graphControls}
        experimentActions={{ run, mutate: mutateRecord }} experimentWriteBlocked={editing.current || !!snapshot.jobWorkers?.some(activeJobWorker)}
        readWorker={(operation, args) => request(path, operation, args)}
        stopWorker={stopWorker} onWorkerProgress={workerProgress}
      />
      <WorkbenchExtensions key={`extensions-${snapshot.project.id}`} snapshot={snapshot} imageId={imageId}
        parameters={parameters} busy={busy} volumeMode={volumeMode}
        volume={volumeWorkflow?.imageId === imageId ? volumeWorkflow : undefined}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)}
        act={(operation, args) => run(() => mutate(operation, args))} />
      </WorkbenchTaskSection>
      <WorkbenchTaskSection task="measurements" active={task}>
      <div ref={setVolumeMeasurementsTarget} />
      <div ref={setTiledMeasurementsTarget} />
      <WorkbenchCatalogueBrowser catalogues={["assayRuns", "assaySeriesRuns", "statisticsDesigns", "statisticsRuns", "specimens", "experimentApplications"]} title="Browse saved measurement records" disabled={busy} />

      <WorkbenchStatistics key={`statistics-${snapshot.project.id}`} snapshot={snapshot} busy={busy}
        writeBlocked={editing.current || !!snapshot.jobWorkers?.some(activeJobWorker)} actions={statisticsActions}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)} />
      <WorkbenchAnnotations key={`annotations-${snapshot.project.id}`} image={image} revision={snapshot.project.revision}
        parameters={parameters} busy={busy} volumeMode={volumeMode}
        volume={volumeWorkflow?.imageId === imageId ? volumeWorkflow : undefined}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)}
        act={editAnnotation} exportAnnotation={exportAnnotation} chooseImportFile={chooseAnnotationFile}
        importBlocked={editing.current} onEditingChange={setAnnotationEditing} />
      <WorkbenchAssays key={`assays-${snapshot.project.id}`} imageId={imageId} images={snapshot.images} revision={snapshot.project.revision}
        sourceParameters={{ channel: parameters.channel, zProjection: parameters.zProjection }} seriesActions={assaySeriesActions}
        writeBlocked={editing.current || !!snapshot.jobWorkers?.some(activeJobWorker)}
        busy={busy} volumeMode={volumeMode} volume={volumeWorkflow?.imageId === imageId ? volumeWorkflow : undefined}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)}
        act={(operation, args) => run(() => mutate(operation, args))} />
      </WorkbenchTaskSection>
      <WorkbenchTaskSection task="review" active={task}>
      <WorkbenchCatalogueBrowser catalogues={["reviewSessions", "adaptationDatasets"]} title="Browse saved review records" disabled={busy} />
      <WorkbenchComparison key={`comparison-${snapshot.project.id}`} snapshot={snapshot} imageId={imageId}
        busy={busy} volumeMode={volumeMode} volume={volumeWorkflow?.imageId === imageId ? volumeWorkflow : undefined}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)} />
      <WorkbenchReview key={`review-${snapshot.project.id}`} snapshot={snapshot} imageId={imageId}
        busy={busy} volumeMode={volumeMode} volume={volumeWorkflow?.imageId === imageId ? volumeWorkflow : undefined}
        read={(operation, args) => request(path, operation, args, snapshot.project.revision)}
        act={(operation, args) => run(() => mutate(operation, args))} />
      </WorkbenchTaskSection>
        </div>
      </div>
    </> : <div className="workbench-empty">
      <h2>A project shared with your tools</h2>
      <p>The graphical workbench, command line and MCP tools open the same project folder.
        Images, masks, measurements and correction history stay together.</p>
      {importRequested ? <p role="status">Image import is ready. Choose New project or Open project above, then import your images.</p> : null}
      <p>Classical segmentation runs locally without model weights. Install or repair the analysis runtime under AI agent access above.</p>
    </div>}
  </section></WorkbenchImageProvider></WorkbenchCatalogueProvider>;
}
