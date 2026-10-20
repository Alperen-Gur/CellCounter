import { useState } from "react";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import type { AcquisitionSession, ExperimentApplication, ExperimentApplicationPlan, ExperimentExclusion, ExperimentLayout, ExperimentLayoutDefinition, ExperimentRecordActions } from "../../../../shared/workbench/experimentProtocol";
import ExperimentFactorEditor, { factorDefinitions, factorDrafts, factorLevels, invalidFactors, type FactorDraft } from "./ExperimentFactorEditor";
import WorkbenchImageSelector from "./WorkbenchImageSelector";
import ScientificOutput from "./ScientificOutput";
import { useCatalogueMany, useCataloguePins } from "./WorkbenchCatalogueBrowser";

type Props = { snapshot: ProjectSnapshot; busy: boolean; writeBlocked: boolean; actions: ExperimentRecordActions;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T> };
type SlotDraft = { key: string; name: string; condition: string; role: "control" | "treatment" | "other";
  values: Record<string, string>; subjectKey: string; blockKey: string; wellRow: string; wellColumn: string };
const slotId = () => `slot_${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}`;
const pageSize = 20;
const validTime = (value: string) => !value.trim() || /(?:Z|[+-]\d{2}:\d{2})$/i.test(value.trim()) && Number.isFinite(Date.parse(value.trim()));

function ApplicationPlan({ plan }: { plan: ExperimentApplicationPlan }) {
  const [page, setPage] = useState(0);
  const [assignmentPage, setAssignmentPage] = useState(0);
  const [assignmentKind, setAssignmentKind] = useState<"new" | "replaced">("new");
  const assignmentRows = assignmentKind === "new" ? plan.assignments : plan.replacedAssignments;
  return <><p>{plan.newSpecimens.length} new biological specimens · {plan.assignments.length} image assignments · {plan.replacedAssignments.length} existing assignments replaced{plan.newPlate ? ` · new plate ${plan.newPlate.name}` : ""}.</p>
    <div className="workbench-table"><table><thead><tr><th>New specimen</th><th>Condition / role</th><th>Image fields</th><th>Subject / block</th></tr></thead><tbody>
      {plan.newSpecimens.slice(page * pageSize, (page + 1) * pageSize).map(specimen => { const row = plan.statisticsRows.find(value => value.specimenId === specimen.id); return <tr key={specimen.id}><th>{specimen.name}</th><td>{specimen.condition} · {specimen.role}</td><td>{plan.assignments.filter(value => value.specimenId === specimen.id).length}</td><td>{row?.subjectId ?? "—"} / {row?.blockId ?? "—"}</td></tr>; })}
    </tbody></table></div><div className="workbench-actions"><button className="cc-btn" disabled={!page} onClick={() => setPage(value => value - 1)}>Previous specimens</button><button className="cc-btn" disabled={(page + 1) * pageSize >= plan.newSpecimens.length} onClick={() => setPage(value => value + 1)}>Next specimens</button></div>
    <details><summary>Identity mapping and reassignment details</summary><ScientificOutput output={{ subjectMapping: plan.subjectMapping, blockMapping: plan.blockMapping, notes: plan.notes }} />
      <label>Assignment records<select value={assignmentKind} onChange={event => { setAssignmentKind(event.target.value as typeof assignmentKind); setAssignmentPage(0); }}><option value="new">New assignments</option><option value="replaced">Previous assignments being replaced</option></select></label>
      <p>{assignmentRows.length} assignment records. Source identities and every assignment remain retained in the application record.</p>
      <div className="workbench-table"><table><thead><tr><th>Image</th><th>Specimen</th><th>Plate / well</th><th>Field</th></tr></thead><tbody>{assignmentRows.slice(assignmentPage * 50, (assignmentPage + 1) * 50).map(row => <tr key={row.imageId}><th>{row.imageId}</th><td>{row.specimenId}</td><td>{row.plateId ? `${row.plateId} · ${row.wellRow ?? "—"}, ${row.wellColumn ?? "—"}` : "—"}</td><td>{row.field ?? "—"}</td></tr>)}</tbody></table></div>
      <div className="workbench-actions"><button className="cc-btn" disabled={!assignmentPage} onClick={() => setAssignmentPage(value => value - 1)}>Previous assignments</button><button className="cc-btn" disabled={(assignmentPage + 1) * 50 >= assignmentRows.length} onClick={() => setAssignmentPage(value => value + 1)}>Next assignments</button></div></details></>;
}

