import { useEffect, useRef, useState } from "react";
import type { ProjectSnapshot, WorkbenchWorkflow } from "../../../../shared/workbench/protocol";
import type { SweepAxis, SweepExportArguments, SweepExportFormat, SweepParameters, SweepPreview, SweepSummary, WorkbenchSweep } from "../../../../shared/workbench/sweepProtocol";
import { sweepAddressLabel } from "../../../../shared/workbench/sweepProtocol";
import { activeJobWorker, workerTargetId, workerTargetKind } from "../../../../shared/workbench/workerProtocol";
import SweepAxisEditor, { parseSweepAxis, sweepParameterKey, type SweepDraftAxis } from "./SweepAxisEditor";
import WorkbenchSweepResults from "./WorkbenchSweepResults";
import { isGraphWorkflow } from "../../../../shared/workbench/graphProtocol";
import type { CataloguePage } from "../../../../shared/workbench/catalogueProtocol";

type Props = {
  snapshot: ProjectSnapshot; workflow?: WorkbenchWorkflow; imageIds: string[]; timeIndices?: number[]; scopeValid: boolean; busy: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void>;
  chooseDirectory: (selected: (path: string) => void) => Promise<void>;
  runSweep: (sweepId: string) => Promise<void>; stopSweep: () => void; runningSweepId: string;
  exportResults: (format: SweepExportFormat, args: SweepExportArguments, name: string) => Promise<void>;
};

function SweepCombinations({ sweepId, revision, busy, read }: {
  sweepId: string; revision: number; busy: boolean; read: Props["read"];
}) {
  const [open, setOpen] = useState(false);
  const [result, setResult] = useState<WorkbenchSweep>();
  const [error, setError] = useState("");
  const latest = useRef(read); latest.current = read;
  useEffect(() => {
    if (!open || busy) return;
    let active = true; setError("");
    void latest.current<{ sweep: WorkbenchSweep }>("sweep.get", { sweepId }).then((value) => {
      if (active) setResult(value.sweep);
    }).catch((cause) => { if (active) setError(String(cause)); });
    return () => { active = false; };
  }, [open, sweepId, revision, busy]);
  return <details onToggle={(event) => setOpen(event.currentTarget.open)}>
    <summary>Combination jobs and image variants</summary>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {open && result ? <ul>{result.combinations.map((combination) => {
      const job = result.jobs?.find((item) => item.id === combination.jobId);
      return <li key={combination.index}>
        <strong>Combination {combination.index + 1}</strong> · {job?.status ?? "saved job"}
        <p>{combination.values.map((value) => `${sweepAddressLabel({ ...value, nodeName: value.nodeId
          ? result.baseWorkflow.graph?.nodes.find((node) => node.id === value.nodeId)?.name : undefined })} ${value.path}: ${value.value === null ? "omitted" : JSON.stringify(value.value)}`).join(" · ")}</p>
        <small>{combination.variants.length} independent image variants · job {combination.jobId}</small>
      </li>;
    })}</ul> : null}
  </details>;
}

