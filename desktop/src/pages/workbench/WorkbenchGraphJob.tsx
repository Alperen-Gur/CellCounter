import { useEffect, useRef, useState } from "react";
import { useCataloguePins } from "./WorkbenchCatalogueBrowser";
import type { ProjectSnapshot, WorkbenchJob, WorkflowSourceSelection } from "../../../../shared/workbench/protocol";
import type { GraphControlActions, GraphJobSummary, GraphNodePreview, PreviewGraphNode } from "../../../../shared/workbench/graphProtocol";
import type { Vec3, VolumeDisplay } from "../../../../shared/workbench/volumeProtocol";
import ScientificOutput from "./ScientificOutput";
import VolumeRenderer from "./VolumeRenderer";
import useGraphCatalogue from "./useGraphCatalogue";
import WorkbenchGraphControls from "./WorkbenchGraphControls";

type Props = { job: WorkbenchJob; snapshot: ProjectSnapshot; busy: boolean;
  writeBlocked: boolean; controls: GraphControlActions;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>; previewNode: PreviewGraphNode };
const describeSelection = (selection?: WorkflowSourceSelection) => !selection ? "" :
  `${selection.target === "volume" ? `time point ${selection.timeIndex + 1}` : `${selection.zProjection} projection`} · channel ${selection.channel + 1}`;
const isGraphSummary = (value: WorkbenchJob["summary"]): value is GraphJobSummary => !!value && "kind" in value && value.kind === "dag";
const PAGE_SIZE = 50;

function SourcePicker({ labels, index, onChange, disabled, title }: {
  labels: string[]; index: number; onChange: (index: number) => void; disabled?: boolean; title: string;
}) {
  const start = Math.floor(index / PAGE_SIZE) * PAGE_SIZE;
  return <>
    <label>{title}<select value={index} disabled={disabled} onChange={(event) => onChange(Number(event.target.value))}>
      {labels.slice(start, start + PAGE_SIZE).map((name, offset) => <option key={start + offset} value={start + offset}>{start + offset + 1}. {name}</option>)}
    </select></label>
    {labels.length > PAGE_SIZE ? <div className="workbench-actions">
      <button type="button" className="cc-btn" disabled={disabled || start === 0} onClick={() => onChange(start - PAGE_SIZE)}>Previous inputs</button>
      <span>{start + 1}–{Math.min(start + PAGE_SIZE, labels.length)} of {labels.length}</span>
      <button type="button" className="cc-btn" disabled={disabled || start + PAGE_SIZE >= labels.length} onClick={() => onChange(start + PAGE_SIZE)}>Next inputs</button>
    </div> : null}
  </>;
}

function NodePreviewOutput({ result }: { result: GraphNodePreview }) {
  const [crosshair, setCrosshair] = useState<Vec3>([0, 0, 0]);
  const value = result.preview;
  const display = value.display as VolumeDisplay | undefined;
  const image = typeof value.overlayDataUrl === "string" ? value.overlayDataUrl : typeof value.dataUrl === "string" ? value.dataUrl : undefined;
  // Display bytes go to the image/volume renderer, never to the scientific table.
  const science = value.output ?? Object.fromEntries(Object.entries(value).filter(([key]) =>
    !["dataUrl", "overlayDataUrl", "display"].includes(key)));
  return <section className="workbench-graph-node-preview" aria-label="Workflow node scientific preview">
    <h4>{result.mode === "retained-measurements" ? "Saved measurements" : "Fresh calculation · not saved"}</h4>
    <p>{result.mode === "retained-measurements"
      ? "Measurements come from the retained masks on this exact input branch."
      : "This calculates the frozen node settings on its retained input. It does not save an output, replace masks or advance the batch."}</p>
    {display ? <VolumeRenderer descriptor={display} crosshair={crosshair} onCrosshair={setCrosshair}
      onPlanePick={(_plane, point) => setCrosshair(point)} /> : image ? <figure>
      <img src={image} alt={`Unsaved ${result.operation} preview for the selected workflow node`} />
      <figcaption>Bounded display preview. Measurements use the full source grid.</figcaption>
    </figure> : null}
    <ScientificOutput output={science} />
    {result.notes.length ? <p>{result.notes.join(" ")}</p> : null}
  </section>;
}

