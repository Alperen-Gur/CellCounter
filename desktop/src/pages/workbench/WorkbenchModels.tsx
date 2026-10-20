import { useEffect, useRef, useState } from "react";
import type { AnalysisParameters, ProjectSnapshot } from "../../../../shared/workbench/protocol";
import type { ParameterSpec, ParameterValue } from "../../../../shared/workbench/extensionProtocol";
import { inferenceSchemaFor, modelParameterIssues, type ModelBackend, type TrainingJob } from "../../../../shared/workbench/modelProtocol";
import PluginParameters from "./PluginParameters";
import ScientificOutput from "./ScientificOutput";
import useModelCatalogue from "./useModelCatalogue";
import WorkbenchModelEnvironment from "./WorkbenchModelEnvironment";
import WorkbenchCatalogueBrowser, { useCataloguePins } from "./WorkbenchCatalogueBrowser";
import type { CataloguePage } from "../../../../shared/workbench/catalogueProtocol";

type Props = {
  snapshot: ProjectSnapshot; imageId: string; parameters: AnalysisParameters; busy: boolean; volumeMode: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void>;
  captureEnvironment: (modelId: string) => Promise<void>;
  environmentWriteBlocked: boolean;
  chooseFile: (title: string, selected: (path: string) => void) => Promise<void>;
};
const trainingSchema: { properties: Record<string, ParameterSpec>; required: string[] } = {
  required: ["epochs", "learningRate", "batchSize"], properties: {
    epochs: { type: "integer", title: "Maximum epochs", minimum: 6, maximum: 2000, default: 100 },
    learningRate: { type: "number", title: "Learning rate", minimum: .000001, maximum: 1, default: .01 },
    batchSize: { type: "integer", title: "Batch size", minimum: 1, maximum: 32, default: 8 },
    augment: { type: "boolean", title: "Augment training images", default: true },
    earlyStop: { type: "boolean", title: "Stop when validation stops improving", default: true },
    seed: { type: "integer", title: "Random seed", minimum: 0, maximum: 4294967295, default: 42 },
    device: { type: "string", title: "Compute device", enum: ["auto", "cpu"], default: "auto" },
    timeoutSeconds: { type: "integer", title: "Maximum run time (seconds)", minimum: 60, maximum: 86400, default: 21600 },
  },
};
const activeStatuses = ["queued", "starting", "running", "cancelling"];