export default function WorkbenchExperimentRecords({ snapshot, busy, writeBlocked, actions, read }: Props) {
  const revision = snapshot.project.revision;
  const layouts = snapshot.experimentLayouts ?? [], sessions = snapshot.acquisitionSessions ?? [], applications = snapshot.experimentApplications ?? [];
  const [error, setError] = useState("");
  const [layoutId, setLayoutId] = useState("");
  const [version, setVersion] = useState(1);
  const [loaded, setLoaded] = useState<ExperimentLayout>();
  const [origin, setOrigin] = useState<string>();
  const [name, setName] = useState("Reusable experiment layout");
  const [notes, setNotes] = useState("");
  const [factors, setFactors] = useState<FactorDraft[]>([{ id: "condition", name: "Condition", kind: "categorical", levelsText: "Control\nTreatment", referenceLevel: "Control" }]);
  const [slots, setSlots] = useState<SlotDraft[]>([]);
  const [slotPage, setSlotPage] = useState(0);
  const [hasPlate, setHasPlate] = useState(false);
  const [plateRows, setPlateRows] = useState(8), [plateColumns, setPlateColumns] = useState(12);
  const [instanceName, setInstanceName] = useState("");
  const [experiment, setExperiment] = useState("");
  const [plateName, setPlateName] = useState("");
  const [bindings, setBindings] = useState<Record<string, { imageIds: string[]; field: string }>>({});
  const [subjectMapping, setSubjectMapping] = useState<Record<string, string>>({}), [blockMapping, setBlockMapping] = useState<Record<string, string>>({});
  const [replaceAssignments, setReplaceAssignments] = useState(false);
  const [bindingPage, setBindingPage] = useState(0);
  const [preview, setPreview] = useState<{ revision: number; key: string; plan: ExperimentApplicationPlan; fingerprint: string }>();
  const [applicationId, setApplicationId] = useState("");
  const [retainedApplication, setRetainedApplication] = useState<ExperimentApplication>();
  const [sessionId, setSessionId] = useState(""), [sessionVersion, setSessionVersion] = useState(1);
  const [sessionOrigin, setSessionOrigin] = useState<string>();
  const [sessionName, setSessionName] = useState(""), [instrument, setInstrument] = useState(""), [operator, setOperator] = useState("");
  const [startedAt, setStartedAt] = useState(""), [endedAt, setEndedAt] = useState(""), [sessionNotes, setSessionNotes] = useState("");
  const [sessionImages, setSessionImages] = useState<string[]>([]);
  const [sessionRecord, setSessionRecord] = useState<AcquisitionSession>();
  const [exclusionTarget, setExclusionTarget] = useState<"image" | "specimen">("specimen"), [exclusionId, setExclusionId] = useState("");
  const [exclusionReason, setExclusionReason] = useState("");
  const [exclusionHistory, setExclusionHistory] = useState<{ revision: number; rows: ExperimentExclusion[] }>();
  const [historyPage, setHistoryPage] = useState(0);
  const pinError = useCataloguePins([{ catalogue: "experimentLayouts", entryId: layoutId },
    { catalogue: "experimentApplications", entryId: applicationId }, { catalogue: "acquisitionSessions", entryId: sessionId },
    { catalogue: "specimens", entryId: exclusionTarget === "specimen" ? exclusionId : "" }]);
  const exclusions = useCatalogueMany<ExperimentExclusion>("experimentExclusions", exclusionId ? [`${exclusionTarget}:${exclusionId}`] : []);
  const perform = (action: () => Promise<void>) => actions.run(async () => { setError(""); try { await action(); } catch (cause) { setError(String(cause)); } });
  const editSlot = (key: string, changes: Partial<SlotDraft>) => setSlots(old => old.map(slot => slot.key === key ? { ...slot, ...changes } : slot));
  const selectedLayout = layouts.find(value => value.id === layoutId);
  const saved = loaded?.id === layoutId && loaded.version === version ? loaded : undefined;
  const definition: ExperimentLayoutDefinition = { name: name.trim(), factors: factorDefinitions(factors), notes: notes.trim(),
    ...(hasPlate ? { plate: { rows: plateRows, columns: plateColumns } } : {}),
    slots: slots.map(slot => ({ key: slot.key, name: slot.name.trim(), condition: slot.condition.trim(), role: slot.role,
      values: Object.fromEntries(factors.map(factor => [factor.id, factor.kind === "numeric" ? Number(slot.values[factor.id]) : slot.values[factor.id] ?? ""])),
      ...(slot.subjectKey.trim() ? { subjectKey: slot.subjectKey.trim() } : {}), ...(slot.blockKey.trim() ? { blockKey: slot.blockKey.trim() } : {}),
      ...(hasPlate && (slot.wellRow || slot.wellColumn) ? { wellRow: Number(slot.wellRow), wellColumn: Number(slot.wellColumn) } : {}) })) };
  const invalidLayout = !name.trim() || invalidFactors(factors) || slots.length === 0 || new Set(slots.map(slot => slot.name.trim().toLocaleLowerCase())).size !== slots.length ||
    hasPlate && (!Number.isInteger(plateRows) || !Number.isInteger(plateColumns) || plateRows < 1 || plateRows > 100 || plateColumns < 1 || plateColumns > 100) ||
    slots.some(slot => !slot.name.trim() || !slot.condition.trim() || factors.some(factor => factor.kind === "numeric" ? !slot.values[factor.id]?.trim() || !Number.isFinite(Number(slot.values[factor.id])) : !factorLevels(factor).includes(slot.values[factor.id])) ||
      hasPlate && (slot.wellRow || slot.wellColumn) && (!Number.isInteger(Number(slot.wellRow)) || !Number.isInteger(Number(slot.wellColumn)) || Number(slot.wellRow) < 1 || Number(slot.wellColumn) < 1 || Number(slot.wellRow) > plateRows || Number(slot.wellColumn) > plateColumns));
  const applyArgs = { layoutId, version, instanceName: instanceName.trim(), experiment: experiment.trim(),
    ...(saved?.definition.plate && plateName.trim() ? { plateName: plateName.trim() } : {}),
    bindings: (saved?.definition.slots ?? []).flatMap(slot => bindings[slot.key]?.imageIds.length ? [{ slotKey: slot.key, imageIds: bindings[slot.key].imageIds, ...(bindings[slot.key].field.trim() ? { field: bindings[slot.key].field.trim() } : {}) }] : []),
    subjectMapping: Object.entries(subjectMapping).filter(([, id]) => id.trim()).map(([key, id]) => ({ key, id: id.trim() })),
    blockMapping: Object.entries(blockMapping).filter(([, id]) => id.trim()).map(([key, id]) => ({ key, id: id.trim() })), replaceAssignments };
  const applyKey = JSON.stringify(applyArgs);
  const currentPreview = preview?.revision === revision && preview.key === applyKey ? preview : undefined;
  const selectedSession = sessions.find(value => value.id === sessionId);
  const invalidSession = !sessionName.trim() || !instrument.trim() || !validTime(startedAt) || !validTime(endedAt) || !!endedAt.trim() && (!startedAt.trim() || Date.parse(endedAt) < Date.parse(startedAt));
  const effectiveExclusion = exclusions.entries.find(item => item.excluded);
  const loadLayout = (record: ExperimentLayout) => {
    setLoaded(record); setLayoutId(record.id); setVersion(record.version); setOrigin(record.id); setName(record.name); setNotes(record.definition.notes ?? "");
    setFactors(factorDrafts(record.definition.factors)); setSlots(record.definition.slots.map(slot => ({ ...slot, values: Object.fromEntries(Object.entries(slot.values).map(([key, value]) => [key, String(value)])),
      subjectKey: slot.subjectKey ?? "", blockKey: slot.blockKey ?? "", wellRow: slot.wellRow == null ? "" : String(slot.wellRow), wellColumn: slot.wellColumn == null ? "" : String(slot.wellColumn) })));
    setHasPlate(!!record.definition.plate); setPlateRows(record.definition.plate?.rows ?? 8); setPlateColumns(record.definition.plate?.columns ?? 12);
    setBindings({}); setSubjectMapping({}); setBlockMapping({}); setPreview(undefined); setSlotPage(0); setBindingPage(0);
  };
  const loadSession = (record: AcquisitionSession) => { setSessionRecord(record); setSessionId(record.id); setSessionVersion(record.version); setSessionOrigin(record.id);
    setSessionName(record.name); setInstrument(record.instrument); setOperator(record.operator ?? ""); setStartedAt(record.startedAt ?? ""); setEndedAt(record.endedAt ?? ""); setSessionNotes(record.notes ?? ""); setSessionImages(record.members.map(value => value.imageId)); };
  const saveLayout = (asVersion: boolean) => actions.mutate<{ layout: ExperimentLayout }>("experiment.layout.save", { ...definition, ...(asVersion && origin ? { layoutId: origin } : {}) }, result => loadLayout(result.layout));
  const saveSession = (asVersion: boolean) => actions.mutate<{ session: AcquisitionSession }>("acquisition.session.save", {
    name: sessionName.trim(), instrument: instrument.trim(), imageIds: sessionImages, notes: sessionNotes.trim(),
    ...(operator.trim() ? { operator: operator.trim() } : {}), ...(startedAt.trim() ? { startedAt: startedAt.trim() } : {}), ...(endedAt.trim() ? { endedAt: endedAt.trim() } : {}), ...(asVersion && sessionOrigin ? { sessionId: sessionOrigin } : {}),
  }, result => loadSession(result.session));

  return <><h3>Reusable designs and acquisition records</h3>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {writeBlocked ? <p>Save or discard scientific edits and stop conflicting workers before saving experiment records.</p> : null}
    <details><summary>Reusable experiment layouts</summary>
      <p>Each slot represents one biological specimen across its image fields. Applying a layout creates new specimens; alternate masks and repeat fields do not increase biological n.</p>
      <fieldset disabled={busy}><legend>Saved layout versions</legend>
        <label>Layout<select value={layoutId} onChange={event => { const value = layouts.find(item => item.id === event.target.value); setLayoutId(event.target.value); setVersion(value?.version ?? 1); }}><option value="">Choose a saved layout</option>{layouts.map(value => <option key={value.id} value={value.id}>{value.name} · v{value.version} · {value.slotCount} slots</option>)}</select></label>
        <label>Saved version<input type="number" min={1} max={selectedLayout?.latestVersion ?? 1} step={1} value={version} onChange={event => setVersion(Number(event.target.value))} /></label>
        <button className="cc-btn" disabled={!selectedLayout || version < 1 || version > selectedLayout.latestVersion} onClick={() => void perform(async () => loadLayout((await read<{ layout: ExperimentLayout }>("experiment.layout.get", { layoutId, version })).layout))}>Load layout into editor</button>
        <p>Loading replaces the layout draft and its pending image bindings. Existing saved versions and applications remain unchanged.</p>
      </fieldset>
      <details><summary>Define layout slots and factors</summary><fieldset disabled={busy}><legend>Layout definition</legend>
        <label>Layout name<input value={name} maxLength={200} onChange={event => setName(event.target.value)} /></label>
        <ExperimentFactorEditor factors={factors} onChange={setFactors} />
        <label><input type="checkbox" checked={hasPlate} onChange={event => setHasPlate(event.target.checked)} /> Include a plate</label>
        {hasPlate ? <div className="workbench-editor-grid"><label>Plate rows<input type="number" min={1} max={100} step={1} value={plateRows} onChange={event => setPlateRows(Number(event.target.value))} /></label><label>Plate columns<input type="number" min={1} max={100} step={1} value={plateColumns} onChange={event => setPlateColumns(Number(event.target.value))} /></label></div> : null}
        <p>{slots.length} specimen slots. Subject and block keys group slots within an application; identities are created when the layout is applied.</p>
        {slots.slice(slotPage * pageSize, (slotPage + 1) * pageSize).map(slot => <fieldset key={slot.key}><legend>{slot.name || "New specimen slot"}</legend><div className="workbench-editor-grid">
          <label>Specimen slot name<input value={slot.name} maxLength={200} onChange={event => editSlot(slot.key, { name: event.target.value })} /></label>
          <label>Condition<input value={slot.condition} maxLength={200} onChange={event => editSlot(slot.key, { condition: event.target.value })} /></label>
          <label>Condition role<select value={slot.role} onChange={event => editSlot(slot.key, { role: event.target.value as SlotDraft["role"] })}><option value="control">Control</option><option value="treatment">Treatment</option><option value="other">Other</option></select></label>
          {factors.map(factor => <label key={factor.id}>{factor.name}{factor.kind === "numeric" && factor.unit ? ` (${factor.unit})` : ""}{factor.kind === "categorical" ? <select value={slot.values[factor.id] ?? ""} onChange={event => editSlot(slot.key, { values: { ...slot.values, [factor.id]: event.target.value } })}><option value="">Choose level</option>{[...new Set(factorLevels(factor))].map(value => <option key={value} value={value}>{value}</option>)}</select> : <input type="number" step="any" value={slot.values[factor.id] ?? ""} onChange={event => editSlot(slot.key, { values: { ...slot.values, [factor.id]: event.target.value } })} />}</label>)}
          <label>Subject key (optional)<input value={slot.subjectKey} maxLength={200} onChange={event => editSlot(slot.key, { subjectKey: event.target.value })} /></label>
          <label>Block key (optional)<input value={slot.blockKey} maxLength={200} onChange={event => editSlot(slot.key, { blockKey: event.target.value })} /></label>
          {hasPlate ? <><label>Well row (optional, starting at 1)<input type="number" min={1} max={plateRows} step={1} value={slot.wellRow} onChange={event => editSlot(slot.key, { wellRow: event.target.value })} /></label><label>Well column (optional, starting at 1)<input type="number" min={1} max={plateColumns} step={1} value={slot.wellColumn} onChange={event => editSlot(slot.key, { wellColumn: event.target.value })} /></label></> : null}
        </div><div className="workbench-actions"><button className="cc-btn" disabled={slots.length >= 1000} onClick={() => { setSlots(old => [...old, { ...slot, key: slotId(), name: `${slot.name} copy`.slice(0, 200), values: { ...slot.values }, wellRow: "", wellColumn: "" }]); setSlotPage(Math.floor(slots.length / pageSize)); }}>Duplicate slot</button>
          <button className="cc-btn" onClick={() => { setSlots(old => old.filter(value => value.key !== slot.key)); setSlotPage(Math.min(slotPage, Math.max(0, Math.ceil((slots.length - 1) / pageSize) - 1))); }}>Remove slot</button></div></fieldset>)}
        <div className="workbench-actions"><button className="cc-btn" disabled={!slotPage} onClick={() => setSlotPage(value => value - 1)}>Previous slots</button><button className="cc-btn" disabled={(slotPage + 1) * pageSize >= slots.length} onClick={() => setSlotPage(value => value + 1)}>Next slots</button>
          <button className="cc-btn" disabled={slots.length >= 1000} onClick={() => { setSlots(old => [...old, { key: slotId(), name: `Specimen ${old.length + 1}`, condition: "", role: "other", values: {}, subjectKey: "", blockKey: "", wellRow: "", wellColumn: "" }]); setSlotPage(Math.floor(slots.length / pageSize)); }}>Add specimen slot</button></div>
        <label>Layout notes<textarea value={notes} maxLength={4000} rows={3} onChange={event => setNotes(event.target.value)} /></label>
        {invalidLayout ? <p>Complete the layout name, factors, distinct slot names, conditions and all factor values. Plate wells require both row and column.</p> : null}
        <div className="workbench-actions"><button className="cc-btn" disabled={writeBlocked || !!invalidLayout} onClick={() => void saveLayout(false)}>Save as new layout</button><button className="cc-btn" disabled={writeBlocked || !!invalidLayout || !origin} onClick={() => void saveLayout(true)}>Save layout version</button></div>
      </fieldset></details>
      <details><summary>Apply a saved layout</summary>{!saved ? <p>Explicitly load a saved layout version above to bind images. Unsaved layout changes are not applied.</p> : <>
        <p>{saved.name} · saved version {saved.version}. This application uses the saved definition.</p>
        <fieldset disabled={busy}><legend>New experiment instance</legend><div className="workbench-editor-grid"><label>Instance name<input value={instanceName} maxLength={200} onChange={event => setInstanceName(event.target.value)} /></label><label>Experiment<input value={experiment} maxLength={200} onChange={event => setExperiment(event.target.value)} /></label>{saved.definition.plate ? <label>New plate name (optional)<input value={plateName} maxLength={200} onChange={event => setPlateName(event.target.value)} /></label> : null}</div>
          {saved.definition.slots.slice(bindingPage * pageSize, (bindingPage + 1) * pageSize).map(slot => <fieldset key={slot.key}><legend>{slot.name} · {slot.condition}</legend>
            <WorkbenchImageSelector label={`Image fields for ${slot.name}`} multiple selectedIds={bindings[slot.key]?.imageIds ?? []} disabled={busy}
              onChange={imageIds => setBindings(old => ({ ...old, [slot.key]: { imageIds, field: old[slot.key]?.field ?? "" } }))} />
            <label>Field label (optional, applies to these images)<input value={bindings[slot.key]?.field ?? ""} maxLength={200} onChange={event => setBindings(old => ({ ...old, [slot.key]: { imageIds: old[slot.key]?.imageIds ?? [], field: event.target.value } }))} /></label>
          </fieldset>)}
          <div className="workbench-actions"><button className="cc-btn" disabled={!bindingPage} onClick={() => setBindingPage(value => value - 1)}>Previous image bindings</button><button className="cc-btn" disabled={(bindingPage + 1) * pageSize >= saved.definition.slots.length} onClick={() => setBindingPage(value => value + 1)}>Next image bindings</button></div>
          <p>Unbound slots create specimen drafts without images. Every image can belong to only one slot in this application.</p>
          <details><summary>Reuse subject or block identities</summary><p>Blank fields create new identities. Enter an existing exact ID only when it represents the same subject or block.</p>
            {(["subjectKey", "blockKey"] as const).map(kind => <fieldset key={kind}><legend>{kind === "subjectKey" ? "Subject mapping" : "Block mapping"}</legend>{[...new Set(saved.definition.slots.map(slot => slot[kind]).filter((value): value is string => !!value))].map(key => <label key={key}>{key} · existing ID (optional)<input value={(kind === "subjectKey" ? subjectMapping : blockMapping)[key] ?? ""} maxLength={200} onChange={event => (kind === "subjectKey" ? setSubjectMapping : setBlockMapping)(old => ({ ...old, [key]: event.target.value }))} /></label>)}</fieldset>)}
          </details>
          <label><input type="checkbox" checked={replaceAssignments} onChange={event => setReplaceAssignments(event.target.checked)} /> Explicitly replace assignments for bound images</label>
          <button className="cc-btn" disabled={!instanceName.trim() || !experiment.trim()} onClick={() => void perform(async () => { const result = await read<{ plan: ExperimentApplicationPlan; previewFingerprint: string }>("experiment.layout.apply.preview", applyArgs); setPreview({ revision, key: applyKey, plan: result.plan, fingerprint: result.previewFingerprint }); })}>Preview new specimens and assignments</button>
        </fieldset>
        {preview && !currentPreview ? <p>The application draft or project changed. Preview again before applying.</p> : null}
        {currentPreview ? <><ApplicationPlan key={currentPreview.fingerprint} plan={currentPreview.plan} /><button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void actions.mutate<{ application: ExperimentApplication }>("experiment.layout.apply.run", { ...applyArgs, previewFingerprint: currentPreview.fingerprint }, result => { setRetainedApplication(result.application); setApplicationId(result.application.id); setPreview(undefined); })}>Apply previewed layout</button></> : null}
      </>}</details>
      <details><summary>Retained layout applications</summary><fieldset disabled={busy}><label>Application<select value={applicationId} onChange={event => setApplicationId(event.target.value)}><option value="">Choose an application</option>{applications.map(value => <option key={value.id} value={value.id}>{value.experiment} · {value.instanceName} · {value.specimenCount} specimens</option>)}</select></label>
        <button className="cc-btn" disabled={!applicationId} onClick={() => void perform(async () => setRetainedApplication((await read<{ application: ExperimentApplication }>("experiment.layout.application.get", { applicationId })).application))}>Read application record</button></fieldset>
        {retainedApplication?.id === applicationId ? <ApplicationPlan key={retainedApplication.hash} plan={retainedApplication} /> : null}<p>In Measurements → Biological-replicate statistics, use this application to populate the existing design editor with its factors and subject/block rows.</p>
      </details>
    </details>
    <details><summary>Acquisition sessions</summary><p>Record instrument, operator, observed times and exact image membership. Sessions do not create biological replicates or infer timing from file imports.</p>
      <fieldset disabled={busy}><legend>Saved session versions</legend><label>Session<select value={sessionId} onChange={event => { const value = sessions.find(item => item.id === event.target.value); setSessionId(event.target.value); setSessionVersion(value?.version ?? 1); }}><option value="">Choose a session</option>{sessions.map(value => <option key={value.id} value={value.id}>{value.name} · v{value.version} · {value.imageCount} images</option>)}</select></label>
        <label>Saved version<input type="number" min={1} max={selectedSession?.latestVersion ?? 1} step={1} value={sessionVersion} onChange={event => setSessionVersion(Number(event.target.value))} /></label><button className="cc-btn" disabled={!selectedSession || sessionVersion < 1 || sessionVersion > selectedSession.latestVersion} onClick={() => void perform(async () => loadSession((await read<{ session: AcquisitionSession }>("acquisition.session.get", { sessionId, version: sessionVersion })).session))}>Load session into editor</button><p>Loading replaces this session draft; saved versions remain unchanged.</p></fieldset>
      <fieldset disabled={busy}><legend>Acquisition metadata</legend><div className="workbench-editor-grid"><label>Session name<input value={sessionName} maxLength={200} onChange={event => setSessionName(event.target.value)} /></label><label>Instrument<input value={instrument} maxLength={200} onChange={event => setInstrument(event.target.value)} /></label><label>Operator (optional)<input value={operator} maxLength={200} onChange={event => setOperator(event.target.value)} /></label>
        <label>Observed start (ISO 8601 with timezone, optional)<input placeholder="2026-10-21T09:30:00+03:00" value={startedAt} maxLength={200} onChange={event => setStartedAt(event.target.value)} /></label><label>Observed end (ISO 8601 with timezone, optional)<input placeholder="2026-10-21T10:30:00+03:00" value={endedAt} maxLength={200} onChange={event => setEndedAt(event.target.value)} /></label></div>
        <WorkbenchImageSelector label="Acquisition session images" multiple selectedIds={sessionImages} onChange={setSessionImages} disabled={busy} />
        <label>Session notes<textarea value={sessionNotes} maxLength={4000} rows={3} onChange={event => setSessionNotes(event.target.value)} /></label>
        {invalidSession ? <p>Supply a name and instrument. Optional times need an explicit timezone; the end cannot precede the start.</p> : null}<div className="workbench-actions"><button className="cc-btn" disabled={writeBlocked || invalidSession} onClick={() => void saveSession(false)}>Save as new session</button><button className="cc-btn" disabled={writeBlocked || invalidSession || !sessionOrigin} onClick={() => void saveSession(true)}>Save session version</button></div>
      </fieldset>{sessionRecord ? <details><summary>Retained session source identity</summary><p>{sessionRecord.name} · version {sessionRecord.version} · {sessionRecord.members.length} immutable source references</p><code>{sessionRecord.hash}</code></details> : null}
    </details>
    <details><summary>Reasoned specimen and image exclusions</summary><p>Exclusions affect current experiment summaries and statistical inputs. They are independent of archive visibility; saved reports retain their historical inputs.</p>
      <fieldset disabled={busy}><legend>Exclusion decision</legend><label>Target type<select value={exclusionTarget} onChange={event => { setExclusionTarget(event.target.value as typeof exclusionTarget); setExclusionId(""); setExclusionReason(""); }}><option value="specimen">Biological specimen</option><option value="image">Image field</option></select></label>
        {exclusionTarget === "specimen" ? <label>Specimen<select value={exclusionId} onChange={event => setExclusionId(event.target.value)}><option value="">Choose a specimen</option>{snapshot.experimentalDesign?.specimens.map(value => <option key={value.id} value={value.id}>{value.experiment} · {value.name}</option>)}</select></label> : <WorkbenchImageSelector label="Image field to exclude or restore" selectedIds={exclusionId ? [exclusionId] : []} onChange={ids => setExclusionId(ids[0] ?? "")} disabled={busy} filters={{ archiveScope: "all" }} />}
        {pinError || exclusions.error ? <p className="workbench-error" role="alert">{pinError || exclusions.error}</p> : null}
        {exclusionId ? <p>{!exclusions.ready ? "Reading the exact exclusion state…" : effectiveExclusion ? `Currently excluded: ${effectiveExclusion.reason}` : "No active exclusion for this target."}</p> : null}
        <label>Reason for this decision<textarea value={exclusionReason} maxLength={2000} rows={3} onChange={event => setExclusionReason(event.target.value)} /></label>
        <div className="workbench-actions">{([true, false] as const).map(excluded => <button key={String(excluded)} className="cc-btn" disabled={writeBlocked || !exclusions.ready || !!exclusions.error || !exclusionId || !exclusionReason.trim() || excluded === !!effectiveExclusion} onClick={() => void actions.mutate("experiment.exclusion.set", { target: exclusionTarget, targetId: exclusionId, excluded, reason: exclusionReason.trim() }, () => { setExclusionReason(""); setExclusionHistory(undefined); })}>{excluded ? "Exclude with reason" : "Restore inclusion with reason"}</button>)}</div>
      </fieldset><p>History uses the compatibility endpoint and loads retained decisions together; current exclusions above are resolved separately for the selected target.</p><button className="cc-btn" disabled={busy} onClick={() => void perform(async () => { const result = await read<{ history: ExperimentExclusion[] }>("experiment.exclusion.list"); setExclusionHistory({ revision, rows: result.history }); setHistoryPage(0); })}>Read retained exclusion history</button>
      {exclusionHistory ? <><p>{exclusionHistory.rows.length} retained decisions · read at revision {exclusionHistory.revision}{exclusionHistory.revision !== revision ? " · refresh for current decisions" : ""}.</p><div className="workbench-table"><table><thead><tr><th>Target</th><th>Decision</th><th>Reason</th><th>Recorded</th></tr></thead><tbody>{exclusionHistory.rows.slice().reverse().slice(historyPage * 50, (historyPage + 1) * 50).map(value => <tr key={value.id}><th>{value.target} · {value.targetId}</th><td>{value.excluded ? "Excluded" : "Included"}</td><td>{value.reason}</td><td>{value.at} · r{value.revision}</td></tr>)}</tbody></table></div><div className="workbench-actions"><button className="cc-btn" disabled={!historyPage} onClick={() => setHistoryPage(value => value - 1)}>Previous decisions</button><button className="cc-btn" disabled={(historyPage + 1) * 50 >= exclusionHistory.rows.length} onClick={() => setHistoryPage(value => value + 1)}>Next decisions</button></div></> : null}
    </details>
  </>;
}
