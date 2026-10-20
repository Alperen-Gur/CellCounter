import { useCataloguePins } from "./WorkbenchCatalogueBrowser";
import { useEffect, useMemo, useRef, useState } from "react";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import type { RefreshActions, RefreshExportFormat, RefreshInspection, RefreshJob, RefreshJobSummary, RefreshOutput,
  RefreshDependencyMode, RefreshKind, RefreshPreview, RefreshReason, RefreshReport, RefreshRunRef } from "../../../../shared/workbench/refreshProtocol";
import { activeJobWorker, workerTargetId, workerTargetKind } from "../../../../shared/workbench/workerProtocol";
import ScientificOutput from "./ScientificOutput";

type Props = {
  snapshot: ProjectSnapshot; imageId: string; busy: boolean; writeBlocked: boolean; runningRefreshId: string;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>; actions: RefreshActions;
};
const keyFor = (item: RefreshRunRef) => `${item.kind}:${item.runId}`;
const kindLabel: Record<RefreshKind, string> = { "derived-image": "Derived acquisition", tracks: "Object tracks", lineage: "Lineage graph", assay: "Assay", "assay-series": "Assay time series", "plugin-measurement": "Measurement plugin", statistics: "Statistical result" };
const targetLabel = (item: { target: string; timeIndex?: number; channel?: number }) => [
  item.target === "volume" ? "Volume" : "Plane", item.channel === undefined ? undefined : `channel ${item.channel + 1}`,
  item.timeIndex === undefined ? undefined : `time point ${item.timeIndex + 1}`,
].filter(Boolean).join(" · ");
const PAGE_SIZE = 50;
function Reasons({ reasons }: { reasons: RefreshReason[] }) {
  return reasons.length ? <ul>{reasons.map((item, index) => <li key={`${item.code}-${index}`}>{item.message}</li>)}</ul> : null;
}

