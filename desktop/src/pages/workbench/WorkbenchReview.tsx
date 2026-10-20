import { useCataloguePins } from "./WorkbenchCatalogueBrowser";
import WorkbenchImageSelector from "./WorkbenchImageSelector";
import { useEffect, useRef, useState } from "react";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import type { ReviewDecision, ReviewPreview, ReviewSession } from "../../../../shared/workbench/reviewProtocol";
import type { VolumeWorkflowConfiguration } from "../../../../shared/workbench/volumeProtocol";
import ScientificOutput from "./ScientificOutput";

type Props = { snapshot: ProjectSnapshot; imageId: string; busy: boolean; volumeMode: boolean; volume?: VolumeWorkflowConfiguration;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void> };

export default function WorkbenchReview({ snapshot, imageId, busy, volumeMode, volume, read, act }: Props) {
  const sessions = snapshot.reviewSessions ?? [];
  const [name, setName] = useState("Random quality-control sample");
  const [scope, setScope] = useState("selected");
  const [reviewImageIds, setReviewImageIds] = useState<string[]>([]);
  const [unit, setUnit] = useState<"image" | "cell">("image");
  const [sampleSize, setSampleSize] = useState(20);
  const [seed, setSeed] = useState(42);
  const [acceptedOnly, setAcceptedOnly] = useState(true);
  const [blinded, setBlinded] = useState(true);
  const [independent, setIndependent] = useState(true);
  const [reviewerNames, setReviewerNames] = useState(["Reviewer 1", "Reviewer 2"]);
  const [reviewerIds] = useState(() => [crypto.randomUUID(), crypto.randomUUID()]);
  const [sessionId, setSessionId] = useState("");
  const [reviewerId, setReviewerId] = useState("");
  const [session, setSession] = useState<ReviewSession>();
  const [itemId, setItemId] = useState("");
  const [preview, setPreview] = useState<ReviewPreview>();
  const [showMasks, setShowMasks] = useState(true);
  const [plane, setPlane] = useState<"xy" | "xz" | "yz">("xy");
  const [planeIndex, setPlaneIndex] = useState("");
  const [reason, setReason] = useState("");
  const [errorType, setErrorType] = useState("none");
  const [revealReason, setRevealReason] = useState("");
  const [summary, setSummary] = useState<unknown>();
  const [error, setError] = useState("");
  const [reading, setReading] = useState(false);
  const [modalOpen, setModalOpen] = useState(false);
  const epoch = useRef(0);
  const previewEpoch = useRef(0);
  const summaryEpoch = useRef(0);
  const latest = useRef({ read, revision: snapshot.project.revision });
  latest.current = { read, revision: snapshot.project.revision };
  const dialog = useRef<HTMLDialogElement>(null);
  const item = session?.items?.find((entry) => entry.id === itemId);
  const pinError = useCataloguePins([{ catalogue: "reviewSessions", entryId: sessionId }]);
  const descriptor = sessions.find((entry) => entry.id === sessionId);
  const selection = volumeMode && volume ? { target: "volume", timeIndices: [volume.timeIndex], channel: volume.channel }
    : { target: "plane" };
  const sourceIds = scope === "selected" ? imageId ? [imageId] : [] : reviewImageIds;

  useEffect(() => {
    setSessionId((id) => id || sessions[0]?.id || "");
    setSummary(undefined); summaryEpoch.current++;
    return () => { summaryEpoch.current++; };
  }, [snapshot.project.revision]);
  useEffect(() => {
    setReviewerId((id) => descriptor?.reviewers.some((entry) => entry.id === id) ? id : descriptor?.reviewers[0]?.id ?? "");
  }, [sessionId, snapshot.project.revision]);
  useEffect(() => {
    const generation = ++epoch.current;
    setSession(undefined); setPreview(undefined); setReading(false); setError("");
    if (!sessionId || !reviewerId || busy || !modalOpen) return;
    setReading(true);
    void latest.current.read<{ session: ReviewSession }>("review.session.get", { sessionId, reviewerId }).then((result) => {
      if (epoch.current !== generation) return;
      setSession(result.session);
      setItemId((id) => result.session.items?.some((entry) => entry.id === id) ? id
        : result.session.items?.find((entry) => !entry.ownDecision)?.id ?? result.session.items?.[0]?.id ?? "");
    }).catch((cause) => { if (epoch.current === generation) setError(String(cause)); })
      .finally(() => { if (epoch.current === generation) setReading(false); });
    return () => { epoch.current++; };
  }, [sessionId, reviewerId, snapshot.project.revision, busy, modalOpen]);
  useEffect(() => {
    const generation = ++previewEpoch.current;
    setPreview(undefined); setReason(""); setErrorType("none");
    if (!session || !itemId || busy || !modalOpen) return;
    void latest.current.read<ReviewPreview>("review.item.preview", {
      sessionId: session.id, itemId, maxSize: 1000,
      ...(session.target === "volume" ? { plane, ...(planeIndex !== "" ? { index: Number(planeIndex) } : {}) } : {}),
    }).then((result) => { if (previewEpoch.current === generation) setPreview(result); })
      .catch((cause) => { if (previewEpoch.current === generation) setError(String(cause)); });
    return () => { previewEpoch.current++; };
  }, [session, itemId, plane, planeIndex, busy, modalOpen]);
  useEffect(() => {
    if (modalOpen && dialog.current && !dialog.current.open) dialog.current.showModal();
    if (!modalOpen && dialog.current?.open) dialog.current.close();
  }, [modalOpen]);
  const decide = (decision: ReviewDecision) => act("review.decision", {
    sessionId, itemId, reviewerId, decision, errorType, ...(reason.trim() ? { reason: reason.trim() } : {}),
  });
  const getSummary = async () => {
    const generation = ++summaryEpoch.current;
    try {
      const result = await read("review.summary", sessionId ? { sessionId } : {});
      if (summaryEpoch.current === generation) { setSummary(result); setError(""); }
    } catch (cause) { if (summaryEpoch.current === generation) setError(String(cause)); }
  };
  return <div className="workbench-automation"><details><summary>Review and quality control</summary>
    {!modalOpen && error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <p>Sample apparently satisfactory results as well as suspected errors. Each review retains the exact masks shown;
      later corrections mark the sampled inputs as changed.</p>
    <fieldset disabled={busy}>
      <div className="workbench-actions">
        <button className="cc-btn" disabled={!imageId || (volumeMode && !volume)} onClick={() => void act("review.flag", {
          imageIds: [imageId], ...selection, state: "accepted",
        })}>Mark selected analysis satisfactory</button>
        <button className="cc-btn" disabled={!imageId || (volumeMode && !volume)} onClick={() => void act("review.flag", {
          imageIds: [imageId], ...selection, state: "needs-review",
        })}>Flag selected analysis for review</button>
      </div>
    </fieldset>
    <div className="workbench-editor-grid">
      <fieldset disabled={busy}>
        <h3>Create a frozen review sample</h3>
        <label>Session name<input value={name} maxLength={200} onChange={(event) => setName(event.target.value)} /></label>
        <label>Population<select value={scope} onChange={(event) => setScope(event.target.value)}>
          <option value="selection">Explicit analyzed-image selection</option><option value="selected">Selected image</option>
        </select></label>
        {scope === "selection" ? <WorkbenchImageSelector label="Review population" multiple selectedIds={reviewImageIds} onChange={setReviewImageIds} disabled={busy}
          filters={{ analysisTarget: volumeMode ? "volume" : "plane" }} eligibilityNote="The selected IDs define the full sampling population, including images on other pages." /> : null}
        <label>Sample unit<select value={unit} onChange={(event) => setUnit(event.target.value as "image" | "cell")}>
          <option value="image">Image or volume frame</option><option value="cell">Individual object</option>
        </select></label>
        <label>Sample size<input type="number" min={1} max={1000} value={sampleSize} onChange={(event) => setSampleSize(Number(event.target.value))} /></label>
        <label>Sampling seed<input type="number" min={0} step={1} value={seed} onChange={(event) => setSeed(Number(event.target.value))} /></label>
        <label className="workbench-inline"><input type="checkbox" checked={acceptedOnly} onChange={(event) => setAcceptedOnly(event.target.checked)} />Sample only analyses marked satisfactory</label>
        <label className="workbench-inline"><input type="checkbox" checked={blinded} onChange={(event) => setBlinded(event.target.checked)} />Hide source, condition and model identity</label>
        <label className="workbench-inline"><input type="checkbox" checked={independent} onChange={(event) => setIndependent(event.target.checked)} />Require two independent reviewers</label>
        {reviewerNames.slice(0, independent ? 2 : 1).map((value, index) => <label key={index}>Reviewer {index + 1} name
          <input value={value} maxLength={200} onChange={(event) => setReviewerNames((old) => old.map((entry, i) => i === index ? event.target.value : entry))} />
        </label>)}
        <button className="cc-btn" disabled={!name.trim() || !sourceIds.length || (volumeMode && !volume) ||
          reviewerNames.slice(0, independent ? 2 : 1).some((value) => !value.trim())}
          onClick={() => void act("review.session.create", { name: name.trim(), imageIds: sourceIds, ...selection,
            unit, sampleSize, seed, acceptedOnly, blinded, requiredReviews: independent ? 2 : 1,
            reviewers: reviewerNames.slice(0, independent ? 2 : 1).map((value, index) => ({ id: reviewerIds[index], name: value.trim() })),
          })}>Create review sample</button>
      </fieldset>
      <fieldset disabled={busy}>
        <h3>Saved review sessions</h3>
        <label>Session<select value={sessionId} onChange={(event) => setSessionId(event.target.value)}>
          {!sessions.length ? <option value="">Create a review sample first</option> : null}
          {sessions.map((entry) => <option key={entry.id} value={entry.id}>{entry.name} · {entry.progress.resolved}/{entry.progress.total} resolved</option>)}
        </select></label>
        {descriptor ? <p>{descriptor.sampleSize} sampled {descriptor.unit === "cell" ? "objects" : "images/frames"} from {descriptor.populationSize}.
          {descriptor.progress.conflicts == null ? "" : ` ${descriptor.progress.conflicts} conflicts · `}
          {" "}{descriptor.progress.stale} changed inputs.</p> : null}
        <button className="cc-btn" disabled={!sessionId} onClick={() => setModalOpen(true)}>Open review desk</button>
        <button className="cc-btn" disabled={!sessionId} onClick={() => void getSummary()}>Calculate review summary</button>
        <p>Reviewer names are recorded declarations. This local workbench does not authenticate individual reviewers.</p>
      </fieldset>
    </div>
    {summary ? <ScientificOutput output={summary} /> : null}
    <dialog ref={dialog} className="workbench-review-dialog" onCancel={() => setModalOpen(false)} onClose={() => setModalOpen(false)}>
      <header className="workbench-heading"><h2>Review desk</h2>
        <button className="cc-btn" onClick={() => setModalOpen(false)}>Close review</button></header>
      {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
      <div className="workbench-editor-grid">
        <fieldset disabled={busy || reading}>
          <label>Declared reviewer<select value={reviewerId} onChange={(event) => {
            setPreview(undefined); setSession(undefined); setItemId(""); setReviewerId(event.target.value);
          }}>{descriptor?.reviewers.map((entry) => <option key={entry.id} value={entry.id}>{entry.name}</option>)}</select></label>
          <label>Sample<select value={itemId} onChange={(event) => { setPlaneIndex(""); setItemId(event.target.value); }}>
            {session?.items?.map((entry) => <option key={entry.id} value={entry.id}>{entry.code} · {entry.status}{entry.stale ? " · inputs changed" : ""}</option>)}
          </select></label>
          <button className="cc-btn" disabled={!session?.items?.some((entry) => !entry.ownDecision && entry.id !== itemId)}
            onClick={() => { setPlaneIndex(""); setItemId(session?.items?.find((entry) => !entry.ownDecision && entry.id !== itemId)?.id ?? itemId); }}>Next unreviewed sample</button>
          <label className="workbench-inline"><input type="checkbox" checked={showMasks} onChange={(event) => setShowMasks(event.target.checked)} />Show retained masks</label>
          {preview?.plane ? <>
            <label>Plane<select value={plane} onChange={(event) => { setPlane(event.target.value as typeof plane); setPlaneIndex(""); }}>
              <option value="xy">XY</option><option value="xz">XZ</option><option value="yz">YZ</option>
            </select></label>
            <label>Plane index (starting at 1)<input type="number" min={1} max={preview.sliceCount} step={1} value={planeIndex === "" ? "" : Number(planeIndex) + 1}
              placeholder={preview.index == null ? "Central plane" : String(preview.index + 1)}
              onChange={(event) => setPlaneIndex(event.target.value === "" ? "" : String(Number(event.target.value) - 1))} /></label>
          </> : null}
        </fieldset>
        <fieldset disabled={busy || reading || !preview || !reviewerId || !item || item.stale}>
          <label>Observed error<select value={errorType} onChange={(event) => setErrorType(event.target.value)}>
            {["none", "missed-object", "false-positive", "boundary", "merge", "split", "other"].map((value) =>
              <option key={value} value={value}>{value.replaceAll("-", " ")}</option>)}
          </select></label>
          <label>Decision note<textarea value={reason} maxLength={2000} onChange={(event) => setReason(event.target.value)} /></label>
          <div className="workbench-actions">
            <button className="cc-btn" onClick={() => void decide("accept")}>Accept</button>
            <button className="cc-btn" onClick={() => void decide("reject")}>Reject</button>
            <button className="cc-btn" onClick={() => void decide("uncertain")}>Uncertain</button>
          </div>
          {item?.ownDecision ? <p>Your recorded decision: {item.ownDecision.decision}. New decisions retain the earlier record.</p> : null}
          {item?.decisions ? <ScientificOutput output={{ decisions: item.decisions }} /> : null}
          {item && item.reviewCount >= item.requiredReviews ? <div className="workbench-actions">
            <button className="cc-btn" disabled={!reason.trim()} onClick={() => void act("review.adjudicate", {
              sessionId, itemId, decision: "accept", reason: reason.trim(),
            })}>Adjudicate: accept</button>
            <button className="cc-btn" disabled={!reason.trim()} onClick={() => void act("review.adjudicate", {
              sessionId, itemId, decision: "reject", reason: reason.trim(),
            })}>Adjudicate: reject</button>
          </div> : null}
        </fieldset>
      </div>
      {reading ? <p role="status">Loading retained review inputs…</p> : null}
      {preview ? <figure>
        <img className="workbench-review-image" src={showMasks ? preview.overlayDataUrl : preview.dataUrl} alt={`Review sample ${preview.code}${showMasks ? " with retained masks" : ""}`} />
        <figcaption>{preview.code}{preview.stale ? " · Current analysis differs from this retained sample." : ""}
          {preview.region ? ` · Region ${preview.region.width} × ${preview.region.height} pixels` : ""}</figcaption>
      </figure> : null}
      {session?.blinded ? <details><summary>End blinding for this session</summary>
        <label>Reason<input value={revealReason} maxLength={2000} onChange={(event) => setRevealReason(event.target.value)} /></label>
        <button className="cc-btn" disabled={busy || !revealReason.trim()} onClick={() => void act("review.reveal", {
          sessionId, reason: revealReason.trim(),
        })}>Reveal source identities and record this action</button>
      </details> : null}
    </dialog>
  </details></div>;
}
