import { useEffect, useState } from "react";
import type { PropagationPreview, TemporalPropagation, TemporalTrackingPreview } from "../../../../shared/workbench/temporalProtocol";
import ScientificOutput from "./ScientificOutput";

type Props = { imageId: string; channel: number; timeIndex: number; timeCount: number; revision: number; busy: boolean;
  read: <T>(operation: string, args: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void>;
  runRead: (action: () => Promise<void>) => Promise<void> };
type TargetDraft = { key: string; timeIndex: number; labelId: string; x: number; y: number; z: number; replacements: string; allowClipping: boolean; skip: boolean };
const target = (timeIndex: number): TargetDraft => ({ key: crypto.randomUUID(), timeIndex, labelId: "", x: 0, y: 0, z: 0, replacements: "", allowClipping: false, skip: false });
const fmt = (value: number | undefined) => value == null ? "—" : value.toLocaleString(undefined, { maximumFractionDigits: 3 });
const labels = (text: string) => text.trim() ? text.trim().split(/[\s,;]+/).map(Number) : [];

export default function WorkbenchTemporal({ imageId, channel, timeIndex, timeCount, revision, busy, read, act, runRead }: Props) {
  const [first, setFirst] = useState(0);
  const [last, setLast] = useState(timeCount - 1);
  const [step, setStep] = useState(1);
  const [distance, setDistance] = useState(20);
  const [units, setUnits] = useState<"voxel" | "um">("voxel");
  const [gap, setGap] = useState(0);
  const [drift, setDrift] = useState<"none" | "explicit" | "phase-correlation">("none");
  const [maxShift, setMaxShift] = useState(20);
  const [offsets, setOffsets] = useState<Record<number, { x: number; y: number; z: number }>>({});
  const [offsetPage, setOffsetPage] = useState(0);
  const [divisions, setDivisions] = useState(false);
  const [minimumRatio, setMinimumRatio] = useState(.5);
  const [maximumRatio, setMaximumRatio] = useState(2);
  const [daughterDistance, setDaughterDistance] = useState(20);
  const [ambiguity, setAmbiguity] = useState(.15);
  const [replaceGraph, setReplaceGraph] = useState(false);
  const [reason, setReason] = useState("");
  const [tracking, setTracking] = useState<{ key: string; revision: number; value: TemporalTrackingPreview }>();
  const [sourceTime, setSourceTime] = useState(timeIndex);
  const [sourceLabel, setSourceLabel] = useState(1);
  const [motion, setMotion] = useState<"lineage-centroid" | "drift" | "explicit">("lineage-centroid");
  const [targets, setTargets] = useState<TargetDraft[]>([target(Math.min(timeCount - 1, timeIndex + 1))]);
  const [propagationReason, setPropagationReason] = useState("");
  const [visualTime, setVisualTime] = useState<number>();
  const [propagation, setPropagation] = useState<{ key: string; revision: number; value: PropagationPreview }>();
  const [history, setHistory] = useState<{ revision: number; values: TemporalPropagation[] }>();
  const [undoReason, setUndoReason] = useState("");
  const [error, setError] = useState("");
  const times = Number.isInteger(step) && step >= 1 && Number.isInteger(first) && Number.isInteger(last) && first >= 0 && last >= first && last < timeCount
    ? Array.from({ length: Math.min(1001, Math.floor((last - first) / step) + 1) }, (_, index) => first + index * step) : [];
  const trackingArgs = { imageId, channel, timeIndices: times, maxDistancePerFrame: distance, units, maxGapFrames: gap,
    drift: { mode: drift, ...(drift === "explicit" ? { offsets: times.map(time => ({ timeIndex: time, ...(offsets[time] ?? { x: 0, y: 0, z: 0 }) })) } : drift === "phase-correlation" ? { maxShiftVox: maxShift } : {}) },
    division: { enabled: divisions, ...(divisions ? { minCombinedVolumeRatio: minimumRatio, maxCombinedVolumeRatio: maximumRatio, maxDaughterDistance: daughterDistance, ambiguityMargin: ambiguity } : {}) },
    replaceGraph, ...(reason.trim() ? { reason: reason.trim() } : {}) };
  const trackingKey = JSON.stringify(trackingArgs);
  const currentTracking = tracking?.revision === revision && tracking.key === trackingKey ? tracking.value : undefined;
  const trackingNodes = new Map(currentTracking?.graph.nodes.map(node => [node.id, node]));
  const propagationArgs = { imageId, channel, sourceTimeIndex: sourceTime, sourceLabelId: sourceLabel, motion, reason: propagationReason.trim(),
    targets: targets.map(value => ({ timeIndex: value.timeIndex, ...(value.labelId.trim() ? { labelId: Number(value.labelId) } : {}),
      ...(motion === "explicit" ? { shiftVox: { x: value.x, y: value.y, z: value.z } } : {}),
      ...(value.replacements.trim() ? { replaceLabelIds: labels(value.replacements) } : {}), allowClipping: value.allowClipping, skip: value.skip })) };
  const propagationKey = JSON.stringify(propagationArgs);
  const currentPropagation = propagation?.revision === revision && propagation.key === propagationKey ? propagation.value : undefined;
  const validTargets = targets.length > 0 && targets.length <= 32 && new Set(targets.map(value => value.timeIndex)).size === targets.length
    && targets.every(value => Number.isInteger(value.timeIndex) && value.timeIndex >= 0 && value.timeIndex < timeCount && value.timeIndex !== sourceTime
      && (!value.labelId || Number.isInteger(Number(value.labelId)) && Number(value.labelId) > 0)
      && (motion !== "explicit" || value.skip || value.labelId.trim().length > 0)
      && labels(value.replacements).every(label => Number.isInteger(label) && label > 0));
  const perform = (action: () => Promise<void>) => runRead(async () => { setError(""); try { await action(); } catch (cause) { setError(String(cause)); } });
  const editTarget = (key: string, changes: Partial<TargetDraft>) => setTargets(previous => previous.map(value => value.key === key ? { ...value, ...changes } : value));
  const loadHistory = async () => setHistory({ revision, values: (await read<{ propagations: TemporalPropagation[] }>("temporal.propagate.list", { imageId })).propagations });
  useEffect(() => { setTracking(undefined); setPropagation(undefined); setHistory(undefined); }, [imageId, channel]);

  return <section aria-label="Temporal inference and correction">
    <details><summary>Infer tracks, gaps and divisions</summary>
      <p>Use current saved volume labels to preview drift-aware tracking. Divisions remain inferred until a researcher reviews them in the lineage editor below.</p>
      {error ? <p className="workbench-error" role="alert">{error}</p> : null}
      <fieldset disabled={busy || timeCount < 2}>
        <legend>Time selection and association</legend>
        <div className="workbench-editor-grid">
          <label>First time point<input type="number" min={1} max={timeCount} value={first + 1} onChange={event => setFirst(Number(event.target.value) - 1)} /></label>
          <label>Last time point<input type="number" min={1} max={timeCount} value={last + 1} onChange={event => setLast(Number(event.target.value) - 1)} /></label>
          <label>Time-point step<input type="number" min={1} max={timeCount} value={step} onChange={event => setStep(Number(event.target.value))} /></label>
          <label>Maximum distance per frame<input type="number" min={.001} step="any" value={distance} onChange={event => setDistance(Number(event.target.value))} /></label>
          <label>Distance units<select value={units} onChange={event => setUnits(event.target.value as typeof units)}><option value="voxel">Voxel coordinates</option><option value="um">Micrometres</option></select></label>
          <label>Maximum missing frames<input type="number" min={0} max={10} value={gap} onChange={event => setGap(Number(event.target.value))} /></label>
        </div>
        <p>Distance allowance scales with elapsed frames. Physical distances require calibration; time points are not biological replicates.</p>
        <label>Drift handling<select value={drift} onChange={event => setDrift(event.target.value as typeof drift)}><option value="none">No drift correction</option><option value="phase-correlation">Estimate phase-correlation drift</option><option value="explicit">Explicit observed translations</option></select></label>
        {drift === "phase-correlation" ? <label>Maximum estimated shift (voxels)<input type="number" min={.001} step="any" value={maxShift} onChange={event => setMaxShift(Number(event.target.value))} /></label> : null}
        {drift === "explicit" ? <><p>Observed sample translation relative to the first selected frame, in X/Y/Z voxels. These offsets are subtracted before association; the first offset must be zero.</p>
          <table><thead><tr><th>Time point</th><th>X (voxels)</th><th>Y (voxels)</th><th>Z (voxels)</th></tr></thead><tbody>{times.slice(offsetPage * 20, (offsetPage + 1) * 20).map(time => <tr key={time}><th>{time + 1}</th>{(["x", "y", "z"] as const).map(axis => <td key={axis}><input aria-label={`Time ${time + 1} observed ${axis} translation`} type="number" step="any" value={offsets[time]?.[axis] ?? 0} onChange={event => setOffsets(previous => ({ ...previous, [time]: { ...(previous[time] ?? { x: 0, y: 0, z: 0 }), [axis]: Number(event.target.value) } }))} /></td>)}</tr>)}</tbody></table>
          <button className="cc-btn" disabled={offsetPage === 0} onClick={() => setOffsetPage(value => value - 1)}>Previous offsets</button><button className="cc-btn" disabled={(offsetPage + 1) * 20 >= times.length} onClick={() => setOffsetPage(value => value + 1)}>Next offsets</button></> : null}
        <label><input type="checkbox" checked={divisions} onChange={event => setDivisions(event.target.checked)} /> Infer candidate divisions</label>
        {divisions ? <div className="workbench-editor-grid">
          <label>Minimum combined daughter/parent volume ratio<input type="number" min={.001} step="any" value={minimumRatio} onChange={event => setMinimumRatio(Number(event.target.value))} /></label>
          <label>Maximum combined daughter/parent volume ratio<input type="number" min={.001} step="any" value={maximumRatio} onChange={event => setMaximumRatio(Number(event.target.value))} /></label>
          <label>Maximum daughter distance ({units === "um" ? "µm" : "voxels"})<input type="number" min={.001} step="any" value={daughterDistance} onChange={event => setDaughterDistance(Number(event.target.value))} /></label>
          <label>Division ambiguity margin<input type="number" min={0} max={10} step="any" value={ambiguity} onChange={event => setAmbiguity(Number(event.target.value))} /></label>
        </div> : null}
        <label><input type="checkbox" checked={replaceGraph} onChange={event => setReplaceGraph(event.target.checked)} /> Replace the current graph while retaining its history</label>
        <label>Reason / inference note<input value={reason} maxLength={4096} onChange={event => setReason(event.target.value)} /></label>
        <button className="cc-btn" disabled={times.length < 2 || times.length > 1000 || distance <= 0} onClick={() => void perform(async () => setTracking({ key: trackingKey, revision, value: await read<TemporalTrackingPreview>("temporal.track.preview", trackingArgs) }))}>Preview temporal inference</button>
        {tracking && !currentTracking ? <p>Settings or saved inputs changed. Preview again before saving this graph.</p> : null}
        {currentTracking ? <><p>{currentTracking.counts.observations} observations · {currentTracking.counts.continuations} continuations · {currentTracking.counts.gaps} gap links · {currentTracking.counts.inferredDivisions} inferred divisions · {currentTracking.counts.ambiguousDivisions} ambiguous division candidates.</p>
          {currentTracking.replacesGraph ? <p>Saving replaces the current graph; previous graph history remains available.</p> : null}
          <details><summary>Preview links and drift estimates</summary><table><thead><tr><th>Source observation</th><th>Target observation</th><th>Link</th></tr></thead><tbody>{currentTracking.graph.edges.slice(0, 200).map((edge, index) => {
            const source = trackingNodes.get(edge.sourceNodeId); const destination = trackingNodes.get(edge.targetNodeId);
            return <tr key={index}><td>T{source ? source.timeIndex + 1 : "?"} · object {source?.labelId ?? "?"}</td><td>T{destination ? destination.timeIndex + 1 : "?"} · object {destination?.labelId ?? "?"}</td><td>{edge.kind === "division" ? "Inferred division" : "Continuation"}</td></tr>;
          })}</tbody></table>{currentTracking.graph.edges.length > 200 ? <p>First 200 links shown. The saved graph and export retain every link.</p> : null}
            <ScientificOutput output={currentTracking.drift} />{currentTracking.ambiguities.length ? <ScientificOutput output={{ ambiguousDivisionCandidates: currentTracking.ambiguities }} /> : null}</details>
          <button className="cc-btn" disabled={currentTracking.replacesGraph && !replaceGraph} onClick={() => void act("temporal.track.run", { ...trackingArgs, previewFingerprint: currentTracking.previewFingerprint })}>Save inferred graph</button>
        </> : null}
      </fieldset>
    </details>
    <details><summary>Propagate an exact object correction</summary>
      <p>Translate the selected source object's exact mask into explicit target frames. This does not resegment targets. Collisions, replacement and clipping require explicit choices.</p>
      {error ? <p className="workbench-error" role="alert">{error}</p> : null}
      <fieldset disabled={busy || timeCount < 2}>
        <legend>Source object and target decisions</legend>
        <div className="workbench-editor-grid"><label>Source time point<input type="number" min={1} max={timeCount} value={sourceTime + 1} onChange={event => setSourceTime(Number(event.target.value) - 1)} /></label>
          <label>Source object label<input type="number" min={1} step={1} value={sourceLabel} onChange={event => setSourceLabel(Number(event.target.value))} /></label>
          <label>Motion<select value={motion} onChange={event => setMotion(event.target.value as typeof motion)}><option value="lineage-centroid">Current lineage centroid displacement</option><option value="drift">Saved drift displacement</option><option value="explicit">Explicit X/Y/Z translation</option></select></label></div>
        <p>A blank target label resolves only along a unique consecutive continuation. Gaps and divisions require an explicit target label.</p>
        {targets.map((value, index) => <fieldset key={value.key}>
          <legend>Target {index + 1}</legend><div className="workbench-editor-grid">
            <label>Target time point<input type="number" min={1} max={timeCount} value={value.timeIndex + 1} onChange={event => editTarget(value.key, { timeIndex: Number(event.target.value) - 1 })} /></label>
            <label>Target label (blank = unique continuation)<input type="number" min={1} step={1} value={value.labelId} onChange={event => editTarget(value.key, { labelId: event.target.value })} /></label>
            {motion === "explicit" ? (["x", "y", "z"] as const).map(axis => <label key={axis}>{axis.toUpperCase()} translation (voxels)<input type="number" step="any" value={value[axis]} onChange={event => editTarget(value.key, { [axis]: Number(event.target.value) })} /></label>) : null}
            <label>Explicit labels to replace (comma separated)<input value={value.replacements} onChange={event => editTarget(value.key, { replacements: event.target.value })} placeholder="e.g. 14, 22" /></label>
          </div>
          <label><input type="checkbox" checked={value.allowClipping} onChange={event => editTarget(value.key, { allowClipping: event.target.checked })} /> Allow explicitly reported clipping at the valid source boundary</label>
          <label><input type="checkbox" checked={value.skip} onChange={event => editTarget(value.key, { skip: event.target.checked })} /> Skip this target and retain that decision in the correction record</label>
          <button className="cc-btn" onClick={() => setTargets(previous => previous.filter(item => item.key !== value.key))}>Remove target</button>
        </fieldset>)}
        <button className="cc-btn" disabled={targets.length >= 32} onClick={() => setTargets(previous => [...previous, target(Math.min(timeCount - 1, (previous.at(-1)?.timeIndex ?? sourceTime) + 1))])}>Add target frame</button>
        <label>Target slice preview<select value={visualTime ?? ""} onChange={event => setVisualTime(event.target.value === "" ? undefined : Number(event.target.value))}><option value="">First non-skipped target</option>{targets.filter(value => !value.skip).map(value => <option key={value.key} value={value.timeIndex}>Time {value.timeIndex + 1}</option>)}</select></label>
        <label>Reason for grouped correction<input value={propagationReason} maxLength={4096} onChange={event => setPropagationReason(event.target.value)} /></label>
        {!validTargets ? <p>Choose distinct, in-bounds target frames different from the source. Explicit motion requires a positive target label.</p> : null}
        <button className="cc-btn" disabled={!validTargets || !propagationReason.trim()} onClick={() => void perform(async () => setPropagation({ key: propagationKey, revision, value: await read<PropagationPreview>("temporal.propagate.preview", { ...propagationArgs, ...(visualTime != null ? { previewTimeIndex: visualTime } : {}), maxSize: 768 }) }))}>Preview target masks and conflicts</button>
        {propagation && !currentPropagation ? <p>Inputs or correction choices changed. Preview again before applying.</p> : null}
        {currentPropagation ? <><p>{currentPropagation.readyCount} ready targets · {currentPropagation.blockedCount} blocked targets.</p>
          <table><thead><tr><th>Time / label</th><th>Status</th><th>Placed voxels</th><th>Clipped voxels</th><th>Collisions / replacements</th></tr></thead><tbody>{currentPropagation.targets.map(item => <tr key={item.timeIndex}><td>T{item.timeIndex + 1} · {item.labelId ?? "unresolved"}</td><td>{item.status}</td><td>{fmt(item.placedVoxels)}</td><td>{fmt(item.clippedVoxels)}</td><td>Collisions: {item.collisionLabelIds?.join(", ") || "none"}; replace: {item.replacedLabelIds?.join(", ") || "none"}</td></tr>)}</tbody></table>
          {currentPropagation.targets.map(item => <div key={item.timeIndex}>{item.reasons.map(reason => <p className="workbench-error" key={reason.code}>Time {item.timeIndex + 1}: {reason.message}</p>)}{item.warnings.map((warning, index) => <p key={index}>{String(warning)}</p>)}
            {item.overlayDataUrl ? <><img src={item.overlayDataUrl} alt={`Preview of proposed object correction at time ${item.timeIndex + 1}`} style={{ maxWidth: "100%", maxHeight: 420, objectFit: "contain" }} /><p>Target time {item.timeIndex + 1}; XY slice {(item.previewIndex ?? 0) + 1}. Collision counts use full-resolution labels.</p></> : null}</div>)}
          <button className="cc-btn" disabled={currentPropagation.blockedCount > 0 || currentPropagation.readyCount === 0} onClick={() => void act("temporal.propagate.run", { ...propagationArgs, previewFingerprint: currentPropagation.previewFingerprint })}>Apply reviewed correction group</button>
          <p>Every non-skipped target must be ready. Applying changes target measurements and makes previous tracking historical until refreshed.</p>
        </> : null}
      </fieldset>
      <details><summary>Saved correction groups and undo</summary>
        <button className="cc-btn" disabled={busy} onClick={() => void perform(loadHistory)}>Read correction history</button>
        <label>Undo reason<input value={undoReason} maxLength={4096} disabled={busy} onChange={event => setUndoReason(event.target.value)} /></label>
        {history ? <><p>History read at project revision {history.revision}{history.revision === revision ? "" : "; refresh before undo"}.</p><ul>{history.values.map(value => <li key={value.id}>
          <strong>{value.status} · source T{value.source.timeIndex + 1} label {value.source.labelId}</strong><p>{value.appliedCount} applied; {value.skippedCount} skipped · {value.reason}</p>
          <p>{value.outputsCurrent ? "Retained outputs still match current frames." : "Later input or target changes prevent undo."}</p>
          <button className="cc-btn" disabled={busy || !value.undoAvailable || history.revision !== revision || !undoReason.trim()} onClick={() => void act("temporal.propagate.undo", { imageId, propagationId: value.id, reason: undoReason.trim() })}>Undo whole correction group</button>
        </li>)}</ul></> : null}
      </details>
    </details>
  </section>;
}