function RefreshJobDetails({ job, revision, busy, workerActive, writeBlocked, read, actions, formats }: {
  job: RefreshJobSummary; revision: number; busy: boolean; workerActive: boolean; writeBlocked: boolean;
  read: Props["read"]; actions: RefreshActions; formats: RefreshExportFormat[];
}) {
  const [open, setOpen] = useState(false);
  const [loaded, setLoaded] = useState<{ revision: number; result: RefreshReport }>();
  const [unitId, setUnitId] = useState("");
  const [formatId, setFormatId] = useState("results-json");
  const [error, setError] = useState("");
  const [attempt, setAttempt] = useState(0);
  const latest = useRef(read); latest.current = read;
  const result = loaded?.revision === revision && loaded.result.refresh.id === job.id && !workerActive ? loaded.result : undefined;
  const unit = result?.refresh.units.find((item) => item.id === unitId) ?? result?.refresh.units[0];
  const format = formats.find((item) => item.id === formatId) ?? formats[0];
  useEffect(() => {
    if (!open || busy || workerActive) return;
    let current = true; setError("");
    void latest.current<RefreshReport>("refresh.results", { refreshId: job.id }).then((value) => {
      if (current) setLoaded({ revision, result: value });
    }).catch((cause) => { if (current) setError(String(cause)); });
    return () => { current = false; };
  }, [open, busy, workerActive, revision, job.id, attempt]);
  return <details onToggle={(event) => setOpen(event.currentTarget.open)}>
    <summary>Refresh report and execution details</summary>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <button type="button" className="cc-btn" disabled={busy || workerActive} onClick={() => setAttempt((value) => value + 1)}>Reload report</button>
    {workerActive ? <p>Pause background work to load a report at the project’s current revision.</p> : !result && !error ? <p role="status">Loading saved refresh report…</p> : null}
    {result ? <>
      <p><strong>{result.executionComplete ? "Execution complete" : "Execution incomplete"}</strong>{" · "}
        <strong>{result.coverageComplete ? "Coverage complete" : "Coverage incomplete"}</strong>.</p>
      <p>{result.refresh.progress.completed}/{result.refresh.progress.total} checkpoints saved · {result.refresh.skipped.length} blocked results skipped.
        {!result.outputsCurrent ? " Some replacement results are no longer current." : ""}</p>
      {result.notes.length ? <p>{result.notes.join(" ")}</p> : null}
      {result.refresh.imageReplacements?.length ? <details><summary>Replacement acquisitions ({result.refresh.imageReplacements.length})</summary><ul>{result.refresh.imageReplacements.map(item => <li key={item.unitId} className="workbench-project-path">{item.previousImageId} → {item.imageId}</li>)}</ul><p>Original acquisitions remain retained. Replacements are distinct representations, not additional biological replicates.</p></details> : null}
      {result.refresh.assignmentTransfers?.length ? <details><summary>Recorded specimen-assignment transfers</summary><ul>{result.refresh.assignmentTransfers.map(item => <li key={`${item.unitId}:${item.previous.specimenId}`}>Specimen {item.previous.specimenId}: {item.previous.imageId} → {item.imageId} · revision {item.revision}</li>)}</ul></details> : null}
      {result.refresh.skipped.length ? <details><summary>Skipped results and blockers</summary><ul>{result.refresh.skipped.map((item) => <li key={keyFor(item)}>
        {item.imageName} · {item.label} · {targetLabel(item)}<Reasons reasons={item.blockers} /></li>)}</ul></details> : null}
      {result.refresh.units.length ? <>
        <label>Checkpoint details<select value={unit?.id ?? ""} onChange={(event) => setUnitId(event.target.value)}>
          {result.refresh.units.map((item, index) => <option key={item.id} value={item.id}>{index + 1} · {item.imageName} · {item.label} · {item.status}</option>)}
        </select></label>
        {unit ? <>
          <p>{kindLabel[unit.kind]} · {targetLabel(unit)} · {unit.status}{result.refresh.staleUnitIds.includes(unit.id) ? " · replacement is stale" : ""}.</p>
          <p className="workbench-project-path">Previous result: {unit.runId}{unit.resultRunId ? ` → replacement: ${unit.resultRunId}` : " · no saved replacement yet"}</p>
          {unit.resultImageId ? <p className="workbench-project-path">Replacement image: {unit.resultImageId}</p> : null}
          {unit.dependsOn?.length ? <p>Requires: {unit.dependsOn.map(id => result.refresh.units.find(item => item.id === id)?.label ?? id).join("; ")}.</p> : null}
          <details><summary>Inputs, method and runtime binding</summary><ScientificOutput output={{
            definitionHash: job.definitionHash, inputFingerprint: unit.inputFingerprint,
            arguments: unit.arguments, dependencies: unit.dependencies, dependsOn: unit.dependsOn, binding: unit.binding,
            resultOutputHash: unit.resultOutputHash,
          }} /></details>
        </> : null}
      </> : null}
    </> : null}
    <label>Report format<select disabled={busy || workerActive || !formats.length} value={format?.id ?? ""} onChange={(event) => setFormatId(event.target.value)}>
      {!formats.length ? <option value="">Loading export formats…</option> : null}
      {formats.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
    </select></label>
    <button type="button" className="cc-btn" disabled={busy || workerActive || writeBlocked || !format}
      onClick={() => { if (format) void actions.exportReport(format, job.id, job.name); }}>Export refresh report…</button>
    <p>The exported report includes all checkpoints, skipped blockers and predecessor/replacement links. Existing exported files are never updated automatically.</p>
  </details>;
}

export default function WorkbenchFreshness({ snapshot, imageId, busy, writeBlocked, runningRefreshId, read, actions }: Props) {
  const [open, setOpen] = useState(false);
  const [scope, setScope] = useState<"image" | "project">("image");
  const [dependencyMode, setDependencyMode] = useState<RefreshDependencyMode>("transitive");
  const [includeHistory, setIncludeHistory] = useState(false);
  const [filter, setFilter] = useState<"affected" | "current" | "all">("affected");
  const [chosen, setChosen] = useState<string[]>([]);
  const [scan, setScan] = useState<{ identity: string; result: RefreshInspection }>();
  const [preview, setPreview] = useState<{ identity: string; result: RefreshPreview }>();
  const [scanLoading, setScanLoading] = useState(false);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const [name, setName] = useState("Refresh saved results");
  const [skipBlocked, setSkipBlocked] = useState(false);
  const [page, setPage] = useState(0);
  const [jobId, setJobId] = useState("");
  const [formats, setFormats] = useState<RefreshExportFormat[]>([]);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const [stoppingWorker, setStoppingWorker] = useState("");
  const epoch = useRef(0);
  const latest = useRef(read); latest.current = read;
  const revision = snapshot.project.revision;
  const pinError = useCataloguePins([{ catalogue: "refreshJobs", entryId: jobId }]);
  const jobs = snapshot.refreshJobs ?? [];
  const job = jobId ? jobs.find((item) => item.id === jobId) : jobs[0];
  const worker = snapshot.jobWorkers?.find(activeJobWorker);
  const refreshWorker = worker && workerTargetKind(worker) === "refresh" ? worker : undefined;
  const scopeValid = scope === "project" || !!imageId;
  const scopeArgs = scope === "image" ? { imageIds: [imageId] } : {};
  const scanIdentity = JSON.stringify({ revision, scope, imageId: scope === "image" ? imageId : null, includeHistory, dependencyMode });
  const inspected = scan?.identity === scanIdentity ? scan.result : undefined;
  const selected = (inspected?.outputs ?? []).filter((item) => item.latest && item.freshness === "stale" && chosen.includes(keyFor(item)));
  const refs = selected.map(({ kind, runId }) => ({ kind, runId }));
  const args = { ...scopeArgs, dependencyMode, runRefs: refs, includeCurrent: false };
  const planIdentity = JSON.stringify({ revision, args });
  const latestPlanIdentity = useRef(planIdentity); latestPlanIdentity.current = planIdentity;
  const plan = preview?.identity === planIdentity ? preview.result : undefined;
  const locked = busy || !!worker;
  const scanBusy = locked || scanLoading || previewLoading;
  const limit = inspected?.limits.unitsPerJob ?? 256;
  const filtered = useMemo(() => (inspected?.outputs ?? []).filter((item) => filter === "all" ||
    (filter === "current" ? item.status === "current" : item.status !== "current")), [inspected?.outputs, filter]);
  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount - 1);
  const visible = filtered.slice(currentPage * PAGE_SIZE, (currentPage + 1) * PAGE_SIZE);
  const canPreview = selected.length > 0 && selected.length <= limit;

  useEffect(() => {
    epoch.current++; setPreviewLoading(false); setError("");
    return () => { epoch.current++; };
  }, [scanIdentity]);
  useEffect(() => { setChosen([]); setPreview(undefined); setPage(0); setMessage(""); }, [scope, scope === "image" ? imageId : undefined, dependencyMode]);
  useEffect(() => { if (!refreshWorker || refreshWorker.workerId !== stoppingWorker) setStoppingWorker(""); }, [refreshWorker?.workerId, refreshWorker?.status, stoppingWorker]);
  useEffect(() => {
    if (!open || locked || !scopeValid) return;
    let current = true; setScanLoading(true); setError("");
    void latest.current<RefreshInspection>("refresh.inspect", { ...scopeArgs, includeHistory, dependencyMode }).then((result) => {
      if (current) {
        setScan({ identity: scanIdentity, result });
        const available = new Set(result.outputs.filter((item) => item.latest && item.freshness === "stale").map(keyFor));
        setChosen((old) => old.filter((id) => available.has(id)));
      }
    }).catch((cause) => { if (current) setError(String(cause)); }).finally(() => { if (current) setScanLoading(false); });
    return () => { current = false; };
  }, [open, locked, scopeValid, scanIdentity, attempt]);
  useEffect(() => {
    if (!open || busy || formats.length) return;
    let current = true;
    void latest.current<{ formats: RefreshExportFormat[] }>("refresh.export.catalogue").then((result) => { if (current) setFormats(result.formats); })
      .catch((cause) => { if (current) setError(String(cause)); });
    return () => { current = false; };
  }, [open, busy, formats.length, attempt]);

  const previewPlan = async () => {
    if (scanBusy || !canPreview) return;
    const generation = ++epoch.current; setPreviewLoading(true); setPreview(undefined); setSkipBlocked(false); setError("");
    try {
      const result = await read<RefreshPreview>("refresh.preview", args);
      if (generation === epoch.current && latestPlanIdentity.current === planIdentity) setPreview({ identity: planIdentity, result });
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setPreviewLoading(false); }
  };
  const stopBackground = async () => {
    if (!refreshWorker) return;
    setStoppingWorker(refreshWorker.workerId); setError("");
    try { await actions.stopWorker(refreshWorker.workerId); }
    catch (cause) { setStoppingWorker(""); setError(String(cause)); }
  };
  return <div className="workbench-automation"><details onToggle={(event) => setOpen(event.currentTarget.open)}>
    <summary>Result freshness</summary>
    {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    <p>Refresh saved processing, tracking, lineage, measurement and statistical results in dependency order. Each checkpoint retains its predecessor and appends an explicit replacement; historical exported files remain unchanged.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {message ? <p role="status">{message}</p> : null}
    <fieldset disabled={scanBusy}>
      <label>Results to inspect<select value={scope} onChange={(event) => setScope(event.target.value as "image" | "project")}>
        <option value="image" disabled={!imageId}>Selected image</option><option value="project">Whole project</option>
      </select></label>
      <label>Dependency scope<select value={dependencyMode} onChange={event => setDependencyMode(event.target.value as RefreshDependencyMode)}>
        <option value="transitive">Affected results and required upstream dependencies</option><option value="measurements">Assays and measurement plugins only</option>
      </select></label>
      <div className="workbench-actions"><button type="button" className="cc-btn" disabled={!scopeValid} onClick={() => setAttempt((value) => value + 1)}>Check result freshness</button></div>
    </fieldset>
    {scanLoading ? <p role="status">Reading saved result dependencies…</p> : null}
    {writeBlocked ? <p>Inspection is read-only. Save or discard pending scientific edits before creating or running a refresh.</p> : null}
    {worker ? <p role="status">Background work owns the project. Freshness will be checked again when it pauses or finishes.</p> : null}
    {inspected ? <>
      <p>{inspected.counts.current} current · {inspected.counts.stale} stale · {inspected.counts.blocked} blocked · {inspected.counts.total} inspected.</p>
      <div className="workbench-actions">
        <button type="button" className="cc-btn" disabled={scanBusy} onClick={() => setChosen(inspected.outputs
          .filter((item) => item.latest && item.freshness === "stale" && item.recomputable).map(keyFor))}>Select refreshable latest results</button>
        <button type="button" className="cc-btn" disabled={scanBusy || !chosen.length} onClick={() => setChosen([])}>Clear selection</button>
        <label>Show<select value={filter} disabled={scanBusy} onChange={(event) => { setFilter(event.target.value as typeof filter); setPage(0); }}>
          <option value="affected">Stale and blocked</option><option value="current">Current</option><option value="all">All results</option>
        </select></label>
      </div>
      <div className="workbench-table"><table>
        <caption>Saved result freshness · {filtered.length} matching results</caption>
        <thead><tr><th scope="col">Refresh</th><th scope="col">Result</th><th scope="col">Image and selection</th><th scope="col">Status and reason</th></tr></thead>
        <tbody>{visible.map((item: RefreshOutput) => <tr key={keyFor(item)}>
          <td><input type="checkbox" aria-label={`Refresh ${item.label} for ${item.imageName}`} checked={chosen.includes(keyFor(item))}
            disabled={scanBusy || !item.latest || item.freshness !== "stale"} onChange={(event) => setChosen((old) => event.target.checked
              ? [...old.filter((id) => id !== keyFor(item)), keyFor(item)] : old.filter((id) => id !== keyFor(item)))} /></td>
          <td>{item.label}<br /><small>{kindLabel[item.kind]} · {item.latest ? "Latest saved result" : "Historical result"}{item.revision != null ? ` · revision ${item.revision}` : ""}</small></td>
          <td>{item.imageName}<br /><small>{targetLabel(item)}</small></td>
          <td><strong>{item.status}</strong><Reasons reasons={item.blockers.length ? item.blockers : item.reasons} />
            {item.replacementRunId ? <small className="workbench-project-path">Replaced by {item.replacementRunId}</small> : null}</td>
        </tr>)}</tbody>
      </table></div>
      <div className="workbench-actions">
        <button type="button" className="cc-btn" disabled={scanBusy || currentPage === 0} onClick={() => setPage(currentPage - 1)}>Previous results</button>
        <span>Page {currentPage + 1} of {pageCount}</span>
        <button type="button" className="cc-btn" disabled={scanBusy || currentPage + 1 >= pageCount} onClick={() => setPage(currentPage + 1)}>Next results</button>
      </div>
      <details><summary>Inspection scope and history</summary>
        <label className="workbench-inline"><input type="checkbox" checked={includeHistory} disabled={scanBusy}
          onChange={(event) => { setIncludeHistory(event.target.checked); setPage(0); }} />Include historical results for inspection</label>
        <p>Selection refreshes only the latest affected result for each saved method and source selection. Historical results stay read-only here.</p>
        {inspected.notes.length ? <p>{inspected.notes.join(" ")}</p> : null}
      </details>
      {inspected.unhandled.length ? <details><summary>Other results requiring attention ({inspected.unhandled.length})</summary>
        <ul>{inspected.unhandled.map((item, index) => <li key={`${item.kind}-${index}`}><strong>{item.kind} · {item.status}</strong>
          <p>{item.message}</p>{item.action ? <p>{item.action}</p> : null}</li>)}</ul></details> : null}
      <p>{selected.length} latest results selected · up to {limit} checkpoints per refresh.</p>
      {selected.length > limit ? <p className="workbench-error">Select at most {limit} results for this refresh.</p> : null}
      <button type="button" className="cc-btn" disabled={scanBusy || !canPreview} onClick={() => void previewPlan()}>Preview result refresh</button>
    </> : null}
    {plan ? <section aria-label="Result refresh preview">
      <h3>Refresh preview</h3>
      <p>{plan.plan.readyCount} ready · {plan.plan.blockedCount} blocked. Inputs and saved method versions will be frozen in the plan.</p>
      {plan.plan.usesExecutableCode ? <p>This plan executes enabled measurement plugins with their saved parameters and runtime bindings.</p> : null}
      <p>{plan.plan.dependencyMode === "transitive" ? "Required stale predecessors are included automatically. Check the complete ordered plan before saving." : "This plan refreshes saved measurement outputs only."}</p>
      <ol>{plan.plan.units.map((item) => <li key={keyFor(item)}><strong>{kindLabel[item.kind]} · {item.label} · {item.status}</strong>
        <p>{item.imageName} · {targetLabel(item)}</p>
        {item.dependsOn?.length ? <p>After: {item.dependsOn.map(id => plan.plan.units.find(value => value.id === id)?.label ?? id).join("; ")}.</p> : null}
        <Reasons reasons={item.blockers} /></li>)}</ol>
      {plan.plan.assignmentTransfers?.length ? <section aria-label="Planned specimen assignment transfers"><h4>Specimen assignments will move to replacement images</h4>
        <p>The original acquisition stays retained. Its assignment moves to the replacement representation so both alternatives cannot increase biological n.</p>
        <ul>{plan.plan.assignmentTransfers.map(item => <li key={`${item.imageId}:${item.specimenId}`}>
          {snapshot.images.find(image => image.id === item.imageId)?.name ?? item.imageId} · specimen {snapshot.experimentalDesign?.specimens.find(value => value.id === item.specimenId)?.name ?? item.specimenId}
          {` · after ${plan.plan.units.find(value => value.id === item.producerUnitId)?.label ?? item.producerUnitId}`}</li>)}</ul></section> : null}
      {plan.plan.notes.length ? <p>{plan.plan.notes.join(" ")}</p> : null}
      <fieldset disabled={scanBusy || writeBlocked}>
        <label>Refresh name<input maxLength={200} value={name} onChange={(event) => setName(event.target.value)} /></label>
        {plan.plan.blockedCount ? <label className="workbench-inline"><input type="checkbox" checked={skipBlocked}
          onChange={(event) => setSkipBlocked(event.target.checked)} />Skip the {plan.plan.blockedCount} blocked results; keep incomplete coverage explicit</label> : null}
        <button type="button" className="cc-btn" disabled={!name.trim() || !plan.plan.readyCount || (plan.plan.blockedCount > 0 && !skipBlocked)} onClick={() => {
          void actions.mutate<{ refresh: RefreshJob }>("refresh.create", { ...args, name: name.trim(), skipBlocked,
            previewFingerprint: plan.previewFingerprint }, (result) => { setJobId(result.refresh.id); setPreview(undefined);
              setMessage("Refresh plan saved. Run its checkpoints below when ready."); });
        }}>Create refresh plan</button>
      </fieldset>
    </section> : null}
    {refreshWorker ? <section aria-label="Active refresh worker">
      <h3>Background result refresh</h3><p>{refreshWorker.status} · {refreshWorker.progress?.completed ?? 0}/{refreshWorker.progress?.total ?? 0} saved checkpoints</p>
      <button type="button" className="cc-btn" disabled={!!stoppingWorker || refreshWorker.stopRequested}
        onClick={() => void stopBackground()}>{stoppingWorker || refreshWorker.stopRequested ? "Stop requested" : "Stop after current checkpoint"}</button>
      <p>The same worker appears in Workflows → Background execution and continues when this app closes.</p>
    </section> : null}
    {runningRefreshId ? <button type="button" className="cc-btn" onClick={actions.stop}>Stop window run after current checkpoint</button> : null}
    {jobs.length ? <section aria-label="Saved result refresh plans">
      <h3>Saved refresh plans</h3>
      <label>Refresh plan<select value={job?.id ?? ""} disabled={busy} onChange={(event) => setJobId(event.target.value)}>
        {jobs.map((item) => <option key={item.id} value={item.id}>{item.name} · {item.status} · {item.progress.completed}/{item.progress.total}</option>)}
      </select></label>
      {job ? <>
        <p>{job.status} · {job.progress.completed}/{job.progress.total} saved checkpoints · {job.skippedCount} skipped results.</p>
        <progress aria-label={`${job.name} refresh progress`} value={job.progress.completed} max={job.progress.total || 1} />
        {job.status === "completed" && job.skippedCount > 0 ? <p>Execution finished with incomplete coverage: skipped results still need attention.</p> : null}
        {job.staleUnitIds.length ? <p>{job.staleUnitIds.length} saved checkpoints no longer match current inputs. Inspect the details before retrying or creating a new plan.</p> : null}
        {job.error ? <p className="workbench-error" role="alert">{job.error.message}</p> : null}
        <div className="workbench-actions">
          {["pending", "running"].includes(job.status) ? <>
            <button type="button" className="cc-btn" disabled={locked || writeBlocked} onClick={() => void actions.mutate("refresh.advance", { refreshId: job.id })}>Run next checkpoint</button>
            <button type="button" className="cc-btn" disabled={locked || writeBlocked} onClick={() => void actions.run(job.id)}>Run remaining in this window</button>
            <button type="button" className="cc-btn" disabled={locked || writeBlocked || job.staleUnitIds.length > 0}
              onClick={() => void actions.mutate("refresh.worker.start", { refreshId: job.id })}>Refresh results in background</button>
            <button type="button" className="cc-btn" disabled={locked || writeBlocked} onClick={() => void actions.mutate("refresh.pause", { refreshId: job.id })}>Pause refresh</button>
          </> : null}
          {job.status === "paused" ? <button type="button" className="cc-btn" disabled={locked || writeBlocked}
            onClick={() => void actions.mutate("refresh.resume", { refreshId: job.id })}>Resume refresh</button> : null}
          {["failed", "blocked"].includes(job.status) ? <button type="button" className="cc-btn" disabled={locked || writeBlocked}
            onClick={() => void actions.mutate("refresh.retry", { refreshId: job.id })}>Retry after resolving blockers</button> : null}
          {!["completed", "cancelled"].includes(job.status) ? <button type="button" className="cc-btn" disabled={locked || writeBlocked}
            onClick={() => void actions.mutate("refresh.cancel", { refreshId: job.id })}>Cancel refresh</button> : null}
        </div>
        {refreshWorker && workerTargetId(refreshWorker) === job.id ? <p>Use the worker’s stop request above to pause this refresh after its current checkpoint.</p> : null}
        <RefreshJobDetails key={job.id} job={job} revision={revision} busy={busy} workerActive={!!worker} writeBlocked={writeBlocked}
          read={read} actions={actions} formats={formats} />
      </> : null}
    </section> : null}
    <p>Refreshing appends saved results. Exported spreadsheets, images and packages retain their original content; create a new export to share refreshed results.</p>
  </details></div>;
}
