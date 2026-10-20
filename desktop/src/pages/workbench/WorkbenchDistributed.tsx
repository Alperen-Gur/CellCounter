import { useCataloguePins } from "./WorkbenchCatalogueBrowser";
import type { CataloguePage } from "../../../../shared/workbench/catalogueProtocol";
import { useEffect, useRef, useState } from "react";
import type { ProjectSnapshot, WorkbenchWorkflow } from "../../../../shared/workbench/protocol";
import type { DistributedActions, Distribution, DistributionPreview, DistributionResultPreview,
  DistributionSummary, RestoredDistributedTask, DistributionScientificSummary } from "../../../../shared/workbench/distributionProtocol";
import { activeJobWorker } from "../../../../shared/workbench/workerProtocol";
import { isGraphWorkflow } from "../../../../shared/workbench/graphProtocol";
import type { GraphJobSummary } from "../../../../shared/workbench/graphProtocol";
import ScientificOutput from "./ScientificOutput";

type Props = {
  snapshot: ProjectSnapshot; workflow?: WorkbenchWorkflow; imageIds: string[]; timeIndices?: number[];
  scopeValid: boolean; busy: boolean; writeBlocked: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  actions: DistributedActions;
};
const describeInput = (input: { target: string; channel?: number; timeIndex?: number }) => [
  input.target === "volume" ? "Volume" : "Plane",
  input.channel === undefined ? undefined : `channel ${input.channel + 1}`,
  input.timeIndex === undefined ? undefined : `time point ${input.timeIndex + 1}`,
].filter(Boolean).join(" · ");
function BranchResultSummary({ summary, workflow }: { summary: GraphJobSummary; workflow?: WorkbenchWorkflow }) {
  const [nodeId, setNodeId] = useState("");
  const [recordIndex, setRecordIndex] = useState(0);
  const branch = summary.branches.find((item) => item.nodeId === nodeId) ?? summary.branches[0];
  const record = branch?.records[Math.min(recordIndex, Math.max(0, branch.records.length - 1))];
  const name = (item: GraphJobSummary["branches"][number]) => item.nodeName || workflow?.graph?.nodes.find((node) => node.id === item.nodeId)?.name || item.nodeId;
  return <section aria-label="Isolated branching task result">
    <p>{summary.branches.length} separate branch summaries. Branch alternatives are not pooled or counted as biological replicates.</p>
    <label>Result branch<select value={branch?.nodeId ?? ""} onChange={(event) => { setNodeId(event.target.value); setRecordIndex(0); }}>
      {summary.branches.map((item) => <option key={item.nodeId} value={item.nodeId}>{name(item)}</option>)}
    </select></label>
    {branch && branch.records.length > 1 ? <label>Source record<select value={recordIndex} onChange={(event) => setRecordIndex(Number(event.target.value))}>
      {branch.records.map((item, index) => <option key={index} value={index}>{item.sourceImageId} · {describeInput(item.sourceSelection)}</option>)}
    </select></label> : null}
    {record ? <>
      <p><strong>{name(branch!)}</strong> · source {record.sourceImageId} · {describeInput(record.sourceSelection)}.</p>
      <p>Retained output {record.imageId} · {describeInput(record.selection)}.</p>
      <ScientificOutput key={`${branch!.nodeId}:${recordIndex}`} output={record.summary} />
    </> : null}
  </section>;
}
function ResultSummary({ summary, workflow }: { summary: DistributionScientificSummary; workflow?: WorkbenchWorkflow }) {
  if ("branches" in summary) return <BranchResultSummary summary={summary} workflow={workflow} />;
  return <p>{summary.imageCount !== undefined ? `${summary.imageCount} images · ` : ""}
    {summary.cellCount !== undefined ? `${summary.cellCount.toLocaleString()} plane objects` : "Saved task results"}
    {summary.volumes ? ` · ${summary.volumes.frameCount} volume frames · ${summary.volumes.cellCount.toLocaleString()} volume objects` : ""}.
    Counts describe this task; they are not biological-replicate statistics.</p>;
}

