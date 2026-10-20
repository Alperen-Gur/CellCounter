import { useEffect, useRef, useState } from "react";
import type { OmeroActions, OmeroImage, OmeroObject, OmeroObjectKind, OmeroPreview, OmeroRegion, OmeroRuntime } from "../../../../shared/workbench/omeroProtocol";
import { request } from "../../kernel/workbench/client";

type Props = { busy: boolean; writeBlocked: boolean; canImport: boolean; actions: OmeroActions };
type Hierarchy = { kind: OmeroObjectKind; parentKind?: OmeroObjectKind; parentId?: number; name: string };
const roots: Hierarchy[] = [{ kind: "project", name: "Projects" }, { kind: "screen", name: "Screens" }, { kind: "image", name: "All images in group" }];
const child: Partial<Record<OmeroObjectKind, OmeroObjectKind>> = { project: "dataset", dataset: "image", screen: "plate", plate: "well", well: "image" };
const initialRegion: OmeroRegion = { timeIndex: 0, channel: 0, zIndex: 0, x: 0, y: 0, width: 512, height: 512 };
const numberText = (value: number | null) => value == null ? "unknown" : value.toLocaleString(undefined, { maximumSignificantDigits: 6 });

export default function WorkbenchOmero({ busy, writeBlocked, canImport, actions }: Props) {
  const [runtime, setRuntime] = useState<OmeroRuntime>();
  const [probe, setProbe] = useState<string>();
  const [error, setError] = useState("");
  const [profileId, setProfileId] = useState("");
  const [profileDraft, setProfileDraft] = useState({ profileId: "laboratory", name: "Laboratory OMERO", host: "", port: 4064, username: "", passwordEnv: "", credentialFile: "", caFile: "" });
  const [credentialKind, setCredentialKind] = useState<"file" | "environment">("file");
  const [groups, setGroups] = useState<{ id: number; name: string }[]>([]);
  const [groupOffset, setGroupOffset] = useState(0);
  const [nextGroupOffset, setNextGroupOffset] = useState<number | null>(null);
  const [groupId, setGroupId] = useState<number>();
  const [trail, setTrail] = useState<Hierarchy[]>([roots[0]]);
  const [objects, setObjects] = useState<OmeroObject[]>([]);
  const [offset, setOffset] = useState(0);
  const [nextOffset, setNextOffset] = useState<number | null>(null);
  const [image, setImage] = useState<OmeroImage>();
  const [region, setRegion] = useState<OmeroRegion>(initialRegion);
  const [name, setName] = useState("");
  const [render, setRender] = useState<{ key: string; preview: OmeroPreview }>();
  const alive = useRef(true);
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  const read = <T,>(operation: string, args: Record<string, unknown> = {}) => request<T>("", operation, args);
  const operation = (action: () => Promise<void>) => actions.run(async () => {
    setError("");
    try { await action(); } catch (cause) { if (alive.current) setError(String(cause)); }
  });
  const selectedProfile = runtime?.profiles.find(item => item.id === profileId);
  const selectionKey = JSON.stringify([profileId, groupId, image?.id, region]);
  const currentRender = render?.key === selectionKey ? render.preview : undefined;
  const validRegion = image && Object.values(region).every(Number.isInteger) && region.x >= 0 && region.y >= 0
    && region.width > 0 && region.height > 0 && region.width * region.height <= 16_000_000
    && region.x + region.width <= image.dimensions.x && region.y + region.height <= image.dimensions.y
    && region.timeIndex >= 0 && region.timeIndex < image.dimensions.t && region.channel >= 0 && region.channel < image.dimensions.c
    && region.zIndex >= 0 && region.zIndex < image.dimensions.z;
  const regionArgs = () => ({ profileId, groupId, imageId: image?.id, ...region });
  const loadRuntime = async () => {
    const value = await read<OmeroRuntime>("omero.runtime.inspect");
    setRuntime(value);
    setProfileId(previous => value.profiles.some(item => item.id === previous) ? previous : value.profiles[0]?.id ?? "");
  };
  const clearRemote = () => { setGroups([]); setGroupId(undefined); setObjects([]); setImage(undefined); setRender(undefined); setTrail([roots[0]]); };
  const loadGroups = async (pageOffset = 0) => {
    const value = await read<{ groups: { id: number; name: string }[]; nextOffset: number | null }>("omero.group.list", { profileId, offset: pageOffset, limit: 50 });
    setGroups(value.groups); setGroupOffset(pageOffset); setNextGroupOffset(value.nextOffset);
    setGroupId(previous => value.groups.some(item => item.id === previous) ? previous : value.groups[0]?.id);
    setObjects([]); setImage(undefined); setRender(undefined);
  };
  const loadObjects = async (selection = trail, pageOffset = 0) => {
    if (groupId == null) return;
    const target = selection[selection.length - 1];
    const value = await read<{ objects: OmeroObject[]; nextOffset: number | null }>("omero.object.list", {
      profileId, groupId, kind: target.kind, ...(target.parentId != null ? { parentId: target.parentId, parentKind: target.parentKind } : {}), offset: pageOffset, limit: 50,
    });
    setTrail(selection); setObjects(value.objects); setOffset(pageOffset); setNextOffset(value.nextOffset); setImage(undefined); setRender(undefined);
  };
  const selectObject = async (value: OmeroObject) => {
    if (value.kind === "image") {
      const result = await read<{ image: OmeroImage }>("omero.image.inspect", { profileId, groupId, imageId: value.id });
      setImage(result.image); setName(""); setRender(undefined);
      setRegion({ ...initialRegion, width: Math.min(512, result.image.dimensions.x), height: Math.min(512, result.image.dimensions.y) });
    } else {
      const next = child[value.kind];
      if (next) await loadObjects([...trail, { kind: next, parentKind: value.kind, parentId: value.id, name: value.name }]);
    }
  };
  return <details className="workbench-automation">
    <summary>OMERO sources</summary>
    <p>Browse a named server profile and import an exact raw-pixel region. Connections use validated TLS. Server content is read only; credentials stay on this computer.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <div className="workbench-actions"><button className="cc-btn" disabled={busy} onClick={() => void operation(loadRuntime)}>Load local profiles</button></div>
    <details><summary>Connection setup and isolated runtime</summary>
      <p>OMERO uses a separate environment with omero-py 5.23.0, NumPy 2 and Ice 3.6. Select an existing interpreter; this does not install software or change analysis/model environments.</p>
      {runtime ? <><p>Runtime: {runtime.status}</p><p className="workbench-project-path">Profile registry: {runtime.registryPath ?? "No host registry selected"}</p>
        {runtime.pythonPath ? <p className="workbench-project-path">Interpreter: {runtime.pythonPath}</p> : null}</> : <p>Load local profiles to read setup status.</p>}
      <div className="workbench-actions">
        <button className="cc-btn" disabled={busy || writeBlocked || !runtime} onClick={() => void actions.chooseFile("Choose the isolated OMERO Python interpreter", async path => {
          const candidate = await read<{ pythonPath: string; pythonSha256: string }>("omero.runtime.candidate", { pythonPath: path });
          await read("omero.runtime.configure", { pythonPath: candidate.pythonPath, pythonSha256: candidate.pythonSha256, expectedConfigurationHash: runtime!.configurationHash });
          setProbe(undefined); await loadRuntime();
        })}>Bind isolated interpreter…</button>
        <button className="cc-btn" disabled={busy || !runtime?.configured} onClick={() => void operation(async () => {
          const value = await read<{ ready: boolean; pythonVersion: string; omeroVersion: string; iceVersion: string }>("omero.runtime.probe");
          setProbe(`Ready · Python ${value.pythonVersion} · OMERO ${value.omeroVersion} · Ice ${value.iceVersion}. No server connection was made.`);
        })}>Probe isolated runtime</button>
      </div>
      {probe ? <p role="status">{probe}</p> : null}
      <fieldset disabled={busy || writeBlocked || !runtime}>
        <legend>Save a local connection profile</legend>
        <p>Use the same profile ID to replace its host-local settings. Changes require the configuration version loaded above.</p>
        {(["profileId", "name", "host", "username"] as const).map(key => <label key={key}>{({ profileId: "Profile ID", name: "Display name", host: "Server DNS host or IPv4 address", username: "User name" })[key]}
          <input value={profileDraft[key]} autoComplete="off" onChange={event => setProfileDraft(previous => ({ ...previous, [key]: event.target.value }))} /></label>)}
        <label>TLS port<input type="number" min={1} max={65535} value={profileDraft.port} onChange={event => setProfileDraft(previous => ({ ...previous, port: Number(event.target.value) }))} /></label>
        <label>Credential reference<select value={credentialKind} onChange={event => setCredentialKind(event.target.value as typeof credentialKind)}>
          <option value="file">Private local credential file</option><option value="environment">Explicit environment-variable name</option></select></label>
        {credentialKind === "file" ? <><p>Choose an existing private JSON file containing a password field. Its contents are never shown or added to the project.</p>
          <p className="workbench-project-path">{profileDraft.credentialFile || "No credential file selected"}</p>
          <button className="cc-btn" onClick={() => void actions.chooseFile("Choose the private OMERO credential file", path => setProfileDraft(previous => ({ ...previous, credentialFile: path })))}>Choose credential file…</button></>
          : <label>Environment-variable name<input value={profileDraft.passwordEnv} autoComplete="off" placeholder="LAB_OMERO_PASSWORD" onChange={event => setProfileDraft(previous => ({ ...previous, passwordEnv: event.target.value }))} /></label>}
        <label>Certificate trust<select value={profileDraft.caFile ? "custom" : "platform"} onChange={event => {
          if (event.target.value === "platform") setProfileDraft(previous => ({ ...previous, caFile: "" }));
          else void actions.chooseFile("Choose the OMERO CA certificate PEM file", path => setProfileDraft(previous => ({ ...previous, caFile: path })));
        }}><option value="platform">System certificate authorities</option><option value="custom">Choose a custom CA file…</option></select></label>
        {profileDraft.caFile ? <p className="workbench-project-path">{profileDraft.caFile}</p> : null}
        <button className="cc-btn" disabled={!profileDraft.host || !profileDraft.username || !(credentialKind === "file" ? profileDraft.credentialFile : profileDraft.passwordEnv)} onClick={() => void operation(async () => {
          await read("omero.profile.save", { profileId: profileDraft.profileId, name: profileDraft.name, host: profileDraft.host, port: profileDraft.port,
            username: profileDraft.username, ...(credentialKind === "file" ? { credentialFile: profileDraft.credentialFile } : { passwordEnv: profileDraft.passwordEnv }),
            ...(profileDraft.caFile ? { caFile: profileDraft.caFile } : {}), expectedConfigurationHash: runtime!.configurationHash });
          clearRemote(); await loadRuntime(); setProfileId(profileDraft.profileId);
        })}>Save local profile</button>
      </fieldset>
    </details>
    <fieldset disabled={busy || !runtime?.profiles.length}>
      <legend>Browse server sources</legend>
      <label>Connection profile<select value={profileId} onChange={event => { setProfileId(event.target.value); clearRemote(); }}>
        {!runtime?.profiles.length ? <option value="">Load or configure a local profile</option> : null}
        {runtime?.profiles.map(item => <option key={item.id} value={item.id}>{item.name} · {item.host}</option>)}
      </select></label>
      {selectedProfile ? <p>{selectedProfile.username}@{selectedProfile.host}:{selectedProfile.port} · TLS with host-name validation · {selectedProfile.certificateAuthority === "custom-ca" ? "custom CA" : "system CAs"}</p> : null}
      <button className="cc-btn" disabled={!profileId} onClick={() => void operation(() => loadGroups())}>Connect and list groups</button>
      {groups.length ? <><label>Group<select value={groupId ?? ""} onChange={event => { setGroupId(Number(event.target.value)); setObjects([]); setImage(undefined); setRender(undefined); setTrail([roots[0]]); }}>
        {groups.map(item => <option key={item.id} value={item.id}>{item.name} · {item.id}</option>)}</select></label>
        <div className="workbench-actions"><button className="cc-btn" disabled={groupOffset === 0} onClick={() => void operation(() => loadGroups(Math.max(0, groupOffset - 50)))}>Previous groups</button>
          <button className="cc-btn" disabled={nextGroupOffset == null} onClick={() => void operation(() => loadGroups(nextGroupOffset!))}>Next groups</button></div>
        <div className="workbench-actions">{roots.map(item => <button key={item.kind} className="cc-btn" onClick={() => void operation(() => loadObjects([item]))}>{item.name}</button>)}</div>
      </> : null}
      {objects.length || trail.length > 1 ? <><nav aria-label="OMERO source hierarchy">{trail.map((item, index) => <button key={`${item.kind}-${item.parentId ?? "root"}`} className="cc-btn" onClick={() => void operation(() => loadObjects(trail.slice(0, index + 1)))}>{item.name}</button>)}</nav>
        <ul>{objects.map(item => <li key={`${item.kind}-${item.id}`}><button className="cc-btn" onClick={() => void operation(() => selectObject(item))}>{item.name || `Unnamed ${item.kind}`} · {item.id}{item.kind === "image" ? " · Inspect pixels" : " · Open"}</button></li>)}</ul>
        <div className="workbench-actions"><button className="cc-btn" disabled={offset === 0} onClick={() => void operation(() => loadObjects(trail, Math.max(0, offset - 50)))}>Previous sources</button>
          <button className="cc-btn" disabled={nextOffset == null} onClick={() => void operation(() => loadObjects(trail, nextOffset!))}>Next sources</button></div></> : null}
    </fieldset>
    {image ? <fieldset disabled={busy}>
      <legend>Raw region from {image.name}</legend>
      <p>{image.dimensions.x} × {image.dimensions.y} pixels · {image.dimensions.z} Z planes · {image.dimensions.c} channels · {image.dimensions.t} time points · {image.dtype}</p>
      <p>Pixel calibration: X {numberText(image.voxelSizeUm.x)} µm; Y {numberText(image.voxelSizeUm.y)} µm; Z {numberText(image.voxelSizeUm.z)} µm.</p>
      <div className="workbench-editor-grid">
        {([ ["timeIndex", "Time point", image.dimensions.t], ["channel", "Channel", image.dimensions.c], ["zIndex", "Z plane", image.dimensions.z] ] as const).map(([key, label, maximum]) =>
          <label key={key}>{label} (starting at 1)<input type="number" min={1} max={maximum} value={region[key] + 1} onChange={event => setRegion(previous => ({ ...previous, [key]: Number(event.target.value) - 1 }))} /></label>)}
        {(["x", "y", "width", "height"] as const).map(key => <label key={key}>{key === "x" || key === "y" ? `${key.toUpperCase()} origin (starting at 0)` : `${key} (source pixels)`}
          <input type="number" min={key === "x" || key === "y" ? 0 : 1} value={region[key]} onChange={event => setRegion(previous => ({ ...previous, [key]: Number(event.target.value) }))} /></label>)}
      </div>
      <p>At most 16 million pixels / 128 MiB. This import becomes a single-channel, single-plane image; the original T/C/Z coordinates remain in provenance.</p>
      <button className="cc-btn" disabled={!validRegion} onClick={() => void operation(async () => {
        const value = await read<OmeroPreview>("omero.import.preview", { ...regionArgs(), maxSize: 768 });
        setRender({ key: selectionKey, preview: value });
      })}>Preview raw region</button>
      {render && !currentRender ? <p>Selection changed. Preview the current region before importing.</p> : null}
      {currentRender ? <><img src={currentRender.dataUrl} alt="Display-scaled preview of the selected raw OMERO region" style={{ maxWidth: "100%", maxHeight: 480, objectFit: "contain" }} />
        <p>Preview display is scaled; imported pixels retain raw values and source resolution.</p>
        <details><summary>Source identity and calibration notes</summary><p>Pixels ID {image.pixelsId}; source image ID {image.id}; group {image.groupId}.</p><p className="workbench-project-path">Selected raw pixels SHA-256: {currentRender.pixelSha256}</p>
          <ul>{[...image.notes, ...currentRender.notes].map((note, index) => <li key={index}>{note}</li>)}</ul></details></> : null}
      <label>Imported image name<input value={name} maxLength={200} placeholder="Use source and selection name" onChange={event => setName(event.target.value)} /></label>
      <button className="cc-btn" disabled={!currentRender || !canImport || writeBlocked} onClick={() => void actions.importRegion({ ...regionArgs(), previewFingerprint: currentRender!.previewFingerprint, ...(name.trim() ? { name: name.trim() } : {}) })}>Import exact raw region</button>
      {!canImport ? <p>Create or open a local project to retain the selected raw region.</p> : writeBlocked ? <p>Save or discard scientific drafts and stop background work before importing.</p> : null}
    </fieldset> : null}
  </details>;
}