export default function WorkbenchModels({ snapshot, imageId, parameters, busy, volumeMode, read, act, captureEnvironment, environmentWriteBlocked, chooseFile }: Props) {
  const models = snapshot.models ?? [];
  const datasets = snapshot.adaptationDatasets ?? [];
  const [expanded, setExpanded] = useState(false);
  const [modelId, setModelId] = useState("");
  const [datasetId, setDatasetId] = useState("");
  const [name, setName] = useState("");
  const [backend, setBackend] = useState<ModelBackend>();
  const { catalogue, error: catalogueError, retry: retryCatalogue } = useModelCatalogue(read);
  const [pythonPath, setPythonPath] = useState("");
  const [checkpointPath, setCheckpointPath] = useState("");
  const [registrationByBackend, setRegistrationByBackend] = useState<Partial<Record<ModelBackend, {
    files: Partial<Record<"configPath" | "thresholdsPath", string>>; values: Record<string, ParameterValue>;
  }>>>({});
  const [binding, setBinding] = useState("");
  const [inferenceByModel, setInferenceByModel] = useState<Record<string, Record<string, ParameterValue>>>({});
  const [training, setTraining] = useState<Record<string, ParameterValue>>({ epochs: 100, learningRate: .01, batchSize: 8 });
  const [trainingName, setTrainingName] = useState("Adapted model");
  const jobs = snapshot.trainingJobs ?? [];
  const [historyJobs, setHistoryJobs] = useState<{ revision: number; entries: TrainingJob[] }>();
  const [probe, setProbe] = useState<unknown>();
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const pinError = useCataloguePins([{ catalogue: "models", entryId: modelId }, { catalogue: "adaptationDatasets", entryId: datasetId }]);
  const epoch = useRef(0);
  const model = models.find((item) => item.id === modelId);
  const registrationId = backend ?? catalogue?.defaultBackend;
  const registrationBackend = catalogue?.backends.find((item) => item.id === registrationId);
  const registration = registrationId ? registrationByBackend[registrationId] : undefined;
  const registrationValues = registration?.values ?? {};
  const registrationFiles = registration?.files ?? {};
  const setRegistrationValues = (values: Record<string, ParameterValue>) => {
    if (registrationId) setRegistrationByBackend(old => ({ ...old, [registrationId]: { files: old[registrationId]?.files ?? {}, values } }));
  };
  const setRegistrationFile = (key: "configPath" | "thresholdsPath", value: string) => {
    if (registrationId) setRegistrationByBackend(old => ({ ...old, [registrationId]: {
      values: old[registrationId]?.values ?? {}, files: { ...old[registrationId]?.files, [key]: value },
    } }));
  };
  const registrationIssues = registrationBackend?.registrationSchema
    ? modelParameterIssues(registrationBackend.registrationSchema, registrationValues) : [];
  const missingFile = registrationBackend?.fileInputs?.some(file => file.required && !registrationFiles[file.key]?.trim());
  const selectedBackend = catalogue?.backends.find((item) => item.id === model?.backend);
  const inferenceSchema = inferenceSchemaFor(model, catalogue);
  const inference = inferenceByModel[modelId] ?? {};
  const setInference = (values: Record<string, ParameterValue>) =>
    setInferenceByModel((old) => ({ ...old, [modelId]: values }));
  const inferenceIssues = model ? modelParameterIssues(inferenceSchema, inference) : [];
  const supportsTraining = model?.supportsTraining ?? selectedBackend?.supportsTraining ?? false;
  const inferenceNotes = model?.notes ?? selectedBackend?.notes ?? [];

  useEffect(() => {
    epoch.current++;
    setModelId((id) => id || models[0]?.id || "");
    setDatasetId((id) => id || datasets[0]?.id || "");
    setLoading(false); setProbe(undefined); setError("");
    return () => { epoch.current++; };
  }, [snapshot.project.revision]);
  useEffect(() => { setBinding(model?.pythonPath ?? ""); setProbe(undefined); }, [modelId, model?.pythonPath]);

  // Live training activity comes from the existing host/session loop. History
  // is requested explicitly in bounded pages, never from a second timer.

  const inspect = async (operation: string, args: Record<string, unknown> = {}) => {
    const generation = ++epoch.current;
    setLoading(true); setError("");
    try {
      const result = await read<unknown>(operation === "adaptation.train.list" ? "project.catalogue" : operation,
        operation === "adaptation.train.list" ? { catalogue: "trainingJobs", limit: 25 } : args);
      if (generation === epoch.current) {
        if (operation === "adaptation.train.list") setHistoryJobs({ revision: snapshot.project.revision, entries: (result as CataloguePage<TrainingJob>).entries });
        else setProbe(result);
      }
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  const choose = async (title: string, apply: (value: string) => void) => {
    const generation = ++epoch.current;
    setLoading(true); setError("");
    try {
      await chooseFile(title, file => { if (generation === epoch.current) apply(file); });
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };

  return <div className="workbench-automation"><details onToggle={(event) => setExpanded(event.currentTarget.open)}>
    <summary>Registered models</summary>
    {error ? <p role="alert" className="workbench-error">{error}</p> : null}
    {pinError ? <p role="alert" className="workbench-error">{pinError}</p> : null}
    <WorkbenchCatalogueBrowser catalogues={["models", "adaptationDatasets", "trainingJobs"]} title="Browse all registered models and training records" disabled={busy || loading} />
    {catalogueError ? <p role="alert" className="workbench-error">{catalogueError}{" "}
      <button type="button" className="cc-btn" disabled={busy || loading} onClick={retryCatalogue}>Retry model catalogue</button></p> : null}
    <p>Register a local Python environment and checkpoint for the selected backend. Models run on the selected channel and projection.
      Supported training adapters use frozen, specimen-separated reference datasets created below.</p>
    <div className="workbench-editor-grid">
      <fieldset disabled={busy || loading}>
        <h3>Register a checkpoint</h3>
        <label>Model backend<select value={registrationBackend?.id ?? ""} disabled={!catalogue} onChange={(event) => setBackend(event.target.value as ModelBackend)}>
          {!catalogue ? <option value="">Loading model backends…</option> : null}
          {catalogue?.backends.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
        </select></label>
        <label>Model name<input value={name} maxLength={200} onChange={(event) => setName(event.target.value)} /></label>
        <label>Local Python executable<input value={pythonPath} onChange={(event) => setPythonPath(event.target.value)} /></label>
        <button className="cc-btn" onClick={() => void choose(`Choose ${registrationBackend?.name ?? "model"} Python executable`, setPythonPath)}>Choose Python</button>
        <label>Local checkpoint file<input value={checkpointPath} onChange={(event) => setCheckpointPath(event.target.value)} /></label>
        <button className="cc-btn" onClick={() => void choose(`Choose local ${registrationBackend?.name ?? "model"} checkpoint`, setCheckpointPath)}>Choose checkpoint</button>
        {registrationBackend?.fileInputs?.map(file => <div key={`${registrationId}-${file.key}`}>
          <label>{file.name}{file.required ? " (required)" : " (optional)"}<input value={registrationFiles[file.key] ?? ""}
            onChange={event => setRegistrationFile(file.key, event.target.value)} /></label>
          <button className="cc-btn" onClick={() => void choose(`Choose ${file.name}`, value => setRegistrationFile(file.key, value))}>Choose {file.name}</button>
        </div>)}
        {registrationBackend?.registrationSchema ? <PluginParameters schema={registrationBackend.registrationSchema}
          values={registrationValues} onChange={setRegistrationValues} /> : null}
        {registrationIssues.map(issue => <p key={issue} role="status">{issue}</p>)}
        {registrationBackend?.notes.length ? <p>{registrationBackend.notes.join(" ")}</p> : null}
        <button className="cc-btn" disabled={environmentWriteBlocked || !registrationBackend || !name.trim() || !pythonPath.trim() || !checkpointPath.trim() || missingFile || registrationIssues.length > 0}
          onClick={() => void act("model.register", { name: name.trim(), backend: registrationBackend?.id, pythonPath: pythonPath.trim(), checkpointPath: checkpointPath.trim(),
            ...(registrationBackend?.registrationSchema ? { registrationConfig: registrationValues } : {}),
            ...Object.fromEntries((registrationBackend?.fileInputs ?? []).flatMap(file => registrationFiles[file.key]?.trim() ? [[file.key, registrationFiles[file.key]!.trim()]] : [])),
          })}>Register trusted model</button>
      </fieldset>
      <fieldset disabled={busy || loading}>
        <h3>Run a registered model</h3>
        <label>Model<select value={modelId} onChange={(event) => {
          epoch.current++; setModelId(event.target.value); setLoading(false); setProbe(undefined); setError("");
        }}>
          {!models.length ? <option value="">Register a model first</option> : null}
          {models.map((item) => <option key={item.id} value={item.id}>
            {item.name} · {catalogue?.backends.find((definition) => definition.id === item.backend)?.name ?? item.backend}{item.enabled ? "" : " · disabled"}
          </option>)}
        </select></label>
        {model ? <>
          <p>{selectedBackend?.name ?? model.backend}</p>
          <small className="workbench-project-path">Checkpoint SHA-256: {model.checkpointHash}</small>
          {model.registrationConfig || model.artifactSetHash ? <details><summary>Retained architecture and configuration</summary>
            <ScientificOutput output={{ backend: model.backend, registrationConfig: model.registrationConfig,
              registrationConfigHash: model.registrationConfigHash, artifactSetHash: model.artifactSetHash }} /></details> : null}
          <label>Local Python binding<input value={binding} onChange={(event) => setBinding(event.target.value)} /></label>
          <div className="workbench-actions">
            <button className="cc-btn" disabled={!binding || binding === model.pythonPath}
              onClick={() => void act("model.configure", { modelId, pythonPath: binding })}>Save Python binding</button>
            <button className="cc-btn" onClick={() => void act("model.configure", { modelId, enabled: !model.enabled })}>
              {model.enabled ? "Disable model" : "Enable trusted model"}</button>
            <button className="cc-btn" disabled={!model.enabled || binding !== model.pythonPath} onClick={() => void inspect("model.probe", { modelId })}>Probe compatibility</button>
          </div>
          <WorkbenchModelEnvironment model={model} revision={snapshot.project.revision} active={expanded} busy={busy || loading}
            writeBlocked={environmentWriteBlocked || jobs.some((job) => activeStatuses.includes(job.status))}
            bindingDirty={binding !== model.pythonPath} read={read} capture={captureEnvironment} />
        </> : null}
        {inferenceSchema ? <PluginParameters schema={inferenceSchema} values={inference} onChange={setInference} /> : null}
        {inferenceIssues.map((issue) => <p key={issue} role="alert" className="workbench-error">{issue}</p>)}
        {inferenceNotes.length ? <p>{inferenceNotes.join(" ")}</p> : null}
        <button className="cc-btn" disabled={!model?.enabled || !inferenceSchema || inferenceIssues.length > 0 || !imageId || volumeMode}
          onClick={() => void act("model.run", { modelId, imageId, parameters: inference, sourceParameters: parameters })}>Segment and save masks</button>
        {volumeMode ? <p>This model adapter currently accepts 2D projections. Use a 3D plugin for volume segmentation.</p> : null}
        {probe ? <ScientificOutput output={probe} /> : null}
      </fieldset>
      <fieldset disabled={busy || loading || !supportsTraining}>
        <h3>Adapt the selected model</h3>
        {model && !supportsTraining ? <p role="status">Training is unavailable for {selectedBackend?.name ?? model.backend} in this adapter.
          Select a registered backend that supports training to use these controls.</p> : null}
        <label>Frozen reference dataset<select value={datasetId} onChange={(event) => setDatasetId(event.target.value)}>
          {!datasets.length ? <option value="">Create a reference dataset first</option> : null}
          {datasets.map((item) => <option key={item.id} value={item.id}>{item.name} · {item.counts.train} train / {item.counts.validation} validation / {item.counts.test} test</option>)}
        </select></label>
        <label>Adapted model name<input value={trainingName} maxLength={200} onChange={(event) => setTrainingName(event.target.value)} /></label>
        <PluginParameters schema={trainingSchema} values={training} onChange={setTraining} />
        <button className="cc-btn" disabled={!supportsTraining || !model?.enabled || !datasetId || !trainingName.trim() || jobs.some((job) => activeStatuses.includes(job.status))}
          onClick={() => void act("adaptation.train.start", { modelId, datasetId, name: trainingName.trim(),
            epochs: 100, learningRate: .01, batchSize: 8, ...training })}>Start training</button>
        {supportsTraining ? <p>Training continues in a local worker. Validation chooses the checkpoint; held-out specimens measure its performance.</p> : null}
      </fieldset>
    </div>
    <button className="cc-btn" disabled={busy || loading} onClick={() => void inspect("adaptation.train.list")}>Refresh training progress</button>
    <ul className="workbench-jobs">{[...new Map([...(historyJobs?.revision === snapshot.project.revision ? historyJobs.entries : []), ...jobs].map(job => [job.id, job])).values()].map((job) => <li key={job.id}>
      <strong>{job.name}</strong><span>{job.status}{job.phase ? ` · ${job.phase}` : ""}</span>
      {job.progress ? <ScientificOutput output={job.progress} /> : null}
      {job.error ? <p className="workbench-error">{job.error.message}</p> : null}
      {job.metrics ? <ScientificOutput output={job.metrics} /> : null}
      <div className="workbench-actions">
        {activeStatuses.includes(job.status) ? <button className="cc-btn" disabled={busy || job.status === "cancelling"}
          onClick={() => void act("adaptation.train.cancel", { jobId: job.id })}>Cancel training</button> : null}
        {job.status === "completed" && !job.resultModelId ? <button className="cc-btn" disabled={busy}
          onClick={() => void act("adaptation.train.collect", { jobId: job.id })}>Retain checkpoint and report</button> : null}
        {job.resultModelId ? <span>Checkpoint retained in registered models.</span> : null}
      </div>
    </li>)}</ul>
  </details></div>;
}