export default function WorkbenchDistributed({ snapshot, workflow, imageIds, timeIndices, scopeValid, busy, writeBlocked, read, actions }: Props) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("Distributed analysis");
  const [distributionId, setDistributionId] = useState("");
  const [taskId, setTaskId] = useState("");
  const [preview, setPreview] = useState<{ identity: string; result: DistributionPreview }>();
  const [detail, setDetail] = useState<{ revision: number; result: Distribution }>();
  const [listed, setListed] = useState<{ revision: number; values: DistributionSummary[] }>();
  const [restored, setRestored] = useState<{ revision: number; task: RestoredDistributedTask | null }>();
  const [resultPath, setResultPath] = useState("");
  const [returned, setReturned] = useState<{ identity: string; result: DistributionResultPreview }>();
  const [allowRuntimeDifferences, setAllowRuntimeDifferences] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const [attempt, setAttempt] = useState(0);
  const epoch = useRef(0);
  const latest = useRef(read); latest.current = read;
  const pinError = useCataloguePins([{ catalogue: "distributions", entryId: distributionId }]);
  const revision = snapshot.project.revision;
  const distributions = [...new Map([...(listed?.revision === revision ? listed.values : []), ...(snapshot.distributions ?? [])].map(item => [item.id, item])).values()];
  const group = detail?.revision === revision && detail.result.id === distributionId ? detail.result : undefined;
  const task = group?.tasks.find((item) => item.id === taskId);
  const restoredTask = restored?.revision === revision ? restored.task : snapshot.distributedTask ?? null;
  const activeWorker = snapshot.jobWorkers?.some(activeJobWorker) ?? false;
  const locked = busy || loading || activeWorker;
  const args = { workflowId: workflow?.id, workflowVersion: workflow?.version, imageIds, ...(timeIndices ? { timeIndices } : {}) };
  const identity = JSON.stringify({ revision, args });
  const resultIdentity = JSON.stringify({ revision, distributionId, taskId, path: resultPath });
  const currentPreview = preview?.identity === identity ? preview.result : undefined;
  const currentReturned = returned?.identity === resultIdentity ? returned.result : undefined;
  const canPlan = !!workflow && scopeValid && imageIds.length > 0;
  const currentIdentity = useRef({ identity, resultIdentity }); currentIdentity.current = { identity, resultIdentity };
  const selectedTask = useRef({ distributionId, taskId }); selectedTask.current = { distributionId, taskId };

  useEffect(() => {
    epoch.current++; setLoading(false); setError("");
    setDistributionId((old) => old || distributions[0]?.id || "");
    return () => { epoch.current++; };
  }, [snapshot.project.id, revision]);
  useEffect(() => {
    setTaskId(""); setResultPath(""); setReturned(undefined); setError(""); setMessage("");
  }, [distributionId]);
  useEffect(() => { setReturned(undefined); setResultPath(""); setMessage(""); }, [taskId]);
  useEffect(() => {
    if (!open || busy || activeWorker || !distributionId) return;
    let current = true;
    void latest.current<{ distribution: Distribution }>("distribution.get", { distributionId }).then((result) => {
      if (current) {
        setDetail({ revision, result: result.distribution });
        setTaskId((old) => result.distribution.tasks.some((item) => item.id === old) ? old : result.distribution.tasks[0]?.id ?? "");
      }
    }).catch((cause) => { if (current) setError(String(cause)); });
    return () => { current = false; };
  }, [open, busy, activeWorker, distributionId, revision, attempt]);
  useEffect(() => {
    if (!open || busy || activeWorker || !snapshot.distributedTask) return;
    let current = true;
    void latest.current<{ task: RestoredDistributedTask | null }>("distribution.task.get").then((result) => {
      if (current) setRestored({ revision, task: result.task });
    }).catch((cause) => { if (current) setError(String(cause)); });
    return () => { current = false; };
  }, [open, busy, activeWorker, snapshot.distributedTask?.id, revision, attempt]);
  useEffect(() => { setAllowRuntimeDifferences(false); }, [restoredTask?.id, JSON.stringify(restoredTask?.runtime.differences)]);

  const inspectPlan = async () => {
    if (locked || !canPlan) return;
    const generation = ++epoch.current; setLoading(true); setError(""); setMessage(""); setPreview(undefined);
    try {
      const result = await read<DistributionPreview>("distribution.preview", args);
      if (generation === epoch.current && currentIdentity.current.identity === identity) setPreview({ identity, result });
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  const refresh = async () => {
    if (locked) return;
    const generation = ++epoch.current; setLoading(true); setError("");
    try {
      const result = await read<CataloguePage<DistributionSummary>>("project.catalogue", { catalogue: "distributions", limit: 25 });
      if (generation === epoch.current) { setListed({ revision, values: result.entries }); setAttempt((value) => value + 1); }
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  const previewResult = async () => {
    if (locked || !task || !resultPath) return;
    const generation = ++epoch.current; setLoading(true); setError(""); setReturned(undefined);
    try {
      const result = await read<DistributionResultPreview>("distribution.result.preview", { distributionId, taskId, path: resultPath });
      if (generation === epoch.current && currentIdentity.current.resultIdentity === resultIdentity) setReturned({ identity: resultIdentity, result });
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  const sourceName = (id: string) => snapshot.images.find((image) => image.id === id)?.name ?? id;

  return <details onToggle={(event) => setOpen(event.currentTarget.open)}>
    <summary>Distributed work</summary>
    <p>Export independent task bundles for another computer. Each task keeps the saved workflow and source identity.
      Returned results are retained as separate projects; collection does not replace original masks or biological assignments.</p>
    {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {message ? <p role="status">{message}</p> : null}
    {activeWorker ? <p>Stop background execution after its current checkpoint before preparing or collecting distributed work.</p> : null}
    {writeBlocked ? <p>Save or discard pending scientific edits before changing distributed work or opening package dialogs.</p> : null}
    {!restoredTask && isGraphWorkflow(workflow) ? <p>Each task carries the entire branching workflow for one source image and time point. Required runtimes and executable code still need explicit trust on the receiving computer.</p> : null}
    {restoredTask ? <section aria-label="Restored distributed task">
      <h3>Restored task</h3>
      <p>{restoredTask.workflow.name} · version {restoredTask.workflow.version} · {describeInput(restoredTask)}</p>
      {isGraphWorkflow(restoredTask.workflow) ? <p>This task retains the complete branching workflow. Run its source-bound nodes through the existing batch and Background execution controls.</p> : null}
      <p>Coordinator task {restoredTask.id}. Required models and executable plugins must be enabled and, where necessary, rebound to this computer explicitly.</p>
      {restoredTask.prepared && restoredTask.runtime.currentDifferences?.length ? <div role="status">
        <p>This computer’s runtime differs from the immutable prepared task. To run here, restore the original task bundle into a new project and prepare it explicitly.</p>
        <ul>{restoredTask.runtime.currentDifferences.map((difference, index) => <li key={index}>{difference}</li>)}</ul>
      </div> : null}
      {restoredTask.requirements.modelIds.length ? <p>Models: {restoredTask.requirements.modelIds.join(", ")}</p> : null}
      {restoredTask.requirements.pluginIds.length ? <p>Plugins: {restoredTask.requirements.pluginIds.join(", ")}</p> : null}
      {restoredTask.runtime.differences.length ? <>
        <p>Runtime differences from the coordinator:</p><ul>{restoredTask.runtime.differences.map((difference, index) => <li key={index}>{difference}</li>)}</ul>
        {!restoredTask.prepared ? <label className="workbench-inline"><input type="checkbox" checked={allowRuntimeDifferences}
          disabled={locked || writeBlocked} onChange={(event) => setAllowRuntimeDifferences(event.target.checked)} />Allow these runtime differences when preparing this task</label> : null}
      </> : null}
      {!restoredTask.prepared ? <>
        {restoredTask.requirements.requiresExportDestination ? <p>This workflow includes an export step. Preparing the job will ask for its new local ZIP destination.</p> : null}
        <button type="button" className="cc-btn" disabled={locked || writeBlocked || (!!restoredTask.runtime.differences.length && !allowRuntimeDifferences)}
          onClick={() => void actions.prepare(allowRuntimeDifferences)}>Prepare runnable job</button>
      </> : <p>Prepared job {restoredTask.job?.name ?? restoredTask.jobId} · {restoredTask.job?.status ?? "saved"}.
        Use the existing batch and Background execution controls below to run or resume it.</p>}
      {restoredTask.job ? <>
        <progress aria-label="Restored task progress" value={restoredTask.job.progress.completed} max={restoredTask.job.progress.total || 1} />
        {restoredTask.job.outputsCurrent === false ? <p>Task outputs are stale. Recompute current results before returning this task.</p> : null}
        <div className="workbench-actions"><button type="button" className="cc-btn"
          disabled={locked || writeBlocked || restoredTask.job.status !== "completed" || restoredTask.job.outputsCurrent !== true}
          onClick={() => void actions.exportPackage({ kind: "completed-task", name: `${restoredTask.workflow.name}-completed-task` })}>Export completed result…</button></div>
      </> : null}
      <p>The completed-result package is a separate export after the job finishes. A ZIP produced by a workflow’s own final export step is not the completed task package.</p>
    </section> : <fieldset disabled={locked || writeBlocked || !canPlan}>
      <legend>Create work packets</legend>
      <p>{workflow ? `${workflow.name} · version ${workflow.version} · ${imageIds.length} source images` : "Select a saved workflow above."}
        {timeIndices ? ` · time points ${timeIndices.map((value) => value + 1).join(", ")}` : ""}</p>
      {!scopeValid ? <p>Select an available time point above or use all time points.</p> : null}
      <label>Distribution name<input maxLength={200} value={name} onChange={(event) => setName(event.target.value)} /></label>
      <div className="workbench-actions">
        <button type="button" className="cc-btn" onClick={() => void inspectPlan()}>Preview work packets</button>
        <button type="button" className="cc-btn" disabled={!currentPreview || !name.trim()} onClick={() => {
          if (currentPreview) void actions.mutate<{ distribution: Distribution }>("distribution.create", { ...args, name: name.trim() }, (result) => {
            setDistributionId(result.distribution.id); setMessage(`Created ${result.distribution.taskCount} work packets. Export each task bundle below.`);
          });
        }}>Create distribution</button>
      </div>
    </fieldset>}
    {currentPreview && !restoredTask ? <section aria-label="Distributed work preview">
      <p>{currentPreview.plan.taskCount} independent tasks. Each contains a complete saved workflow for one source image{timeIndices ? " and time point" : " or volume time point"}.</p>
      {currentPreview.plan.workflow.kind === "dag" ? <p>Each task includes the whole graph with its frozen source selector and branch relationships.
        {currentPreview.plan.nodeCheckpointCount !== undefined ? ` ${currentPreview.plan.nodeCheckpointCount.toLocaleString()} scientific node checkpoints across the distribution.` : ""}
        Branches within a task are not split into separate biological inputs.</p> : null}
      <p>{currentPreview.plan.requirements.pluginIds.length} required plugins · {currentPreview.plan.requirements.modelIds.length} required models.
        Execution permissions are granted on the receiving computer.</p>
      <details><summary>Task inputs</summary><ol>{currentPreview.plan.tasks.map((input) => <li key={input.index}>
        {input.imageName ?? sourceName(input.sourceImageId)} · {describeInput(input)}
        {input.nodeCheckpointCount !== undefined ? ` · ${input.nodeCheckpointCount} node checkpoints` : ""}
        {input.segmentationBranchCount !== undefined ? ` · ${input.segmentationBranchCount} segmentation branches` : ""}
        {input.newImageCount !== undefined ? ` · ${input.newImageCount} new images` : ""}</li>)}</ol></details>
      {currentPreview.plan.referenceImageIds.length ? <details><summary>{currentPreview.plan.referenceImageIds.length} additional workflow reference images</summary>
        <ul>{currentPreview.plan.referenceImageIds.map((id) => <li key={id}>{sourceName(id)}</li>)}</ul>
        <p>These images travel with the workflow as references; they are not additional task inputs.</p>
      </details> : null}
      {currentPreview.plan.notes.length ? <p>{currentPreview.plan.notes.join(" ")}</p> : null}
    </section> : null}
    <div className="workbench-actions"><button type="button" className="cc-btn" disabled={locked} onClick={() => void refresh()}>Refresh distributed work</button></div>
    {distributions.length ? <>
      <label>Saved distribution<select value={distributionId} disabled={locked} onChange={(event) => setDistributionId(event.target.value)}>
        {!distributionId ? <option value="">Choose a distribution…</option> : null}
        {distributions.map((item) => <option key={item.id} value={item.id}>{item.name} · {item.collectedCount}/{item.taskCount} collected</option>)}
      </select></label>
      {group ? <section aria-label="Saved distribution tasks">
        <p>{group.name} · {group.status} · {group.collectedCount} of {group.taskCount} results collected.</p>
        {!group.sourceInputsCurrent ? <p className="workbench-error">Source inputs changed after this distribution was created. Its frozen tasks cannot be treated as current source analyses.</p> : null}
        <label>Task<select value={taskId} disabled={locked} onChange={(event) => setTaskId(event.target.value)}>
          {group.tasks.map((item) => <option key={item.id} value={item.id}>Task {item.index + 1} · {sourceName(item.sourceImageId)} · {describeInput(item)} · {item.status}</option>)}
        </select></label>
        {task ? <>
          <p>Task {task.index + 1} · {describeInput(task)} · {task.status}</p>
          {task.nodeCheckpointCount !== undefined ? <p>{task.nodeCheckpointCount} scientific node checkpoints · {task.segmentationBranchCount ?? "—"} segmentation branches · {task.newImageCount ?? "—"} new images.</p> : null}
          <button type="button" className="cc-btn" disabled={locked || writeBlocked || !group.sourceInputsCurrent || task.status === "collected"}
            onClick={() => void actions.exportPackage({ kind: "task-bundle", distributionId: group.id, taskId: task.id,
              name: `${group.name}-task-${task.index + 1}` })}>Export task bundle…</button>
          {task.bundle ? <details><summary>Exported bundle</summary><p className="workbench-project-path">{task.bundle.destination}</p>
            <p className="workbench-project-path">SHA-256: {task.bundle.sha256}</p><p>{task.bundle.exportedAt}</p></details> : null}
          {task.result ? <section aria-label="Collected isolated result">
            <h4>Collected result</h4><ResultSummary summary={task.result.summary} />
            <p>Retained separately from this project’s image library.</p>
            <button type="button" className="cc-btn" disabled={locked || writeBlocked}
              onClick={() => void actions.exportPackage({ kind: "collected-result", distributionId: group.id, taskId: task.id,
                name: `${group.name}-task-${task.index + 1}-result` })}>Export collected result…</button>
            <details><summary>Result provenance</summary><p>Collected {task.result.collectedAt} · source project {task.result.sourceProjectId}</p>
              <p className="workbench-project-path">Snapshot SHA-256: {task.result.snapshotHash}</p>
              <p className="workbench-project-path">Package SHA-256: {task.result.sourcePackageHash}</p></details>
          </section> : <section aria-label="Collect returned task result">
            <div className="workbench-actions">
              <button type="button" className="cc-btn" disabled={locked || writeBlocked || !group.sourceInputsCurrent} onClick={() => {
                const requestedTask = task.id; const requestedDistribution = group.id;
                void actions.chooseResult((path) => {
                  if (selectedTask.current.taskId === requestedTask && selectedTask.current.distributionId === requestedDistribution) {
                    setResultPath(path); setReturned(undefined); setError("");
                  }
                });
              }}>Choose returned result ZIP…</button>
              <button type="button" className="cc-btn" disabled={locked || !resultPath || !group.sourceInputsCurrent} onClick={() => void previewResult()}>Preview returned result</button>
            </div>
            {resultPath ? <p className="workbench-project-path">{resultPath}</p> : null}
            {currentReturned ? <>
              <p>Verified task {currentReturned.taskId} · job {currentReturned.job.status} · {currentReturned.job.progress.completed}/{currentReturned.job.progress.total} checkpoints.</p>
              <ResultSummary summary={currentReturned.summary} workflow={currentReturned.job.workflow} />
              {currentReturned.runtimeDifferences.length ? <><p>Runtime differences recorded in this result:</p><ul>{currentReturned.runtimeDifferences.map((difference, index) => <li key={index}>{difference}</li>)}</ul></> : null}
              {currentReturned.notes.length ? <p>{currentReturned.notes.join(" ")}</p> : null}
              <button type="button" className="cc-btn" disabled={locked || writeBlocked || !group.sourceInputsCurrent} onClick={() => {
                void actions.mutate("distribution.result.collect", { distributionId, taskId, path: resultPath,
                  previewFingerprint: currentReturned.previewFingerprint }, () => { setReturned(undefined); setResultPath("");
                  setMessage("Collected the completed task as a separate result project. Original image masks and assignments are unchanged."); });
              }}>Collect isolated result</button>
            </> : returned ? <p>The project or selected task changed. Preview the result again before collection.</p> : null}
          </section>}
        </> : null}
        {group.notes.length ? <p>{group.notes.join(" ")}</p> : null}
      </section> : <p role="status">Loading saved task details…</p>}
    </> : <p>No distributed work has been created in this project.</p>}
  </details>;
}
