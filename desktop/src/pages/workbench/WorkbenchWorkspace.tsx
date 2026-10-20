import { useEffect, useRef, useState } from "react";
import WorkbenchCatalogueBrowser, { useCatalogueEntries, useCataloguePins } from "./WorkbenchCatalogueBrowser";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import type { WorkspaceActions, WorkspaceDescriptor, WorkspaceDetail, WorkspaceImportPreview, WorkspaceSelection, WorkspaceSamples, WorkspaceMutation, WorkspaceMaterializationPreview, WorkspaceOutput } from "../../../../shared/workbench/workspaceProtocol";
import WorkbenchZarrSelection, { WorkbenchZarrRegion, zarrDimensions } from "./WorkbenchZarrSelection";
import type { StorageRegion, StorageSelection } from "../../../../shared/workbench/storageProtocol";
import WorkspacePage from "../workspace/WorkspacePage";
import type { CanonicalWorkspaceAdapter } from "../workspace/canonicalWorkspace";
import { activeJobWorker } from "../../../../shared/workbench/workerProtocol";
import type { SessionNavigation } from "../../../../shared/workbench/sessionProtocol";

type Props = { snapshot: ProjectSnapshot; imageId: string; selection: WorkspaceSelection; busy: boolean; writeBlocked: boolean;
  actions: WorkspaceActions; onEditingChange: (dirty: boolean) => void;
  navigation?: SessionNavigation; onSelectionChange?: (workspaceId: string) => void;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T> };
const describe = (value: unknown) => typeof value === "string" ? value : JSON.stringify(value);

