import { useCatalogueMany, useCataloguePins } from "./WorkbenchCatalogueBrowser";
import type { ImageAssignment } from "../../../../shared/workbench/protocol";
import WorkbenchImageSelector from "./WorkbenchImageSelector";
import { useEffect, useRef, useState } from "react";
import type {
  AnalysisParameters, ExperimentalDesign, ExperimentSummary, ProjectSnapshot,
  Specimen, WorkbenchWorkflow, WorkbenchJob, WorkbenchImage, WorkflowStep, WorkflowSegmentationStep, WorkflowMeasurementStep,
} from "../../../../shared/workbench/protocol";
import { DEFAULT_ANALYSIS } from "../../../../shared/workbench/protocol";
import type { VolumeWorkflowConfiguration } from "../../../../shared/workbench/volumeProtocol";
import { DEFAULT_VOLUME_PARAMETERS } from "../../../../shared/workbench/volumeProtocol";
import type { ParameterSpec, ParameterValue } from "../../../../shared/workbench/extensionProtocol";
import { inferenceSchemaFor, modelParameterIssues } from "../../../../shared/workbench/modelProtocol";
import PluginParameters from "./PluginParameters";
import WorkbenchAssaySummary from "./WorkbenchAssaySummary";
import AssayParameters from "./AssayParameters";
import WorkbenchWorkers from "./WorkbenchWorkers";
import { activeJobWorker, type JobWorker } from "../../../../shared/workbench/workerProtocol";
import type { SweepExportArguments, SweepExportFormat } from "../../../../shared/workbench/sweepProtocol";
import type { PreprocessingDraftStep } from "../../../../shared/workbench/preprocessingProtocol";
import { recipeFromDraft, recipeIsValid, recipeToDraft } from "../../../../shared/workbench/preprocessingProtocol";
import PreprocessingRecipeEditor from "./PreprocessingRecipeEditor";
import usePreprocessingCatalogue from "./usePreprocessingCatalogue";
import useModelCatalogue from "./useModelCatalogue";
import WorkbenchSweeps from "./WorkbenchSweeps";
import WorkbenchDistributed from "./WorkbenchDistributed";
import type { DistributedActions } from "../../../../shared/workbench/distributionProtocol";
import type { CreateWorkflowJob, GraphControlActions, PreviewGraphNode, SaveWorkflow } from "../../../../shared/workbench/graphProtocol";
import { isGraphWorkflow } from "../../../../shared/workbench/graphProtocol";
import WorkbenchGraphEditor from "./WorkbenchGraphEditor";
import WorkbenchGraphJob from "./WorkbenchGraphJob";
import WorkbenchExperimentRecords from "./WorkbenchExperimentRecords";
import type { ExperimentRecordActions } from "../../../../shared/workbench/experimentProtocol";
import ScientificOutput from "./ScientificOutput";

type Props = {
  snapshot: ProjectSnapshot; imageId: string; parameters: AnalysisParameters; busy: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void>;
  runJob: (id: string) => Promise<void>;
  stopJob: () => void;
  runningJobId: string;
  volumeMode: boolean;
  volume?: VolumeWorkflowConfiguration;
  readWorker: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  stopWorker: (workerId: string) => Promise<void>;
  onWorkerProgress: (workers: JobWorker[]) => void;
  chooseSweepDirectory: (selected: (path: string) => void) => Promise<void>;
  runSweep: (sweepId: string) => Promise<void>;
  stopSweep: () => void;
  runningSweepId: string;
  exportSweepResults: (format: SweepExportFormat, args: SweepExportArguments, name: string) => Promise<void>;
  distributedActions: DistributedActions;
  distributedWriteBlocked: boolean;
  saveWorkflow: SaveWorkflow;
  createWorkflowJob: CreateWorkflowJob;
  previewGraphNode: PreviewGraphNode;
  graphControls: GraphControlActions;
  experimentActions: ExperimentRecordActions;
  experimentWriteBlocked: boolean;
};
const num = (value: number | null) => value == null ? "—" : value.toLocaleString(undefined, { maximumFractionDigits: 2 });
const isSegmentation = (step: WorkflowStep): step is WorkflowSegmentationStep =>
  ["analysis", "volume-analysis", "plugin-segmentation", "model-segmentation"].includes(step.type);
const isMeasurement = (step: WorkflowStep): step is WorkflowMeasurementStep =>
  step.type === "plugin-measurement" || step.type === "assay";
type MeasurementDraft = { key: string; step: WorkflowMeasurementStep };
type SourceDraft = { label: string; volumeMode: boolean; parameters: AnalysisParameters; volume?: VolumeWorkflowConfiguration };

function DerivedCheckpointImages({ checkpoints, images }: { checkpoints: WorkbenchJob["checkpoints"]; images: WorkbenchImage[] }) {
  const [open, setOpen] = useState(false);
  const derived = checkpoints.filter((item) => item.derivedImageId);
  if (!derived.length) return null;
  const names = open ? new Map(images.map((image) => [image.id, image.name])) : undefined;
  return <details onToggle={(event) => setOpen(event.currentTarget.open)}>
    <summary>{derived.length} retained processed {derived.length === 1 ? "image" : "images"}</summary>
    {open ? <ul>{derived.map((item) => <li key={`${item.imageId}-${item.timeIndex ?? 0}-${item.channel ?? 0}`}>
      {names?.get(item.imageId) ?? item.imageId}
      {item.sourceSelection?.target === "volume" ? ` · time point ${item.sourceSelection.timeIndex + 1}` : ""}
      {item.sourceSelection ? ` · channel ${item.sourceSelection.channel + 1}` : ""}
      {" → "}{names?.get(item.derivedImageId!) ?? item.derivedImageId} · {item.status}
    </li>)}</ul> : null}
  </details>;
}