export default function WorkbenchGraphJob({ job, snapshot, busy, writeBlocked, controls, read, previewNode }: Props) {
  const [open, setOpen] = useState(false);
  const [loaded, setLoaded] = useState<{ revision: number; job: WorkbenchJob }>();
  const [checkpointIndex, setCheckpointIndex] = useState(0);
  const [nodeId, setNodeId] = useState("");
  const [summaryNodeId, setSummaryNodeId] = useState("");
  const [summaryIndex, setSummaryIndex] = useState(0);
  const [preview, setPreview] = useState<{ identity: string; result: GraphNodePreview }>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [attempt, setAttempt] = useState(0);
  const pinError = useCataloguePins(open ? [{ catalogue: "jobs", entryId: job.id }] : []);
  const latestRead = useRef(read); latestRead.current = read;
  const epoch = useRef(0);
  const revision = snapshot.project.revision;
  const { catalogue, error: catalogueError, retry: retryCatalogue } = useGraphCatalogue(read, open);
  const detail = loaded?.revision === revision && loaded.job.id === job.id ? loaded.job : undefined;
  const graph = job.workflow.graph;
  const nameFor = (id: string) => graph?.nodes.find((node) => node.id === id)?.name || id;
  const imageName = (id: string) => snapshot.images.find((image) => image.id === id)?.name ?? id;
  const checkpoints = detail?.checkpoints ?? [];
  const index = Math.min(checkpointIndex, Math.max(0, checkpoints.length - 1));
  const checkpoint = checkpoints[index];
  const selectedNode = graph?.nodes.find((node) => node.id === nodeId);
  const previewSupported = catalogue?.nodeTypes.find((kind) => kind.type === selectedNode?.type)?.previewSupported === true;
  const dependency = checkpoint?.nodes?.find((node) => node.nodeId === selectedNode?.input);
  const dependencyReady = selectedNode?.input === "$source" || dependency?.status === "completed";
  const stale = !!job.staleImageIds?.length || !!job.staleNodeIds?.length;
  const identity = JSON.stringify({ projectId: snapshot.project.id, revision, jobId: job.id, checkpointIndex: index, nodeId });
  const currentIdentity = useRef(identity); currentIdentity.current = identity;
  const currentPreview = preview?.identity === identity ? preview.result : undefined;
  const summary = isGraphSummary(detail?.summary) ? detail.summary : undefined;
  const branch = summary?.branches.find((item) => item.nodeId === summaryNodeId) ?? summary?.branches[0];
  const recordIndex = Math.min(summaryIndex, Math.max(0, (branch?.records.length ?? 0) - 1));
  const record = branch?.records[recordIndex];

  useEffect(() => {
    if (!open || busy) return;
    let current = true; setError("");
    void latestRead.current<{ job: WorkbenchJob }>("job.get", { jobId: job.id }).then((result) => {
      if (current) {
        setLoaded({ revision, job: result.job });
        setNodeId((old) => result.job.workflow.graph?.nodes.some((node) => node.id === old) ? old
          : result.job.workflow.graph?.nodes.find((node) => node.type !== "summary" && node.type !== "export")?.id ?? "");
      }
    }).catch((cause) => { if (current) setError(String(cause)); });
    return () => { current = false; };
  }, [open, busy, job.id, revision, attempt]);
  useEffect(() => { epoch.current++; setLoading(false); }, [identity]);
  const inspect = async () => {
    if (busy || loading || !detail || !selectedNode || !previewSupported || !dependencyReady || stale) return;
    const generation = ++epoch.current; setLoading(true); setError(""); setPreview(undefined);
    try {
      await previewNode({ jobId: job.id, checkpointIndex: index, nodeId, maxSize: 768 }, (result) => {
        if (epoch.current === generation && currentIdentity.current === identity) setPreview({ identity, result });
      });
    } catch (cause) { if (epoch.current === generation) setError(`${nameFor(nodeId)}: ${String(cause)}`); }
    finally { if (epoch.current === generation) setLoading(false); }
  };
  return <>
    {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    {job.nextUnit?.nodeId ? <p>Next checkpoint: <strong>{nameFor(job.nextUnit.nodeId)}</strong>
      {job.nextUnit.imageId ? ` · ${imageName(job.nextUnit.imageId)}` : ""}
      {job.nextUnit.timeIndex !== undefined ? ` · time point ${job.nextUnit.timeIndex + 1}` : ""}.</p> : null}
    <p>Completed branch outputs remain saved when a batch pauses or a later node fails. Changed inputs require a new batch; retry never discards successful checkpoints.</p>
    <WorkbenchGraphControls job={detail ?? job} checkpointIndex={index} snapshot={snapshot} busy={busy}
      writeBlocked={writeBlocked} actions={controls} read={read} />
    {job.staleNodeIds?.length ? <details><summary>Affected source and branch nodes</summary><ul>{job.staleNodeIds.map((entry, i) => {
      const id = typeof entry === "string" ? entry : entry.nodeId;
      return <li key={`${id}:${i}`}>{nameFor(id)}{typeof entry !== "string" ? ` · ${imageName(entry.imageId)} · input ${entry.checkpointIndex + 1}` : ""}</li>;
    })}</ul></details> : null}
    <details onToggle={(event) => setOpen(event.currentTarget.open)}>
      <summary>Branch checkpoints, previews and saved results</summary>
      {error ? <p role="alert" className="workbench-error">{error} <button type="button" className="cc-btn" disabled={busy} onClick={() => setAttempt((value) => value + 1)}>Reload batch details</button></p> : null}
      {open ? <>
        <div className="workbench-table"><table><caption>Progress by node across source inputs</caption>
          <thead><tr><th>Node</th><th>Operation</th><th>Completed</th><th>Total</th></tr></thead>
          <tbody>{job.nodeProgress?.map((item) => <tr key={item.nodeId}><th scope="row">{nameFor(item.nodeId)}</th>
            <td>{catalogue?.nodeTypes.find((kind) => kind.type === item.type)?.name ?? item.type}</td><td>{item.completed}</td><td>{item.total}</td></tr>)}</tbody>
        </table></div>
        {!detail ? <p role="status">{busy ? "Checkpoint details will update when the active operation finishes." : "Loading exact branch checkpoints…"}</p> : <>
          <SourcePicker title="Source image and time point" index={index} disabled={busy || loading}
            labels={checkpoints.map((item) => `${imageName(item.imageId)} · ${describeSelection(item.sourceSelection)}`)} onChange={setCheckpointIndex} />
          <div className="workbench-table"><table><caption>Branch outputs for {checkpoint ? imageName(checkpoint.imageId) : "selected source"}
            {checkpoint?.timeIndex !== undefined ? ` · time point ${checkpoint.timeIndex + 1}` : ""}</caption>
            <thead><tr><th>Node</th><th>Status</th><th>Retained output image</th><th>Output selection</th><th>Revision</th></tr></thead>
            <tbody>{checkpoint?.nodes?.map((node) => <tr key={node.nodeId}><th scope="row">{nameFor(node.nodeId)}</th><td>{node.status}</td>
              <td>{node.outputBinding?.imageId ? imageName(node.outputBinding.imageId) : "Not produced"}</td>
              <td>{describeSelection(node.outputBinding?.selection) || "—"}</td><td>{node.completedRevision ?? "—"}{node.reusedFrom ? " · reused" : node.correctionOrigin ? " · exact correction" : ""}</td></tr>)}</tbody>
          </table></div>
          <label>Node for scientific preview<select value={nodeId} disabled={busy || loading} onChange={(event) => setNodeId(event.target.value)}>
            {graph?.nodes.filter((node) => node.type !== "summary" && node.type !== "export").map((node) => <option key={node.id} value={node.id}>{nameFor(node.id)} · {node.type}</option>)}
          </select></label>
          {catalogueError ? <p className="workbench-error">{catalogueError} <button className="cc-btn" onClick={retryCatalogue}>Retry preview catalogue</button></p> : null}
          {selectedNode && previewSupported ? <>
            <button type="button" className="cc-btn" disabled={busy || loading || !dependencyReady || stale} onClick={() => void inspect()}>
              {selectedNode.type === "measurements" ? "Preview saved measurements" : "Preview fresh calculation"}</button>
            {!dependencyReady ? <p>Run the input node <strong>{nameFor(selectedNode.input ?? "")}</strong> before previewing this node.</p> : null}
            {stale ? <p>Retained source or branch results changed. Create a new batch with the intended inputs before calculating a preview.</p> : null}
          </> : selectedNode && catalogue ? <p>This node requires explicit checkpoint execution. Preview does not invoke executable models or plugins.</p> : null}
          {loading ? <p role="status">Preparing the selected node preview…</p> : null}
          {currentPreview ? <NodePreviewOutput key={identity} result={currentPreview} /> : preview ? <p>Source, node or project results changed. Request a new scientific preview.</p> : null}
          {summary ? <section aria-label="Saved branch summary">
            <h4>Saved branch results</h4>
            <p>Each record keeps its branch and original source/time identity. Technical alternatives are not pooled or counted as biological replicates.</p>
            {job.outputsCurrent === false ? <p role="status">This is a historical summary. Some inputs or export dependencies have changed.</p> : null}
            <label>Summary branch<select value={branch?.nodeId ?? ""} onChange={(event) => { setSummaryNodeId(event.target.value); setSummaryIndex(0); }}>
              {summary.branches.map((item) => <option key={item.nodeId} value={item.nodeId}>{nameFor(item.nodeId)}</option>)}
            </select></label>
            {branch ? <SourcePicker title="Summary source input" index={recordIndex}
              labels={branch.records.map((item) => `${imageName(item.sourceImageId)} · ${describeSelection(item.sourceSelection)}`)} onChange={setSummaryIndex} /> : null}
            {record ? <>
              <p><strong>{nameFor(branch!.nodeId)}</strong> · {imageName(record.sourceImageId)} · {describeSelection(record.sourceSelection)}
                {" → "}{imageName(record.imageId)} · {describeSelection(record.selection)}.</p>
              <ScientificOutput key={`${branch!.nodeId}:${recordIndex}`} output={record.summary} />
              {record.stepResults ? <details><summary>Saved assay and plugin result references</summary><ScientificOutput output={{ measurements: record.stepResults }} /></details> : null}
            </> : null}
          </section> : <p>Branch summaries become available after the batch’s summary checkpoint.</p>}
        </>}
      </> : null}
    </details>
  </>;
}