export default function WorkbenchSweeps({ snapshot, workflow, imageIds, timeIndices, scopeValid, busy, read, act, chooseDirectory, runSweep, stopSweep, runningSweepId, exportResults }: Props) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("Parameter sweep");
  const [axes, setAxes] = useState<SweepDraftAxis[]>([]);
  const [parameters, setParameters] = useState<SweepParameters>();
  const [parameterAttempt, setParameterAttempt] = useState(0);
  const [parameterError, setParameterError] = useState("");
  const [directory, setDirectory] = useState("");
  const [preview, setPreview] = useState<{ identity: string; result: SweepPreview }>();
  const [readSweeps, setReadSweeps] = useState<{ revision: number; values: SweepSummary[] }>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const epoch = useRef(0);
  const latest = useRef(read); latest.current = read;
  const revision = snapshot.project.revision;
  const branching = isGraphWorkflow(workflow);
  const sweeps = [...new Map([...(readSweeps?.revision === revision ? readSweeps.values : []), ...(snapshot.sweeps ?? [])].map(item => [item.id, item])).values()];
  const parameterMatch = parameters?.workflow.id === workflow?.id && parameters?.workflow.version === workflow?.version;
  const candidates = parameterMatch ? parameters?.candidatePaths ?? [] : [];
  const maxAxes = parameters?.limits.axes ?? 6;
  const maxValues = parameters?.limits.valuesPerAxis ?? 16;
  const maxCombinations = parameters?.limits.combinations ?? 64;
  const parsed = axes.map((axis) => parseSweepAxis(axis, candidates.find((item) => sweepParameterKey(item) === sweepParameterKey(axis)), maxValues));
  const validAxes = axes.length > 0 && axes.length <= maxAxes && parsed.every((item) => item.axis);
  const values = parsed.flatMap((item) => item.axis ? [item.axis] : []) as SweepAxis[];
  const estimatedCount = values.reduce((count, axis) => count * axis.values.length, 1);
  const requiresDirectory = workflow?.steps.some((step) => step.type === "export") ?? false;
  const args = { workflowId: workflow?.id, workflowVersion: workflow?.version, imageIds,
    ...(timeIndices ? { timeIndices } : {}), axes: values, ...(requiresDirectory && directory ? { exportDirectory: directory } : {}) };
  const identity = JSON.stringify({ revision, args });
  const currentPreview = preview?.identity === identity ? preview.result : undefined;
  const matchingAxisKind = values.every((axis) => branching ? axis.nodeId !== undefined : axis.stepIndex !== undefined);
  const ready = scopeValid && !!workflow && imageIds.length > 0 && validAxes && matchingAxisKind && estimatedCount <= maxCombinations;
  const activeWorker = snapshot.jobWorkers?.find(activeJobWorker);
  const locked = busy || loading || !!activeWorker;

  useEffect(() => {
    epoch.current++; setAxes([]); setParameters(undefined); setPreview(undefined); setLoading(false);
    setParameterError(""); setError("");
    return () => { epoch.current++; };
  }, [workflow?.id, workflow?.version]);
  useEffect(() => {
    epoch.current++; setPreview(undefined); setLoading(false); setError("");
    return () => { epoch.current++; };
  }, [revision]);
  useEffect(() => {
    if (!open || !workflow || busy || activeWorker || parameterMatch) return;
    let active = true; setParameterError("");
    void latest.current<SweepParameters>("sweep.parameters", { workflowId: workflow.id, workflowVersion: workflow.version })
      .then((value) => { if (active) setParameters(value); })
      .catch((cause) => { if (active) setParameterError(String(cause)); });
    return () => { active = false; };
  }, [open, workflow?.id, workflow?.version, busy, !!activeWorker, parameterAttempt, parameterMatch]);
  const refreshList = async () => {
    const generation = ++epoch.current; setLoading(true); setError("");
    try {
      const value = await read<CataloguePage<SweepSummary>>("project.catalogue", { catalogue: "sweeps", limit: 25 });
      if (epoch.current === generation) setReadSweeps({ revision, values: value.entries });
    } catch (cause) { if (epoch.current === generation) setError(String(cause)); }
    finally { if (epoch.current === generation) setLoading(false); }
  };
  const inspect = async () => {
    if (!ready) return;
    const generation = ++epoch.current; setLoading(true); setError(""); setPreview(undefined);
    try {
      const result = await read<SweepPreview>("sweep.preview", args);
      if (epoch.current === generation) setPreview({ identity, result });
    } catch (cause) { if (epoch.current === generation) setError(String(cause)); }
    finally { if (epoch.current === generation) setLoading(false); }
  };
  const choose = () => {
    const generation = epoch.current;
    return chooseDirectory((path) => {
      if (generation === epoch.current) { setDirectory(path); setPreview(undefined); }
    });
  };
  return <details onToggle={(event) => setOpen(event.currentTarget.open)}>
    <summary>Parameter sweeps</summary>
    <p>Compare explicit parameter combinations using independent image variants. Each combination has its own saved workflow and resumable batch.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {!scopeValid ? <p>Select an available current time point above, or choose all time points.</p> : null}
    {branching ? <p>Each combination keeps the complete branching workflow. Parameters identify a named node; source selectors remain inherited from the graph. Branch object counts stay separate.</p> : null}
    <fieldset disabled={locked || !workflow || !scopeValid}>
      <legend>Configure a sweep</legend>
      <p>{workflow ? `${workflow.name} · version ${workflow.version} · ${imageIds.length} source images` : "Select a saved workflow above."}
        {timeIndices ? ` · time points ${timeIndices.map((index) => index + 1).join(", ")}` : ""}</p>
      <label>Sweep name<input maxLength={200} value={name} onChange={(event) => setName(event.target.value)} /></label>
      {parameterError ? <p className="workbench-error" role="alert">{parameterError}{" "}
        <button type="button" className="cc-btn" onClick={() => setParameterAttempt((value) => value + 1)}>Retry parameters</button></p> : null}
      {!parameterMatch && !parameterError ? <p role="status">Loading the saved workflow’s parameter definitions…</p> : null}
      <SweepAxisEditor parameters={candidates} axes={axes} disabled={locked || !parameterMatch}
        maxAxes={maxAxes} maxValues={maxValues} onChange={(next) => {
          epoch.current++; setAxes(next); setPreview(undefined); setLoading(false); setError("");
        }} />
      {validAxes ? <p>{estimatedCount.toLocaleString()} combinations · limit {maxCombinations}</p> : null}
      {validAxes && estimatedCount > maxCombinations ? <p className="workbench-error" role="alert">Reduce the value lists to stay within the combination limit.</p> : null}
      {requiresDirectory ? <>
        <button type="button" className="cc-btn" onClick={() => void choose()}>Choose export folder…</button>
        {directory ? <p className="workbench-project-path">{directory}</p> : <p>Choose an existing folder before creating this sweep. Each combination exports to a new ZIP.</p>}
      </> : null}
      <div className="workbench-actions">
        <button type="button" className="cc-btn" disabled={!ready} onClick={() => void inspect()}>Preview combinations</button>
        <button type="button" className="cc-btn" disabled={!currentPreview || !name.trim() || (requiresDirectory && !directory)}
          onClick={() => {
            if (currentPreview && ready) void act("sweep.create", { ...args, name: name.trim() });
          }}>Create sweep and image variants</button>
      </div>
    </fieldset>
    {currentPreview ? <section aria-label="Parameter sweep preview">
      <p>{currentPreview.combinationCount} combinations create {currentPreview.requiredVariantCount} isolated source variants
        {currentPreview.requiredProcessedCount ? ` and ${currentPreview.requiredProcessedCount} processed images` : ""} ·{" "}
        {currentPreview.requiredBranchImageCount ? `${currentPreview.requiredBranchImageCount} independent branch images · ` : ""}
        {currentPreview.requiredImageCount} additional image identities in total.
        {currentPreview.checkpointCount !== undefined ? ` ${currentPreview.checkpointCount.toLocaleString()} saved checkpoints across the group.` : ""}</p>
      {currentPreview.nodeCheckpointCount !== undefined ? <p>{currentPreview.nodeCheckpointCount.toLocaleString()} scientific node checkpoints across all combinations and source/time inputs.</p> : null}
      <p>Variants receive no biological specimen or review assignments. Compare parameter settings before assigning final analysis images to experiments.</p>
      <div className="workbench-table"><table>
        <caption>Exact parameter combinations</caption>
        <thead><tr><th>Combination</th>{axes.map((axis) => <th key={axis.key}>{sweepAddressLabel(axis)} ·{" "}
          {candidates.find((item) => sweepParameterKey(item) === sweepParameterKey(axis))?.label ?? axis.path}</th>)}</tr></thead>
        <tbody>{currentPreview.combinations.map((combination) => <tr key={combination.index}>
          <td>{combination.index + 1}</td>{axes.map((axis) => {
            const value = combination.values.find((item) => sweepParameterKey(item) === sweepParameterKey(axis))?.value;
            return <td key={axis.key}>{value === null ? "Omitted (backend default)" : JSON.stringify(value)}</td>;
          })}
        </tr>)}</tbody>
      </table></div>
      {currentPreview.notes.length ? <p>{currentPreview.notes.join(" ")}</p> : null}
    </section> : null}
    <div className="workbench-actions">
      <button type="button" className="cc-btn" disabled={locked} onClick={() => void refreshList()}>Refresh sweeps</button>
      {runningSweepId ? <button type="button" className="cc-btn" onClick={stopSweep}>Stop sweep after current checkpoint</button> : null}
    </div>
    {activeWorker ? <p role="status">A background worker owns this project. Use Background execution below to stop after its current checkpoint.</p> : null}
    <ul className="workbench-jobs">{sweeps.map((sweep) => <li key={sweep.id}>
      <div><strong>{sweep.name}</strong><span>{sweep.status} · {sweep.progress.completed} / {sweep.progress.total} checkpoints</span></div>
      {sweep.status === "awaiting-review" ? <p>A child graph is awaiting an explicit review decision. Open its batch in Saved workflows below; the sweep and its worker will not pass the gate automatically.</p> : null}
      {sweep.completedCombinations !== undefined ? <p>{sweep.completedCombinations} completed combinations
        {sweep.combinationCount !== undefined ? ` of ${sweep.combinationCount}` : ""}.</p> : null}
      <progress aria-label={`${sweep.name} progress`} value={sweep.progress.completed} max={sweep.progress.total || 1} />
      {sweep.sourceInputsCurrent === false ? <p>Source inputs changed after this sweep was created.</p> : null}
      {sweep.outputsCurrent === false ? <p>The group does not yet have current results for every combination.</p> : null}
      <div className="workbench-actions">
        {["pending", "running"].includes(sweep.status) ? <>
          <button type="button" className="cc-btn" disabled={locked} onClick={() => void act("sweep.advance", { sweepId: sweep.id })}>Run next checkpoint</button>
          <button type="button" className="cc-btn" disabled={locked} onClick={() => void runSweep(sweep.id)}>Run remaining in this window</button>
          <button type="button" className="cc-btn" disabled={locked || !sweep.sourceInputsCurrent}
            onClick={() => void act("sweep.worker.start", { sweepId: sweep.id })}>Run whole sweep in background</button>
          <button type="button" className="cc-btn" disabled={locked} onClick={() => void act("sweep.pause", { sweepId: sweep.id })}>Pause sweep</button>
        </> : null}
        {sweep.status === "paused" ? <button type="button" className="cc-btn" disabled={locked}
          onClick={() => void act("sweep.resume", { sweepId: sweep.id })}>Resume sweep</button> : null}
        {sweep.status === "failed" ? <button type="button" className="cc-btn" disabled={locked}
          onClick={() => void act("sweep.retry", { sweepId: sweep.id })}>Retry failed checkpoint</button> : null}
        {!["completed", "cancelled"].includes(sweep.status) ? <button type="button" className="cc-btn" disabled={locked}
          onClick={() => void act("sweep.cancel", { sweepId: sweep.id })}>Cancel sweep</button> : null}
      </div>
      {activeWorker && workerTargetKind(activeWorker) === "sweep" && workerTargetId(activeWorker) === sweep.id
        ? <p>This whole sweep is running independently of the app. Check progress and stop requests in Background execution below.</p> : null}
      <SweepCombinations sweepId={sweep.id} revision={revision} busy={busy || !!activeWorker} read={read} />
      <WorkbenchSweepResults sweepId={sweep.id} revision={revision} busy={busy} workerActive={!!activeWorker} read={read}
        exportResults={exportResults} />
    </li>)}</ul>
    <p>Run remaining in this window keeps advancing while this workbench stays open. Run whole sweep in background continues after the app closes.
      Both save the same checkpoints and can pause after the current unit. Individual combination jobs remain available in the batch controls.</p>
  </details>;
}