function LinearJobDetails({ jobId, revision, busy, read, images }: { jobId: string; revision: number; busy: boolean; read: Props["read"]; images: WorkbenchImage[] }) {
  const [open, setOpen] = useState(false), [error, setError] = useState("");
  const [loaded, setLoaded] = useState<{ revision: number; job: WorkbenchJob }>();
  const latest = useRef(read); latest.current = read;
  const pinError = useCataloguePins(open ? [{ catalogue: "jobs", entryId: jobId }] : []);
  useEffect(() => { let current = true; if (!open || busy) return;
    void latest.current<{ job: WorkbenchJob }>("job.get", { jobId }).then(value => { if (current) { setLoaded({ revision, job: value.job }); setError(""); } })
      .catch(cause => { if (current) setError(String(cause)); }); return () => { current = false; };
  }, [open, busy, jobId, revision]);
  const job = loaded?.revision === revision ? loaded.job : undefined;
  return <details open={open} onToggle={event => setOpen(event.currentTarget.open)}><summary>Saved checkpoints and batch result</summary>
    {error || pinError ? <p className="workbench-error" role="alert">{error || pinError}</p> : null}
    {job ? <><p>{job.checkpoints.length} retained source checkpoints.</p><DerivedCheckpointImages checkpoints={job.checkpoints} images={images} />
      {job.summary ? <ScientificOutput output={job.summary} /> : <p>The batch has not retained its summary yet.</p>}</> : null}
  </details>;
}