export default function WorkbenchWorkspace({ snapshot, imageId, selection, busy, writeBlocked, actions, onEditingChange, read, navigation, onSelectionChange }: Props) {
  const [zarrSelection, setZarrSelection] = useState<StorageSelection>({ sourceId: "", arrayPath: "", timeIndex: 0, channel: 0, zIndex: 0 });
  const [zarrRegion, setZarrRegion] = useState<StorageRegion>({ x: 0, y: 0, width: 512, height: 512 });
  const [zarrFollow, setZarrFollow] = useState(true);
  const [zarrOverview, setZarrOverview] = useState<{ key: string; dataUrl: string; width: number; height: number }>();
  const [open, setOpen] = useState(false), [loading, setLoading] = useState(false), [error, setError] = useState("");
  const workspaces = snapshot.workspaces ?? [];
  const [workspaceId, setWorkspaceId] = useState("");
  const [detail, setDetail] = useState<{ revision: number; value: WorkspaceDetail }>();
  const [name, setName] = useState("Layer workspace"), [layerId, setLayerId] = useState("");
  const [dirty, setDirty] = useState(false);
  const outputs = useCatalogueEntries<WorkspaceOutput>("workspaceOutputs").filter(item => item.workspaceId === workspaceId);
  const [materializeLayerId, setMaterializeLayerId] = useState("");
  const [followPosition, setFollowPosition] = useState(false);
  const [materialization, setMaterialization] = useState<{ revision: number; value: WorkspaceMaterializationPreview }>();
  const [role, setRole] = useState<"raw-source" | "instance-labels">("raw-source");
  const [zIndex, setZIndex] = useState(0);
  const [importPath, setImportPath] = useState(""), [importFormat, setImportFormat] = useState<"portable" | "native">("portable");
  const [importPreview, setImportPreview] = useState<{ path: string; format: "portable" | "native"; revision: number; value: WorkspaceImportPreview }>();
  const pinError = useCataloguePins([{ catalogue: "workspaces", entryId: workspaceId }, { catalogue: "zarrSources", entryId: zarrSelection.sourceId }]);
  const epoch = useRef(0); const latest = useRef({ read }); latest.current = { read };
  const workerActive = snapshot.jobWorkers?.some(activeJobWorker) === true;
  const locked = busy || loading || workerActive;
  const selected = detail?.value.workspace.id === workspaceId ? detail.value : undefined;
  const current = detail?.revision === snapshot.project.revision;
  const mutationBlocked = locked || writeBlocked || !current;
  const zarrSource = snapshot.zarrSources?.find(item => item.id === zarrSelection.sourceId);
  const zarrDims = zarrDimensions(zarrSource, zarrSelection.arrayPath);
  const zarrKey = JSON.stringify([zarrSelection, zarrSource?.metadataHash]);
  const zarrValid = Boolean(zarrSource && Object.values(zarrRegion).every(Number.isInteger) && zarrRegion.x >= 0 && zarrRegion.y >= 0 && zarrRegion.width > 0 && zarrRegion.height > 0 && zarrRegion.width * zarrRegion.height <= 4_000_000
    && zarrRegion.x + zarrRegion.width <= zarrDims.x && zarrRegion.y + zarrRegion.height <= zarrDims.y && [[zarrSelection.timeIndex, zarrDims.t ?? 1], [zarrSelection.channel, zarrDims.c ?? 1], [zarrSelection.zIndex, zarrDims.z ?? 1]].every(([value, limit]) => Number.isInteger(value) && value >= 0 && value < limit));
  const selectedImage = snapshot.images.find((image) => image.id === imageId);
  const fixedSelection = selection.target === "volume" ? { ...selection, zIndex: Math.min(zIndex, Math.max(0, (selectedImage?.zCount ?? 1) - 1)) } : selection;
  useEffect(() => { onEditingChange(dirty); return () => onEditingChange(false); }, [dirty, onEditingChange]);
  useEffect(() => { onSelectionChange?.(workspaceId); }, [workspaceId, onSelectionChange]);
  useEffect(() => {
    if (!navigation?.selection.workspaceId) return;
    setOpen(true); setWorkspaceId(navigation.selection.workspaceId);
  }, [navigation?.id]);
  useEffect(() => () => { epoch.current++; }, []);
  useEffect(() => {
    if (open) setWorkspaceId(old => old || workspaces[0]?.id || "");
  }, [open, snapshot.project.revision]);
  useEffect(() => {
    if (!open || !workspaceId || busy || workerActive || dirty) return;
    let active = true; const generation = ++epoch.current;
    void latest.current.read<WorkspaceDetail>("workspace.get", { workspaceId }).then((value) => {
      if (active && generation === epoch.current) {
        setDetail({ revision: snapshot.project.revision, value });
        setLayerId((old) => value.document.layers.some((item) => item.id === old) ? old : value.document.layers[0]?.id ?? "");

      }
    }).catch((cause) => { if (active) setError(String(cause)); });
    return () => { active = false; };
  }, [open, workspaceId, snapshot.project.revision, busy, workerActive, dirty]);
  const readAction = async (operation: string, args: Record<string, unknown>, accepted: (value: any) => void) => {
    if (locked) return; setLoading(true); setError(""); const generation = ++epoch.current;
    try { const value = await read(operation, args); if (generation === epoch.current) accepted(value); }
    catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  const commit = async (operation: WorkspaceMutation, args: Record<string, unknown>) => {
    if (!detail || detail.revision !== snapshot.project.revision) throw new Error("The project changed. Your workspace draft is retained; discard or copy it before loading current state.");
    const retained = await actions.commit(operation, args, detail.revision);
    if (!retained) throw new Error("The workspace operation did not complete. Your local draft is retained.");
    setDetail(retained); setWorkspaceId(retained.value.workspace.id);
  };
  const editor: CanonicalWorkspaceAdapter | undefined = selected && detail ? {
    document: selected.document,
    identity: `${workspaceId}:${selected.workspace.version}:${detail.revision}`,
    blocked: locked || writeBlocked,
    saveBlocked: !current,
    onDirty: setDirty,
    resolvePlane: async (sourceLayer, document) => {
      const value = await latest.current.read<WorkspaceSamples>("workspace.layer.samples", { workspaceId, layerId: sourceLayer.id, position: document.position });
      if (value.version !== selected.workspace.version || value.workspaceId !== workspaceId || value.layerId !== sourceLayer.id || value.dtype !== "float32-le")
        throw new Error("The saved layer changed while loading its exact source. Retain your draft and reload the workspace.");
      const count = value.width * value.height;
      if (!Number.isSafeInteger(count) || count < 1 || count > 4_000_000 || value.dataBase64.length > Math.ceil(count * 4 / 3) * 4)
        throw new Error("The exact workspace plane exceeds its editor bounds.");
      const encoded = atob(value.dataBase64);
      if (encoded.length !== count * 4) throw new Error("The source plane byte count does not match its dimensions.");
      const bytes = Uint8Array.from(encoded, character => character.charCodeAt(0));
      const view = new DataView(bytes.buffer); const values = new Float32Array(count);
      for (let index = 0; index < count; index++) values[index] = view.getFloat32(index * 4, true);
      const support = value.supportBase64 == null ? undefined : Uint8Array.from(atob(value.supportBase64), character => character.charCodeAt(0));
      if (support && (support.length !== count || support.some(value => value > 1))) throw new Error("Source support does not match its exact grid.");
      return { width: value.width, height: value.height, values, support, ...(value.calibration ? { calibration: value.calibration } : {}) };
    },
    save: document => commit("workspace.document.update", { workspaceId, workspaceVersion: selected.workspace.version, documentJson: JSON.stringify(document) }),
    operation: step => commit("workspace.operation.run", { workspaceId, step }),
    replay: workflowId => commit("workspace.replay", { workspaceId, workflowId }),
    linkPoints: maxDistance => commit("pointlineage.build", { workspaceId, maxDistance }),
    renderExport: (kind, id) => actions.export(workspaceId, detail.revision, { kind, id }),
    exportProject: () => actions.export(workspaceId, detail.revision),
    exportDraft: document => actions.exportDraft(document, detail.revision),
    importGeometry: () => actions.importGeometry(detail.revision),
  } : undefined;
  const validImport = importPreview?.path === importPath && importPreview.format === importFormat && importPreview.revision === snapshot.project.revision ? importPreview.value : undefined;
  return <details className="workbench-package" open={open} onToggle={(event) => setOpen(event.currentTarget.open)}>
    <summary>Layer workspaces</summary>
    {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    <p>Arrange image, semantic-label and vector layers in this project. Source pixels, instance masks and scientific measurements remain bound to their canonical image and selection.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <fieldset disabled={locked || writeBlocked || dirty}>
      <label>Saved workspace<select value={workspaceId} onChange={(event) => { setWorkspaceId(event.target.value); }}>
        {!workspaces.length ? <option value="">No saved workspace</option> : null}
        {workspaces.map((item) => <option key={item.id} value={item.id}>{item.name} · version {item.version}</option>)}
      </select></label>
      <details><summary>Create or import a workspace</summary>
        <label>New workspace name<input value={name} maxLength={200} onChange={(event) => setName(event.target.value)} /></label>
        <button type="button" className="cc-btn" disabled={!name.trim()} onClick={() => void actions.mutate<{ workspace: WorkspaceDescriptor }>("workspace.create", { name: name.trim() }, snapshot.project.revision,
          (result) => setWorkspaceId(result.workspace.id))}>Create empty workspace</button>
        <button type="button" className="cc-btn" onClick={() => void actions.openExisting(path => { setImportPath(path); setImportFormat("portable"); setImportPreview(undefined); })}>Open existing local workspace…</button>
        <p>This copies the existing library workspace for previewed import. Original documents and source files remain available.</p>
        <p><a href="#/workspace-archive">Read or export the original workspace archive</a></p>
        <label>Import format<select value={importFormat} onChange={(event) => setImportFormat(event.target.value as "portable" | "native")}>
          <option value="portable">Portable microscopy project</option><option value="native">Native layer-workspace metadata</option>
        </select></label>
        <button type="button" className="cc-btn" onClick={() => void actions.chooseImport((path) => { setImportPath(path); setImportPreview(undefined); })}>Choose workspace JSON…</button>
        {importPath ? <p className="workbench-project-path">{importPath}</p> : null}
        <button type="button" className="cc-btn" disabled={!importPath} onClick={() => void readAction("workspace.import.preview", { path: importPath, format: importFormat },
          (value: WorkspaceImportPreview) => setImportPreview({ path: importPath, format: importFormat, revision: snapshot.project.revision, value }))}>Preview workspace import</button>
        {validImport ? <><p>{validImport.missingSources.length} sources require explicit attachment.</p>
          <pre className="workbench-json">{JSON.stringify(validImport.summary, null, 2).slice(0, 8192)}</pre>
          {validImport.notes.map((note, index) => <p key={index}>{note}</p>)}
          <button type="button" className="cc-btn" onClick={() => void actions.import({ path: importPath, format: importFormat, previewFingerprint: validImport.previewFingerprint }, snapshot.project.revision,
            (workspace) => { setWorkspaceId(workspace.id); setImportPreview(undefined); })}>Import as a new workspace</button></> : null}
      </details>
    </fieldset>
    {selected ? <>
      <p>{selected.workspace.name} · version {selected.workspace.version} · {selected.workspace.layerCount} layers · {selected.workspace.sourceBindingsCurrent === null ? "external source ranges checked when used" : selected.workspace.sourceBindingsCurrent ? "sources current" : "sources need attention"}</p>
      {selected.missingSources.length ? <details><summary>Sources requiring attachment</summary><ul>{selected.missingSources.map((source, index) => <li key={index}>{describe(source)}</li>)}</ul></details> : null}
      {!current ? <p role="status">The project changed while these layer settings were open. Discard the local layer draft to load the current saved version before applying changes.</p> : null}
      <fieldset disabled={mutationBlocked || dirty}>
        <legend>Attach the selected image</legend>
        <p>{selectedImage?.name ?? "Select a project image"} · channel {selection.channel + 1}{selection.target === "volume" ? ` · time ${(selection.timeIndex ?? 0) + 1}` : ` · ${selection.zProjection} Z projection`}</p>
        {selection.target === "volume" ? <label>Z plane (1-based)<input type="number" min={1} max={selectedImage?.zCount ?? 1} value={fixedSelection.zIndex! + 1} onChange={(event) => setZIndex(Math.max(0, Number(event.target.value) - 1))} /></label> : null}
        <label><input type="checkbox" disabled={role !== "raw-source" || selection.target !== "volume"} checked={followPosition && role === "raw-source" && selection.target === "volume"} onChange={event => setFollowPosition(event.target.checked)} />Follow workspace time, Z and channel positions</label>
        <p>Enable this for an acquired volume slice to browse its exact source positions. Fixed projected planes and saved instance masks remain tied to their selected acquisition.</p>
        <label>Layer role<select value={role} onChange={(event) => setRole(event.target.value as typeof role)}><option value="raw-source">Source intensity</option><option value="instance-labels">Saved instance masks</option></select></label>
        <button type="button" className="cc-btn" disabled={!imageId} onClick={() => void actions.mutate("workspace.layer.add", { workspaceId, imageId, role, selection: fixedSelection, followPosition: followPosition && role === "raw-source" && selection.target === "volume" }, snapshot.project.revision)}>Add image as a new layer</button>
        <button type="button" className="cc-btn" disabled={!imageId || !layerId} onClick={() => void actions.mutate("workspace.source.bind", { workspaceId, layerId, imageId, role, selection: fixedSelection, followPosition: followPosition && role === "raw-source" && selection.target === "volume" }, snapshot.project.revision)}>Attach image to the chosen saved layer</button>
      </fieldset>
      <label>Existing layer for source attachment<select value={layerId} disabled={locked || dirty} onChange={(event) => setLayerId(event.target.value)}>
        {!selected.document.layers.length ? <option value="">No layers</option> : null}
        {selected.document.layers.map((item) => <option key={item.id} value={item.id}>{item.name} · {item.kind}</option>)}
      </select></label>
      <details><summary>Attach a live NGFF source region</summary>
        <p>Register a source under OME-Zarr sources above, then choose its exact resolution and ROI here. Time/Z/channel browsing reads bounded source planes without extracting an acquisition for every view.</p>
        <WorkbenchZarrSelection sources={snapshot.zarrSources ?? []} value={zarrSelection} disabled={locked || dirty} onChange={value => {
          if (value.sourceId !== zarrSelection.sourceId || value.arrayPath !== zarrSelection.arrayPath) {
            const dimensions = zarrDimensions(snapshot.zarrSources?.find(item => item.id === value.sourceId), value.arrayPath);
            setZarrRegion({ x: 0, y: 0, width: Math.min(512, dimensions.x ?? 512), height: Math.min(512, dimensions.y ?? 512) });
          }
          setZarrSelection(value);
        }} />
        <button type="button" className="cc-btn" disabled={locked || !zarrSource?.available || !zarrSelection.arrayPath} onClick={() => void readAction("zarr.overview", { ...zarrSelection, maxSize: 768 },
          (value: { dataUrl: string; width: number; height: number }) => setZarrOverview({ key: zarrKey, ...value }))}>Read selected-level overview</button>
        {zarrOverview?.key === zarrKey ? <figure><img className="workbench-output-image" src={zarrOverview.dataUrl} alt="Display-only NGFF overview for choosing an exact layer region" /><figcaption>{zarrOverview.width} × {zarrOverview.height} selected-level source pixels; this overview is sampled for display.</figcaption></figure> : null}
        <WorkbenchZarrRegion value={zarrRegion} onChange={setZarrRegion} disabled={locked || dirty} maxPixels={4_000_000} />
        <label><input type="checkbox" disabled={locked || dirty} checked={zarrFollow} onChange={event => setZarrFollow(event.target.checked)} />Follow workspace time, Z and channel axes</label>
        <div className="workbench-actions"><button type="button" className="cc-btn" disabled={mutationBlocked || dirty || !zarrValid || !zarrSource?.available} onClick={() => void actions.mutate("workspace.zarr.add", { workspaceId, ...zarrSelection, ...zarrRegion, followPosition: zarrFollow }, snapshot.project.revision)}>Add exact NGFF region as a layer</button>
          <button type="button" className="cc-btn" disabled={mutationBlocked || dirty || !zarrValid || !layerId || !zarrSource?.available} onClick={() => void actions.mutate("workspace.zarr.bind", { workspaceId, layerId, ...zarrSelection, ...zarrRegion, followPosition: zarrFollow }, snapshot.project.revision)}>Attach NGFF region to the chosen saved layer</button></div>
        {!zarrValid && zarrSource ? <p>Choose an in-bounds ROI containing at most four million pixels and an available T/Z/channel position.</p> : null}
      </details>
      {editor ? <WorkspacePage canonical={editor} /> : null}
      <details><summary>Create scientific image from a generated layer</summary>
        <p>Retain a stitched intensity grid as an independent analysis image with its exact acquired-support mask and all parent coordinates. Semantic classes and display-only transforms are not promoted to acquired pixels.</p>
        <label>Generated intensity layer<select disabled={locked || dirty} value={materializeLayerId} onChange={event => { setMaterializeLayerId(event.target.value); setMaterialization(undefined); }}><option value="">Choose a retained generated layer</option>
          {(selected.generatedLayers ?? []).filter(item => item.materializable).map(item => <option key={item.layerId} value={item.layerId}>{selected.document.layers.find(layer => layer.id === item.layerId)?.name ?? item.layerId} · {item.width} × {item.height}</option>)}</select></label>
        <button type="button" className="cc-btn" disabled={locked || dirty || !current || !selected.generatedLayers?.some(item => item.layerId === materializeLayerId && item.materializable)} onClick={() => void readAction("workspace.materialize.preview", { workspaceId, layerId: materializeLayerId },
          (value: WorkspaceMaterializationPreview) => setMaterialization({ revision: snapshot.project.revision, value }))}>Preview scientific image</button>
        {materialization?.revision === snapshot.project.revision && materialization.value.layerId === materializeLayerId && materialization.value.workspaceId === workspaceId ? <>
          <p>{materialization.value.width} × {materialization.value.height} pixels · {materialization.value.validSamples.toLocaleString()} / {materialization.value.totalSamples.toLocaleString()} supported samples · {materialization.value.calibration ? `${materialization.value.calibration.x} × ${materialization.value.calibration.y} ${materialization.value.calibration.unit} per pixel` : "Physical calibration unknown"}</p>
          <ul>{materialization.value.notes.map((note, index) => <li key={index}>{note}</li>)}</ul>
          <details><summary>Parent sources and coordinates</summary><ul>{materialization.value.parents.map((parent, index) => <li key={index}>{snapshot.images.find(image => image.id === parent.imageId)?.name ?? parent.imageId ?? parent.sourceId} · {parent.arrayPath ? `${parent.arrayPath} · ROI ${JSON.stringify(parent.region)} · ` : ""}{JSON.stringify(parent.selection)}</li>)}</ul><p>Exact coordinate identity: {materialization.value.coordinateIdentity}</p></details>
          <button type="button" className="cc-btn" disabled={mutationBlocked || dirty} onClick={() => void actions.mutate("workspace.materialize.run", { workspaceId, layerId: materializeLayerId, previewFingerprint: materialization.value.previewFingerprint }, snapshot.project.revision, () => setMaterialization(undefined))}>Create independent scientific image</button>
        </> : null}
      </details>
      <div className="workbench-actions">
        <button type="button" className="cc-btn" disabled={mutationBlocked || dirty || !selected.workspace.undoAvailable} onClick={() => void actions.mutate("workspace.undo", { workspaceId }, snapshot.project.revision)}>Restore previous workspace version</button>
      </div>
      <details><summary>Retained workspace outputs</summary>
        <WorkbenchCatalogueBrowser catalogues={["workspaceOutputs"]} title="Browse all retained workspace outputs" disabled={locked} onChoose={(_, value) => {
          if (value.workspaceId !== workspaceId) setError("This output belongs to a different saved workspace. Select that workspace to use its export controls.");
        }} />
        <p>{outputs.length} available output records for this workspace. Browse older records to make them available here; the recent page is not the complete output history.</p>
        {outputs.map(output => <div key={output.id}><p>{output.operation} · workspace v{output.workspaceVersion} · {output.outputsCurrent === null ? "Retained output; external ranges require a new source check" : output.outputsCurrent ? "Current saved output" : "Historical output; inputs or workspace changed"}</p>
          <ul>{output.files.map(file => <li key={file.id}>{file.kind} · {file.bytes.toLocaleString()} bytes <button type="button" className="cc-btn" disabled={mutationBlocked || dirty} onClick={() => void actions.exportOutput(output, file.id, snapshot.project.revision)}>Export exact artifact…</button></li>)}</ul></div>)}
      </details>
      <details><summary>Advanced metadata interchange</summary><p>Import a complete validated shared workspace document as a new retained version. Existing scientific acquisitions and masks remain independent.</p>
        <button type="button" className="cc-btn" disabled={mutationBlocked || dirty} onClick={() => void actions.replaceDocument(workspaceId, snapshot.project.revision)}>Replace saved metadata from JSON…</button>
      </details>
    </> : null}
    {workerActive ? <p>Stop background execution after its current checkpoint before changing workspace versions.</p> : null}
  </details>;
}
