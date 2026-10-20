import WorkbenchImageSelector from "./WorkbenchImageSelector";
import { useState } from "react";
import type { ProjectSnapshot, WorkbenchJob } from "../../../../shared/workbench/protocol";
import type { GraphContinuation, GraphControlActions, GraphReview } from "../../../../shared/workbench/graphProtocol";
import { workflowHasExport } from "../../../../shared/workbench/graphProtocol";

type Props = { job: WorkbenchJob; checkpointIndex: number; snapshot: ProjectSnapshot; busy: boolean; writeBlocked: boolean;
  actions: GraphControlActions; read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T> };
export default function WorkbenchGraphControls({ job, checkpointIndex, snapshot, busy, writeBlocked, actions, read }: Props) {
  const revision = snapshot.project.revision;
  const [review, setReview] = useState<{ revision: number; value: GraphReview }>();
  const [reason, setReason] = useState("");
  const [recommendation, setRecommendation] = useState<"approve" | "revise" | "reject">("revise");
  const [humanDecision, setHumanDecision] = useState(false);
  const [corrections, setCorrections] = useState<Record<string, string>>({});
  const [exportDestination, setExportDestination] = useState("");
  const [preview, setPreview] = useState<{ identity: string; value: GraphContinuation }>();
  const [error, setError] = useState("");
  const pending = job.pendingReview;
  const currentReview = review?.revision === revision && review.value.jobId === job.id && review.value.nodeId === pending?.nodeId && review.value.checkpointIndex === pending?.checkpointIndex ? review.value : undefined;
  const checkpoint = job.checkpoints?.[checkpointIndex];
  const graph = job.workflow.graph;
  const nameFor = (id: string) => graph?.nodes.find(node => node.id === id)?.name || id;
  const outputNodes = checkpoint?.nodes?.filter(node => node.status === "completed" && ["analysis", "volume-analysis", "model-segmentation", "plugin-segmentation", "mask-merge"].includes(graph?.nodes.find(value => value.id === node.nodeId)?.type ?? "")) ?? [];
  const selectedCorrections = outputNodes.filter(node => corrections[node.nodeId]).map(node => ({ nodeId: node.nodeId, imageId: corrections[node.nodeId] }));
  const continuationArgs = { jobId: job.id, checkpointIndex, corrections: selectedCorrections, ...(workflowHasExport(job.workflow) && exportDestination ? { exportDestination } : {}) };
  const identity = JSON.stringify({ revision, args: continuationArgs });
  const currentPreview = preview?.identity === identity ? preview.value : undefined;
  const perform = (action: () => Promise<void>) => actions.run(async () => { setError(""); try { await action(); } catch (cause) { setError(String(cause)); } });
  const reviewArgs = currentReview ? { jobId: job.id, checkpointIndex: currentReview.checkpointIndex, nodeId: currentReview.nodeId, inputFingerprint: currentReview.inputFingerprint, reason: reason.trim() } : undefined;
  return <section aria-label="Branch review and corrected continuation">
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {pending ? <section aria-label="Pending branch review"><h4>Awaiting review · {nameFor(pending.nodeId)}</h4>
      <p>Source input {pending.checkpointIndex + 1} · {pending.prompt}</p><p>{pending.requireHuman ? "A human decision is required. Agent recommendations cannot release this gate." : "This gate accepts an explicit human or agent decision."} Background execution has stopped at this checkpoint.</p>
      <button className="cc-btn" disabled={busy} onClick={() => void perform(async () => { setReview({ revision, value: (await read<{ review: GraphReview }>("job.graph.review.get", { jobId: job.id, checkpointIndex: pending.checkpointIndex, nodeId: pending.nodeId })).review }); setHumanDecision(false); })}>Read exact review input and history</button>
      {currentReview ? <><p>{currentReview.inputsCurrent ? "The retained input binding is current." : "The input mask or source changed. Use a corrected continuation; this gate cannot accept a decision."}</p>
        <button className="cc-btn" disabled={busy || writeBlocked || !currentReview.inputsCurrent} onClick={() => void actions.openInput(currentReview.inputBinding)}>Open exact mask in correction workspace</button>
        <p className="workbench-project-path">Input image {currentReview.inputBinding.imageId} · fingerprint {currentReview.inputFingerprint}</p>
        <fieldset disabled={busy || writeBlocked || !currentReview.inputsCurrent || !currentReview.nextActions.includes("decide")}><legend>Explicit review decision</legend>
          <label>Reason / review note<textarea rows={2} value={reason} maxLength={2000} onChange={event => setReason(event.target.value)} /></label>
          <label><input type="checkbox" checked={humanDecision} onChange={event => setHumanDecision(event.target.checked)} /> I have reviewed this exact input and am recording a human decision</label>
          <div className="workbench-actions"><button className="cc-btn" disabled={!humanDecision || !reason.trim()} onClick={() => reviewArgs && void actions.mutate("job.graph.review.decide", { ...reviewArgs, decision: "approve", reviewerKind: "human" }, revision)}>Approve this gate</button>
            <button className="cc-btn" disabled={!humanDecision || !reason.trim()} onClick={() => reviewArgs && void actions.mutate("job.graph.review.decide", { ...reviewArgs, decision: "reject", reviewerKind: "human" }, revision)}>Reject and block this gate</button></div>
          <p>Approval permits an explicit subsequent run; it does not silently restart a worker. Rejection retains checkpoints and can be superseded only by another explicit decision on the unchanged input.</p>
        </fieldset>
        <details><summary>Record a recommendation without releasing the gate</summary><fieldset disabled={busy || writeBlocked || !currentReview.inputsCurrent || !currentReview.nextActions.includes("recommend")}>
          <label>Recommendation<select value={recommendation} onChange={event => setRecommendation(event.target.value as typeof recommendation)}><option value="approve">Approve</option><option value="revise">Revise</option><option value="reject">Reject</option></select></label><p>The review note above is retained with this recommendation.</p><button className="cc-btn" disabled={!reason.trim()} onClick={() => reviewArgs && void actions.mutate("job.graph.review.recommend", { ...reviewArgs, recommendation }, revision)}>Save recommendation only</button>
        </fieldset></details>
        <details><summary>Recommendation and decision history</summary><ul>{currentReview.recommendations.map(value => <li key={value.id}>Recommendation: {value.recommendation} · {value.actor.name} ({value.actor.kind}) · {value.reason}</li>)}{currentReview.decisions.map(value => <li key={value.id}>Decision: {value.decision} · {value.actor.name} ({value.reviewerKind}) · {value.reason}</li>)}</ul><p>{currentReview.identityNote}</p></details>
      </> : null}
    </section> : null}
    {job.continuation ? <p>This job continues source input {job.continuation.checkpointIndex + 1} of {job.continuation.sourceJobId}. Corrected masks were copied into independent branches; previous decisions remain historical.</p> : null}
    {outputNodes.length ? <details><summary>Continue from corrected branch masks</summary>
      <p>Create one new job for the selected source image/time. Choose completed segmentation or merge outputs whose masks were corrected; compatible ancestors are reused and descendants, reviews and reports run anew.</p>
      <fieldset disabled={busy || writeBlocked}><legend>Corrected source masks · input {checkpointIndex + 1}</legend>
        {outputNodes.map(node => { const binding = node.outputBinding; return <div key={node.nodeId}>
          <label><input type="checkbox" checked={!!corrections[node.nodeId]} onChange={event => setCorrections(previous => ({ ...previous, [node.nodeId]: event.target.checked ? binding?.imageId ?? "" : "" }))} /> Use corrected masks for {nameFor(node.nodeId)}</label>
          {binding?.imageId ? <button className="cc-btn" onClick={() => void actions.openInput(binding)}>Open {nameFor(node.nodeId)} for correction</button> : null}
          {corrections[node.nodeId] ? <WorkbenchImageSelector label={`Corrected masks for ${nameFor(node.nodeId)}`}
            selectedIds={[corrections[node.nodeId]]} disabled={busy || writeBlocked}
            filters={{ sourceHash: binding?.sourceHash, analysisTarget: binding?.selection?.target === "volume" ? "volume" : "plane" }}
            onChange={ids => setCorrections(previous => ({ ...previous, [node.nodeId]: ids[0] ?? "" }))}
            eligibilityNote="The canonical continuation preview validates exact source grid, support and selected frame before any copy." /> : null}
        </div>; })}
        {workflowHasExport(job.workflow) ? <><button className="cc-btn" onClick={() => void actions.chooseExport(setExportDestination)}>Choose a new continuation package path…</button>{exportDestination ? <p className="workbench-project-path">{exportDestination}</p> : <p>A new ZIP destination is required because this workflow exports a package.</p>}</> : null}
        <button className="cc-btn" disabled={!selectedCorrections.length || selectedCorrections.length > 8 || (workflowHasExport(job.workflow) && !exportDestination)} onClick={() => void perform(async () => setPreview({ identity, value: await read<GraphContinuation>("job.graph.continue.preview", continuationArgs) }))}>Preview corrected continuation</button>
        {preview && !currentPreview ? <p>Corrections, source input or project state changed. Preview the continuation again.</p> : null}
        {currentPreview ? <><p>{currentPreview.plan.newImageCount} new independent images.</p><p>Reused nodes: {currentPreview.plan.reusedNodeIds.map(nameFor).join("; ") || "none"}.</p><p>Reset descendants: {currentPreview.plan.resetNodeIds.map(nameFor).join("; ") || "none"}.</p>{currentPreview.plan.notes.map((note, index) => <p key={index}>{note}</p>)}<button className="cc-btn" onClick={() => void actions.mutate("job.graph.continue.run", { ...continuationArgs, previewFingerprint: currentPreview.previewFingerprint }, revision)}>Create corrected continuation job</button></> : null}
      </fieldset>
    </details> : null}
  </section>;
}