export default function WorkbenchAutomation({ snapshot, imageId, parameters, busy, read, act, runJob, stopJob, runningJobId, volumeMode, volume, readWorker, stopWorker, onWorkerProgress, chooseSweepDirectory, runSweep, stopSweep, runningSweepId, exportSweepResults, distributedActions, distributedWriteBlocked, saveWorkflow: persistWorkflow, createWorkflowJob, previewGraphNode, graphControls, experimentActions, experimentWriteBlocked }: Props) {
  const workflows = snapshot.workflows ?? [];
  const jobs = snapshot.jobs ?? [];
  const executionBusy = busy || (snapshot.jobWorkers ?? []).some(activeJobWorker);
  const design: ExperimentalDesign = snapshot.experimentalDesign ?? { specimens: [], plates: [], assignments: [] };
  const [workflowId, setWorkflowId] = useState("");
  const [structure, setStructure] = useState<"linear" | "dag">("linear");
  const [graphLoad, setGraphLoad] = useState<{ serial: number; workflow: WorkbenchWorkflow }>();
  const [chosenWorkflow, setChosenWorkflow] = useState<WorkbenchWorkflow>();
  const [versionLoading, setVersionLoading] = useState(false);
  const versionEpoch = useRef(0);
  const [workflowName, setWorkflowName] = useState("Cell analysis");
  const [editingWorkflowId, setEditingWorkflowId] = useState("");
  const [sourceDraft, setSourceDraft] = useState<SourceDraft>();
  const [exportPackage, setExportPackage] = useState(false);
  const [preprocessingEnabled, setPreprocessingEnabled] = useState(false);
  const [recipeSteps, setRecipeSteps] = useState<PreprocessingDraftStep[]>([]);
  const { catalogue, error: catalogueError, retry: retryCatalogue } = usePreprocessingCatalogue(read);
  const { catalogue: modelCatalogue, error: modelCatalogueError, retry: retryModelCatalogue } = useModelCatalogue(read);
  const [segmentationPluginId, setSegmentationPluginId] = useState("");
  const [segmentationModelId, setSegmentationModelId] = useState("");
  const [segmentationValues, setSegmentationValues] = useState<Record<string, ParameterValue>>({});
  const [measurementPluginId, setMeasurementPluginId] = useState("");
  const [assays, setAssays] = useState<{ id: string; name: string; dimensions: number[];
    parameters: { properties: Record<string, ParameterSpec>; required: string[] } }[]>([]);
  const [measurementSteps, setMeasurementSteps] = useState<MeasurementDraft[]>([]);
  const [newAssay, setNewAssay] = useState("morphology");
  const [scope, setScope] = useState<"selected" | "selection">("selected");
  const [batchImageIds, setBatchImageIds] = useState<string[]>([]);
  const scopedImageIds = scope === "selection" ? batchImageIds : imageId ? [imageId] : [];
  const [timeScope, setTimeScope] = useState<"all" | "current">("all");
  const [specimenId, setSpecimenId] = useState("");
  const [plateId, setPlateId] = useState("");
  const [row, setRow] = useState(1);
  const [column, setColumn] = useState(1);
  const [field, setField] = useState("");
  const [specimen, setSpecimen] = useState({ name: "", experiment: "", condition: "", role: "other" as Specimen["role"] });
  const [editingSpecimenId, setEditingSpecimenId] = useState("");
  const [plate, setPlate] = useState({ name: "", rows: 8, columns: 12 });
  const [editingPlateId, setEditingPlateId] = useState("");
  const [summary, setSummary] = useState<ExperimentSummary>();
  const [error, setError] = useState("");
  const revisionRef = useRef(snapshot.project.revision);
  const latestRead = useRef(read); latestRead.current = read;
  revisionRef.current = snapshot.project.revision;
  const latestWorkflow = workflows.find((item) => item.id === workflowId);
  const selectedWorkflow = chosenWorkflow?.id === workflowId ? chosenWorkflow : latestWorkflow;
  const savedFirstStep = selectedWorkflow?.steps.find(isSegmentation);
  const savedVolume = isGraphWorkflow(selectedWorkflow) ? selectedWorkflow?.graph?.target === "volume" :
    savedFirstStep?.type === "volume-analysis" || (savedFirstStep?.type === "plugin-segmentation" && savedFirstStep.target === "volume");
  const draftVolumeMode = sourceDraft?.volumeMode ?? volumeMode;
  const draftParameters = sourceDraft?.parameters ?? parameters;
  const draftVolume = sourceDraft ? sourceDraft.volume : volume;
  const dimension = draftVolumeMode ? 3 : 2;
  const plugins = (snapshot.plugins ?? []).filter((item) => item.enabled && item.manifest.supportedDimensions.includes(dimension));
  const segmentationPlugin = plugins.find((item) => item.pluginId === segmentationPluginId && item.manifest.kind === "segmentation");
  const segmentationModel = snapshot.models?.find((item) => item.id === segmentationModelId && item.enabled);
  const modelSchema = inferenceSchemaFor(segmentationModel, modelCatalogue);
  const modelIssues = segmentationModel ? modelParameterIssues(modelSchema, segmentationValues) : [];
  const measurementPlugin = plugins.find((item) => item.pluginId === measurementPluginId && item.manifest.kind === "measurement");
  const invalidPlugins = Boolean((segmentationPluginId && !segmentationPlugin) ||
    (segmentationModelId && (!segmentationModel || draftVolumeMode || modelIssues.length > 0)) ||
    measurementSteps.some(({ step }) => step.type === "assay"
      ? !assays.find((assay) => assay.id === step.assay)?.dimensions.includes(dimension)
      : !plugins.some((plugin) => plugin.pluginId === step.pluginId && plugin.manifest.kind === "measurement")));
  const invalidRecipe = preprocessingEnabled && !recipeIsValid(recipeSteps, catalogue, dimension);
  const maxMeasurementSteps = 20 - 3 - Number(preprocessingEnabled) - Number(exportPackage);
  const invalidDraft = (draftVolumeMode && !draftVolume) || invalidPlugins || invalidRecipe || measurementSteps.length > maxMeasurementSteps;
  const pinError = useCataloguePins([{ catalogue: "workflows", entryId: workflowId }, { catalogue: "specimens", entryId: specimenId }, { catalogue: "specimens", entryId: editingSpecimenId }, { catalogue: "plates", entryId: editingPlateId }, { catalogue: "plates", entryId: plateId }, { catalogue: "models", entryId: segmentationModelId }, { catalogue: "plugins", entryId: segmentationPluginId }, { catalogue: "plugins", entryId: measurementPluginId }, ...measurementSteps.flatMap(({ step }) => step.type === "plugin-measurement" ? [{ catalogue: "plugins" as const, entryId: step.pluginId }] : [])]);
  const assignmentScope = useCatalogueMany<ImageAssignment>("assignments", imageId ? [imageId] : []);
  const assignment = assignmentScope.entries[0];
  const assignedScope = useCatalogueMany<Specimen>("specimens", assignment?.specimenId ? [assignment.specimenId] : []);
  const assignedSpecimen = assignedScope.entries[0];

  useEffect(() => {
    let active = true;
    void latestRead.current<{ assays: typeof assays }>("assay.catalog").then((result) => { if (active) setAssays(result.assays); })
      .catch((cause) => { if (active) setError(String(cause)); });
    return () => { active = false; };
  }, []);

  useEffect(() => {
    setError(""); setSummary(undefined);
    setWorkflowId((old) => old || workflows[0]?.id || "");
    setSpecimenId((old) => old || design.specimens[0]?.id || "");
  }, [snapshot.project.id, snapshot.project.revision]);

  useEffect(() => {
    if (!assignmentScope.ready) return;
    if (assignment) {
      setSpecimenId(assignment.specimenId);
      setPlateId(assignment.plateId ?? "");
      setRow(assignment.wellRow ?? 1);
      setColumn(assignment.wellColumn ?? 1);
      setField(assignment.field ?? "");
    } else {
      setPlateId(""); setRow(1); setColumn(1); setField("");
    }
  }, [imageId, assignmentScope.ready, assignment?.specimenId, assignment?.plateId, assignment?.wellRow, assignment?.wellColumn, assignment?.field]);

  const loadWorkflow = (workflow: WorkbenchWorkflow) => {
    if (isGraphWorkflow(workflow)) {
      if (!workflow.graph) { setError("This saved branching workflow is missing its graph. Reopen the project before editing it."); return; }
      setWorkflowId(workflow.id); setStructure("dag");
      setGraphLoad((old) => ({ serial: (old?.serial ?? 0) + 1, workflow }));
      setError(""); return;
    }
    const first = workflow.steps.find(isSegmentation);
    if (!first) { setError("This workflow has no supported segmentation step."); return; }
    const isVolume = first.type === "volume-analysis" || (first.type === "plugin-segmentation" && first.target === "volume");
    const planeParameters = first.type === "analysis" ? first.parameters :
      first.type === "plugin-segmentation" || first.type === "model-segmentation"
        ? { ...DEFAULT_ANALYSIS, ...first.sourceParameters } : { ...DEFAULT_ANALYSIS };
    setSourceDraft({ label: `${workflow.name} · version ${workflow.version}`, volumeMode: isVolume,
      parameters: { ...planeParameters }, ...(isVolume ? { volume: {
        imageId, timeIndex: 0,
        channel: first.type === "volume-analysis" || first.type === "plugin-segmentation" ? first.channel ?? 0 : 0,
        parameters: { ...(first.type === "volume-analysis" ? first.parameters : DEFAULT_VOLUME_PARAMETERS) },
      } } : {}) });
    setWorkflowId(workflow.id); setEditingWorkflowId(workflow.id); setStructure("linear");
    setWorkflowName(workflow.name); setExportPackage(workflow.steps.some((step) => step.type === "export"));
    setSegmentationPluginId(first.type === "plugin-segmentation" ? first.pluginId : "");
    setSegmentationModelId(first.type === "model-segmentation" ? first.modelId : "");
    setSegmentationValues(first.type === "plugin-segmentation" ? { ...first.pluginParameters } :
      first.type === "model-segmentation" ? { ...first.modelParameters } : {});
    const preprocessing = workflow.steps.find((step) => step.type === "preprocessing");
    setPreprocessingEnabled(Boolean(preprocessing));
    setRecipeSteps(recipeToDraft(preprocessing?.recipe ?? []));
    setMeasurementSteps(workflow.steps.filter(isMeasurement).map((step) => ({
      key: crypto.randomUUID(), step: step.type === "assay" ?
        { type: "assay", assay: step.assay, assayParameters: { ...step.assayParameters } } :
        { type: "plugin-measurement", pluginId: step.pluginId, pluginParameters: { ...step.pluginParameters } },
    })));
    setError("");
  };
  const moveMeasurement = (index: number, direction: -1 | 1) => {
    setMeasurementSteps((old) => {
      const next = [...old]; [next[index], next[index + direction]] = [next[index + direction], next[index]]; return next;
    });
  };
  const saveWorkflow = (update: boolean) => {
    if (invalidDraft || (update && editingWorkflowId !== workflowId)) return;
    const steps: WorkbenchWorkflow["steps"] = [
      ...(preprocessingEnabled ? [{ type: "preprocessing" as const, recipe: recipeFromDraft(recipeSteps) }] : []),
      segmentationModel ? { type: "model-segmentation", modelId: segmentationModel.id,
        modelParameters: segmentationValues, sourceParameters: draftParameters }
        : segmentationPlugin ? { type: "plugin-segmentation", pluginId: segmentationPlugin.pluginId,
        pluginParameters: segmentationValues, target: draftVolumeMode ? "volume" : "plane",
        ...(draftVolumeMode && draftVolume ? { channel: draftVolume.channel } : { sourceParameters: draftParameters }) }
        : draftVolumeMode && draftVolume ? { type: "volume-analysis", parameters: draftVolume.parameters, channel: draftVolume.channel }
        : { type: "analysis", parameters: draftParameters },
      ...measurementSteps.map((item) => item.step),
      { type: "measurements" }, { type: "summary" },
      ...(exportPackage ? [{ type: "export" as const }] : []),
    ];
    return persistWorkflow("workflow.save", { name: workflowName, steps, ...(update ? { workflowId } : {}) }, (workflow) => {
      setWorkflowId(workflow.id); setChosenWorkflow(workflow); setEditingWorkflowId(workflow.id);
    });
  };
  const createJob = async () => {
    if (!selectedWorkflow) return;
    await createWorkflowJob(selectedWorkflow, scopedImageIds,
      savedVolume && timeScope === "current" && volume ? [volume.timeIndex] : undefined);
  };
  const chooseVersion = async (version: number) => {
    if (!latestWorkflow || busy) return;
    const generation = ++versionEpoch.current; setVersionLoading(true); setError("");
    try {
      const result = await read<{ workflow: WorkbenchWorkflow }>("workflow.get", { workflowId: latestWorkflow.id, version });
      if (generation === versionEpoch.current) setChosenWorkflow(result.workflow);
    } catch (cause) { if (generation === versionEpoch.current) setError(String(cause)); }
    finally { if (generation === versionEpoch.current) setVersionLoading(false); }
  };

  return <div className="workbench-automation">
    {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <details open><summary>Workflows and batches</summary>
      <p>Save these analysis settings, then apply them to selected images. Completed steps are checkpointed so interrupted batches can resume.</p>
      <label>Workflow structure<select value={structure} disabled={busy} onChange={(event) => setStructure(event.target.value as "linear" | "dag")}>
        <option value="linear">Linear</option><option value="dag">Branching</option>
      </select><small>Switching structure preserves both editor drafts. Saved workflows are loaded only when requested.</small></label>
      <div className="workbench-editor-grid">
        <div>
        <fieldset hidden={structure !== "linear"} disabled={executionBusy || distributedWriteBlocked}>
          <h3>{sourceDraft ? "Edit saved" : "Save current"} {draftVolumeMode ? "volume" : "projection"} settings</h3>
          {sourceDraft ? <p>Source settings loaded from {sourceDraft.label}.{" "}
            <button type="button" className="cc-btn" onClick={() => setSourceDraft(undefined)}>Use current image settings</button></p> : null}
          <label>Workflow name<input value={workflowName} onChange={(event) => setWorkflowName(event.target.value)} /></label>
          <label className="workbench-inline"><input type="checkbox" checked={preprocessingEnabled}
            onChange={(event) => setPreprocessingEnabled(event.target.checked)} />Preprocess before segmentation</label>
          {preprocessingEnabled ? <>
            {catalogueError ? <p className="workbench-error" role="alert">{catalogueError}{" "}
              <button type="button" className="cc-btn" onClick={retryCatalogue}>Retry filter catalogue</button></p> : null}
            <PreprocessingRecipeEditor catalogue={catalogue} steps={recipeSteps} dimension={dimension} onChange={setRecipeSteps} />
            <p>The segmentation source settings select the channel and {draftVolumeMode ? "time-point volume" : "Z projection"} to process.
              Each unit retains a new processed image. Later steps use its first channel and {draftVolumeMode ? "first time point" : "complete saved plane"}.
              Processed intensities remain labeled separately, and biological specimen assignments are not copied.</p>
            <p>Assays requiring additional source channels or a separate nuclear mask cannot use this single-channel workflow output.</p>
          </> : null}
          <label>Segmentation<select value={segmentationModelId ? `model:${segmentationModelId}` : segmentationPluginId} onChange={(event) => {
            const value = event.target.value;
            setSegmentationPluginId(value.startsWith("model:") ? "" : value);
            setSegmentationModelId(value.startsWith("model:") ? value.slice(6) : "");
            setSegmentationValues({});
          }}>
            <option value="">{sourceDraft ? "Saved threshold settings" : "Current threshold settings"}</option>
            {plugins.filter((item) => item.manifest.kind === "segmentation").map((item) =>
              <option key={item.pluginId} value={item.pluginId}>{item.manifest.name} · {item.manifest.version}</option>)}
            {(snapshot.models ?? []).filter((item) => item.enabled).map((item) =>
              <option key={item.id} value={`model:${item.id}`} disabled={draftVolumeMode}>
                {item.name} · {modelCatalogue?.backends.find((backend) => backend.id === item.backend)?.name ?? item.backend} (2D)
              </option>)}
            {segmentationModelId && !segmentationModel ? <option value={`model:${segmentationModelId}`} disabled>Selected model is disabled or unavailable</option> : null}
            {segmentationPluginId && !segmentationPlugin ? <option value={segmentationPluginId} disabled>Selected plugin unavailable for this dimension</option> : null}
          </select></label>
          {segmentationPlugin ? <PluginParameters plugin={segmentationPlugin} values={segmentationValues} onChange={setSegmentationValues} /> : null}
          {segmentationModel ? <>
            {modelCatalogueError && !modelSchema ? <p className="workbench-error" role="alert">{modelCatalogueError}{" "}
              <button type="button" className="cc-btn" onClick={retryModelCatalogue}>Retry model catalogue</button></p> : null}
            {modelSchema ? <PluginParameters schema={modelSchema} values={segmentationValues} onChange={setSegmentationValues} /> : null}
            {modelIssues.map((issue) => <p key={issue} className="workbench-error" role="alert">{issue}</p>)}
            <p>{(segmentationModel.notes ?? modelCatalogue?.backends.find((backend) => backend.id === segmentationModel.backend)?.notes ?? []).join(" ")}</p>
          </> : null}
          <label>Add measurement plugin<select value={measurementPluginId} onChange={(event) => setMeasurementPluginId(event.target.value)}>
            <option value="">Choose a plugin</option>
            {plugins.filter((item) => item.manifest.kind === "measurement").map((item) =>
              <option key={item.pluginId} value={item.pluginId}>{item.manifest.name} · {item.manifest.version}</option>)}
            {measurementPluginId && !measurementPlugin ? <option value={measurementPluginId} disabled>Selected plugin unavailable for this dimension</option> : null}
          </select></label>
          <button type="button" className="cc-btn" disabled={!measurementPlugin || measurementSteps.length >= maxMeasurementSteps}
            onClick={() => measurementPlugin && setMeasurementSteps((old) => [...old, {
              key: crypto.randomUUID(), step: { type: "plugin-measurement", pluginId: measurementPlugin.pluginId, pluginParameters: {} },
            }])}>Add measurement step</button>
          <label>Add built-in assay<select value={newAssay} onChange={(event) => setNewAssay(event.target.value)}>
            {assays.map((item) => <option key={item.id} value={item.id} disabled={!item.dimensions.includes(dimension)}>{item.name}</option>)}
          </select></label>
          <button type="button" className="cc-btn" disabled={measurementSteps.length >= maxMeasurementSteps || !assays.find((item) => item.id === newAssay)?.dimensions.includes(dimension)}
            onClick={() => setMeasurementSteps((old) => [...old, {
              key: crypto.randomUUID(), step: { type: "assay", assay: newAssay, assayParameters: {} },
            }])}>Add assay to workflow</button>
          <ol className="workbench-recipe">{measurementSteps.map(({ key, step }, index) => {
            const definition = step.type === "assay" ? assays.find((item) => item.id === step.assay) : undefined;
            const plugin = step.type === "plugin-measurement" ? (snapshot.plugins ?? []).find((item) => item.pluginId === step.pluginId) : undefined;
            const title = step.type === "assay" ? definition?.name ?? step.assay : plugin?.manifest.name ?? step.pluginId;
            return <li key={key}><h4>{index + 1}. {title}</h4>
              {step.type === "assay" && definition ? <AssayParameters schema={definition.parameters} values={step.assayParameters ?? {}}
                imageId={imageId} images={snapshot.images} zProjection={draftParameters.zProjection}
                onChange={(values) => setMeasurementSteps((old) => old.map((item) => item.key === key
                  ? { ...item, step: { ...step, assayParameters: values } } : item))} /> : null}
              {step.type === "plugin-measurement" && plugin ? <PluginParameters plugin={plugin} values={step.pluginParameters ?? {}}
                onChange={(values) => setMeasurementSteps((old) => old.map((item) => item.key === key
                  ? { ...item, step: { ...step, pluginParameters: values } } : item))} /> : null}
              {step.type === "assay" ? !definition?.dimensions.includes(dimension)
                ? <p className="workbench-error">This assay is unavailable for the selected dimension.</p> : null
                : !plugin?.enabled || !plugin.manifest.supportedDimensions.includes(dimension)
                  ? <p className="workbench-error">This plugin is disabled or unavailable for the selected dimension.</p> : null}
              <div className="workbench-actions">
                <button type="button" className="cc-btn" disabled={index === 0} aria-label={`Move ${title} step ${index + 1} earlier`}
                  onClick={() => moveMeasurement(index, -1)}>Move earlier</button>
                <button type="button" className="cc-btn" disabled={index === measurementSteps.length - 1} aria-label={`Move ${title} step ${index + 1} later`}
                  onClick={() => moveMeasurement(index, 1)}>Move later</button>
                <button type="button" className="cc-btn" aria-label={`Remove ${title} step ${index + 1}`}
                  onClick={() => setMeasurementSteps((old) => old.filter((item) => item.key !== key))}>Remove step</button>
              </div>
            </li>;
          })}</ol>
          {measurementSteps.length > maxMeasurementSteps ? <p className="workbench-error" role="alert">
            This workflow exceeds 20 steps. Remove a measurement step or an optional preprocessing/export step.</p> : null}
          <ol className="workbench-steps">
            {preprocessingEnabled ? <li><strong>Preprocess</strong><span>{recipeSteps.map((step) =>
              catalogue?.filters.find((filter) => filter.method === step.method)?.name ?? step.method).join(" → ") || "Add a filter"}</span></li> : null}
            <li><strong>Analyze</strong><span>{segmentationModel ? segmentationModel.name : segmentationPlugin ? segmentationPlugin.manifest.name : draftVolumeMode
              ? `${draftVolume?.parameters.method ?? "Loading"} · channel ${(draftVolume?.channel ?? 0) + 1} · full 3D volume`
              : `${draftParameters.method} · channel ${draftParameters.channel + 1} · ${draftParameters.zProjection} projection`}</span></li>
            {measurementSteps.map(({ key, step }) => <li key={key}><strong>{step.type === "assay" ? "Assay" : "Plugin measurements"}</strong>
              <span>{step.type === "assay" ? assays.find((item) => item.id === step.assay)?.name ?? step.assay :
                snapshot.plugins?.find((item) => item.pluginId === step.pluginId)?.manifest.name ?? step.pluginId}</span></li>)}
            <li><strong>Measure</strong><span>Exact masks, {preprocessingEnabled ? "processed" : "selected source"} intensities and current calibration</span></li>
            <li><strong>Summarize</strong><span>Descriptive results for the selected images</span></li>
            {exportPackage ? <li><strong>Export</strong><span>Choose a new ZIP for each run</span></li> : null}
          </ol>
          <label className="workbench-inline"><input type="checkbox" checked={exportPackage}
            onChange={(event) => setExportPackage(event.target.checked)} />Export after completion</label>
          <div className="workbench-actions">
            <button className="cc-btn" disabled={!workflowName.trim() || invalidDraft} onClick={() => void saveWorkflow(false)}>Save new workflow</button>
            <button className="cc-btn" disabled={!workflowId || editingWorkflowId !== workflowId || !workflowName.trim() || invalidDraft} onClick={() => void saveWorkflow(true)}>Save as next version</button>
          </div>
        </fieldset>
        <WorkbenchGraphEditor active={structure === "dag"} snapshot={snapshot} imageId={imageId}
          imageIds={scopedImageIds}
          volumeMode={volumeMode} volume={volume} parameters={parameters} currentTimeOnly={timeScope === "current"}
          busy={executionBusy} writeBlocked={distributedWriteBlocked} load={graphLoad} selectedWorkflowId={workflowId}
          assays={assays} read={read} saveWorkflow={persistWorkflow}
          onSaved={(workflow) => { setWorkflowId(workflow.id); setChosenWorkflow(workflow); }} />
        </div>
        <fieldset disabled={executionBusy || versionLoading}>
          <label>Saved workflow<select value={workflowId} onChange={(event) => {
            versionEpoch.current++; setVersionLoading(false); setWorkflowId(event.target.value); setChosenWorkflow(undefined);
          }}>
            {!workflows.length ? <option value="">Save a workflow first</option> : null}
            {workflows.map((item) => <option key={item.id} value={item.id}>{item.name} · {isGraphWorkflow(item) ? "Branching" : "Linear"} · latest version {item.version}</option>)}
          </select></label>
          {latestWorkflow && selectedWorkflow ? <label>Saved version<select value={selectedWorkflow.version}
            onChange={(event) => void chooseVersion(Number(event.target.value))}>
            {Array.from({ length: latestWorkflow.version }, (_, index) => latestWorkflow.version - index).map((version) =>
              <option value={version} key={version}>Version {version}{version === latestWorkflow.version ? " · latest" : ""}</option>)}
          </select></label> : null}
          <button type="button" className="cc-btn" disabled={!selectedWorkflow} onClick={() => {
            if (selectedWorkflow) loadWorkflow(selectedWorkflow);
          }}>Load saved workflow for editing</button>
          {selectedWorkflow ? isGraphWorkflow(selectedWorkflow) ? <details><summary>Saved branch connections</summary>
            <ul>{selectedWorkflow.graph?.nodes.map((node) => <li key={node.id}><strong>{node.name ?? node.id}</strong> · {node.type}
              {" ← "}{(node.inputs ?? (node.input ? [node.input] : [])).map((id) => id === "$source" ? "Original source"
                : selectedWorkflow.graph?.nodes.find((item) => item.id === id)?.name ?? id).join(" + ")}</li>)}</ul>
            <p>Branches preserve distinct masks and source/time identities. Summary references do not pool technical alternatives.</p>
          </details> : <p>Saved steps: {selectedWorkflow.steps.map((step) => step.type).join(" → ")}</p> : null}
          <label>Images<select value={scope} onChange={(event) => setScope(event.target.value as "selection" | "selected")}>
            <option value="selection">Explicit image selection across pages</option>
            <option value="selected">Selected image</option>
          </select></label>
          {scope === "selection" ? <WorkbenchImageSelector label="Workflow input images" multiple selectedIds={batchImageIds} onChange={setBatchImageIds} disabled={executionBusy || distributedWriteBlocked} /> : null}
          <p>{scopedImageIds.length} explicitly scoped images from {snapshot.imageCount ?? snapshot.images.length} retained acquisitions. The same scope is used for batches, sweeps and distributed tasks.</p>
          {savedVolume || structure === "dag" ? <label>Time points for volume workflows<select value={timeScope}
            onChange={(event) => setTimeScope(event.target.value as "all" | "current")}>
            <option value="all">All time points in each image</option>
            <option value="current" disabled={!volumeMode || !volume}>Current time point ({(volume?.timeIndex ?? 0) + 1}) in each image</option>
          </select></label> : null}
          <button className="cc-btn" disabled={distributedWriteBlocked || !workflowId || !scopedImageIds.length ||
            (savedVolume && timeScope === "current" && (!volumeMode || !volume))}
            onClick={() => void createJob().catch((cause) => setError(String(cause)))}>Create batch</button>
          <p>A batch keeps its saved workflow version. Later edits to a mask or calibration block affected pending work so corrections are preserved.</p>
          {distributedWriteBlocked ? <p>Save or discard pending scientific edits before creating or executing a batch.</p> : null}
        </fieldset>
      </div>
      <WorkbenchSweeps snapshot={snapshot} workflow={selectedWorkflow} busy={busy} read={read} act={act}
        imageIds={scopedImageIds}
        timeIndices={savedVolume && timeScope === "current" && volume ? [volume.timeIndex] : undefined}
        scopeValid={!(savedVolume && timeScope === "current" && (!volumeMode || !volume))}
        chooseDirectory={chooseSweepDirectory} runSweep={runSweep} stopSweep={stopSweep} runningSweepId={runningSweepId}
        exportResults={exportSweepResults} />
      <WorkbenchDistributed snapshot={snapshot} workflow={selectedWorkflow} busy={busy} read={read}
        actions={distributedActions} writeBlocked={distributedWriteBlocked}
        imageIds={scopedImageIds}
        timeIndices={savedVolume && timeScope === "current" && volume ? [volume.timeIndex] : undefined}
        scopeValid={!(savedVolume && timeScope === "current" && (!volumeMode || !volume))} />
      <ul className="workbench-jobs">{jobs.map((job) => <li key={job.id}>
        <div><strong>{job.name || job.workflow.name}</strong><span>{job.status} · {job.progress.completed} / {job.progress.total} steps</span></div>
        <progress aria-label={`${job.name} progress`} value={job.progress.completed} max={job.progress.total || 1} />
        {job.error ? <p className="workbench-error">{job.error.details?.nodeId
          ? `${job.workflow.graph?.nodes.find((node) => node.id === job.error!.details!.nodeId)?.name ?? job.error.details.nodeId}: ` : ""}{job.error.message}</p> : null}
        {job.nextUnit?.type === "preprocessing" ? <p>Next step: create the retained processed image.</p> : null}
        {isGraphWorkflow(job.workflow) ? <WorkbenchGraphJob job={job} snapshot={snapshot} busy={executionBusy} writeBlocked={distributedWriteBlocked} controls={graphControls} read={read} previewNode={previewGraphNode} />
          : <LinearJobDetails jobId={job.id} revision={snapshot.project.revision} busy={executionBusy} read={read} images={snapshot.images} />}
        {job.outputsCurrent === false ? <p>Analysis inputs or experimental design changed after this batch captured its results. Create a new batch to recompute.</p> : null}
        <div className="workbench-actions">
          {["pending", "running"].includes(job.status) ? <>
            <button className="cc-btn" disabled={executionBusy || distributedWriteBlocked} onClick={() => void act("job.advance", { jobId: job.id })}>Run next checkpoint</button>
            <button className="cc-btn" disabled={executionBusy || distributedWriteBlocked} onClick={() => void runJob(job.id)}>Run remaining in this window</button>
            <button className="cc-btn" disabled={executionBusy || distributedWriteBlocked} onClick={() => void act("job.pause", { jobId: job.id })}>Pause</button>
          </> : null}
          {job.status === "paused" ? <button className="cc-btn" disabled={executionBusy || distributedWriteBlocked} onClick={() => void act("job.resume", { jobId: job.id })}>Resume</button> : null}
          {job.status === "failed" || (job.status === "blocked" && isGraphWorkflow(job.workflow) && !job.pendingReview) ? <button className="cc-btn" disabled={executionBusy || distributedWriteBlocked} onClick={() => void act("job.retry", { jobId: job.id })}>Retry pending checkpoint</button> : null}
          {!["completed", "cancelled"].includes(job.status) ? <button className="cc-btn" disabled={executionBusy || distributedWriteBlocked}
            onClick={() => void act("job.cancel", { jobId: job.id })}>Cancel batch</button> : null}
        </div>
      </li>)}</ul>
      {runningJobId ? <button className="cc-btn" onClick={stopJob}>Stop batch after current step</button> : null}
      <WorkbenchWorkers snapshot={snapshot} busy={busy} read={readWorker} act={act} stop={stopWorker} onProgress={onWorkerProgress} />
    </details>
    <details><summary>Experiments, specimens and plates</summary>
      <p>Assign fields of view to their biological specimen. Summaries count specimens as replicates.</p>
      <WorkbenchExperimentRecords snapshot={snapshot} busy={busy} writeBlocked={experimentWriteBlocked} actions={experimentActions} read={read} />
      <div className="workbench-editor-grid">
        <fieldset disabled={busy}>
          <h3>Biological specimen</h3>
          <label>Existing specimen<select value={editingSpecimenId} onChange={(event) => {
            setEditingSpecimenId(event.target.value);
            const item = design.specimens.find((candidate) => candidate.id === event.target.value);
            setSpecimen(item ? { name: item.name, experiment: item.experiment, condition: item.condition, role: item.role }
              : { name: "", experiment: "", condition: "", role: "other" });
          }}><option value="">New specimen</option>{design.specimens.map((item) => <option key={item.id} value={item.id}>{item.experiment} · {item.name}</option>)}</select></label>
          {(["name", "experiment", "condition"] as const).map((key) => <label key={key}>{key === "name" ? "Specimen name" : key === "experiment" ? "Experiment" : "Condition"}
            <input value={specimen[key]} onChange={(event) => setSpecimen((old) => ({ ...old, [key]: event.target.value }))} /></label>)}
          <label>Condition role<select value={specimen.role} onChange={(event) => setSpecimen((old) => ({ ...old, role: event.target.value as Specimen["role"] }))}>
            <option value="control">Control</option><option value="treatment">Treatment</option><option value="other">Other</option></select></label>
          <button className="cc-btn" disabled={!specimen.name.trim() || !specimen.experiment.trim() || !specimen.condition.trim()}
            onClick={() => void act("specimen.set", { ...specimen, ...(editingSpecimenId ? { specimenId: editingSpecimenId } : {}) })}>Save specimen</button>
        </fieldset>
        <fieldset disabled={busy}>
          <h3>Plate layout</h3>
          <label>Existing plate<select value={editingPlateId} onChange={(event) => {
            setEditingPlateId(event.target.value);
            const item = design.plates.find((candidate) => candidate.id === event.target.value);
            setPlate(item ? { name: item.name, rows: item.rows, columns: item.columns } : { name: "", rows: 8, columns: 12 });
          }}><option value="">New plate</option>{design.plates.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
          <label>Plate name<input value={plate.name} onChange={(event) => setPlate((old) => ({ ...old, name: event.target.value }))} /></label>
          <label>Rows<input type="number" min="1" max="100" value={plate.rows}
            onChange={(event) => setPlate((old) => ({ ...old, rows: Number(event.target.value) }))} /></label>
          <label>Columns<input type="number" min="1" max="100" value={plate.columns}
            onChange={(event) => setPlate((old) => ({ ...old, columns: Number(event.target.value) }))} /></label>
          <button className="cc-btn" disabled={!plate.name.trim()} onClick={() => void act("plate.set", { ...plate,
            ...(editingPlateId ? { plateId: editingPlateId } : {}) })}>Save plate</button>
        </fieldset>
        <fieldset disabled={busy || !imageId || !assignmentScope.ready || !!assignmentScope.error || !assignedScope.ready || !!assignedScope.error}>
          <h3>Assign selected image</h3>
          <p>{!assignmentScope.ready || !assignedScope.ready ? "Reading this image's exact assignment…" : assignmentScope.error || assignedScope.error || (assignedSpecimen ? `Assigned to ${assignedSpecimen.name} · ${assignedSpecimen.condition}` : "No biological specimen assigned.")}</p>
          <label>Specimen<select value={specimenId} onChange={(event) => setSpecimenId(event.target.value)}>
            {!design.specimens.length ? <option value="">Create a specimen first</option> : null}
            {design.specimens.map((item) => <option key={item.id} value={item.id}>{item.experiment} · {item.name} · {item.condition}</option>)}</select></label>
          <label>Plate<select value={plateId} onChange={(event) => setPlateId(event.target.value)}>
            <option value="">No plate</option>{design.plates.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
          {plateId ? <>
            <label>Well row (starting at 1)<input type="number" min="1" value={row} onChange={(event) => setRow(Number(event.target.value))} /></label>
            <label>Well column (starting at 1)<input type="number" min="1" value={column} onChange={(event) => setColumn(Number(event.target.value))} /></label>
          </> : null}
          <label>Field of view (optional)<input value={field} onChange={(event) => setField(event.target.value)} /></label>
          <div className="workbench-actions">
            <button className="cc-btn" disabled={!specimenId} onClick={() => void act("image.assign", {
              imageIds: [imageId], specimenId, ...(plateId ? { plateId, wellRow: row, wellColumn: column } : {}), ...(field.trim() ? { field: field.trim() } : {}),
            })}>Assign image</button>
            <button className="cc-btn" disabled={!assignment} onClick={() => void act("image.unassign", { imageIds: [imageId] })}>Remove assignment</button>
          </div>
        </fieldset>
      </div>
      <button className="cc-btn" disabled={busy} onClick={() => {
        const revision = snapshot.project.revision;
        void read<ExperimentSummary>("experiment.summary").then((result) => {
          if (revisionRef.current === revision) setSummary(result);
        }).catch((cause) => { if (revisionRef.current === revision) setError(String(cause)); });
      }}>Summarize biological replicates</button>
      {summary ? <div className="workbench-table">
        <table><caption>Complete biological specimens · {summary.unassignedImageCount} unassigned images</caption>
          <thead><tr><th>Experiment</th><th>Condition</th><th>Biological n</th><th>Incomplete</th><th>Mean objects / image</th><th>SD across specimens</th><th>Mean area µm²</th><th>Physical n</th></tr></thead>
          <tbody>{summary.conditions.map((item) => <tr key={JSON.stringify([item.experiment, item.condition])}>
            <td>{item.experiment}</td><td>{item.condition}</td><td>{item.biologicalN}</td><td>{item.excludedIncompleteSpecimens}</td>
            <td>{num(item.meanObjectsPerImage)}</td><td>{num(item.sdObjectsPerImage)}</td><td>{num(item.meanObjectAreaUm2)}</td><td>{item.physicalBiologicalN}</td>
          </tr>)}</tbody>
        </table><p>{summary.notes.join(" ")}</p>
      </div> : null}
      <WorkbenchAssaySummary snapshot={snapshot} busy={busy} read={read} />
    </details>
  </div>;
}
