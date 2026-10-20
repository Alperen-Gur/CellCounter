import { useEffect, useRef, useState } from "react";
import WorkbenchCatalogueBrowser, { useCatalogueEntries, useCataloguePins } from "./WorkbenchCatalogueBrowser";
import type { WorkbenchImage } from "../../../../shared/workbench/protocol";
import type { DisplayChannelMapping, DisplayPreset, DisplayPresetMutation, DisplayPresetResolution,
  DisplayPresetSettings, DisplayPresetSummary, DisplayPresetFileActions, DisplayPresetExportFormat,
  DisplayPresetImportPreview } from "../../../../shared/workbench/displayPresetProtocol";

type Props = {
  image: WorkbenchImage; revision: number; active: boolean; busy: boolean; writeBlocked: boolean;
  settings: DisplayPresetSettings; validSettings: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  mutate: DisplayPresetMutation; files: DisplayPresetFileActions; apply: (resolved: DisplayPresetResolution) => void;
};
const units = (value: string) => value === "processed-source" ? "processed intensities" : "raw intensities";

export default function WorkbenchDisplayPresets({ image, revision, active, busy, writeBlocked, settings, validSettings, read, mutate, files, apply }: Props) {
  const retainedPresets = useCatalogueEntries<DisplayPresetSummary>("displayPresets");
  const [presetId, setPresetId] = useState("");
  const [version, setVersion] = useState(0);
  const [preset, setPreset] = useState<DisplayPreset>();
  const [mapping, setMapping] = useState<{ source: number; target: number | "" }[]>([]);
  const [includeArchived, setIncludeArchived] = useState(false);
  const presets = retainedPresets.filter(item => includeArchived || !item.archived || item.id === presetId);
  const pinError = useCataloguePins([{ catalogue: "displayPresets", entryId: presetId }]);
  const [name, setName] = useState("Channel display");
  const [notes, setNotes] = useState("");
  const [loading, setLoading] = useState(false);
  const [acting, setActing] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const [warnings, setWarnings] = useState<string[]>([]);
  const [portableOpen, setPortableOpen] = useState(false);
  const [exportFormat, setExportFormat] = useState<DisplayPresetExportFormat>();
  const [importPath, setImportPath] = useState("");
  const [importName, setImportName] = useState("");
  const [importPreview, setImportPreview] = useState<{ path: string; revision: number; result: DisplayPresetImportPreview }>();
  const epoch = useRef(0);
  const loadedNameKey = useRef("");
  const latest = useRef(read); latest.current = read;
  const selected = preset?.id === presetId && (!version || preset.version === version) ? preset : undefined;
  const summary = presets.find((item) => item.id === presetId);
  const fixedMismatch = selected?.intensityUnits !== settings.intensityUnits && !!selected?.channels.some((item) => item.lower !== undefined || item.upper !== undefined);
  const mappingReady = !!selected && mapping.length === selected.channels.length && mapping.every((item) =>
    item.target !== "" && item.target >= 0 && item.target < image.channels) && new Set(mapping.map((item) => item.target)).size === mapping.length;
  const locked = busy || acting;
  const currentImport = importPreview?.path === importPath && importPreview.revision === revision ? importPreview.result : undefined;

  useEffect(() => {
    epoch.current++; setWarnings([]); setError("");
    return () => { epoch.current++; };
  }, [image.id, image.sourceHash, revision, presetId, version]);
  useEffect(() => {
    if (!active || busy || !presetId) { if (!presetId) setPreset(undefined); return; }
    let current = true; setLoading(true); setError("");
    void latest.current<{ preset: DisplayPreset }>("display.preset.get", { presetId, ...(version ? { version } : {}) }).then((result) => {
      if (current) {
        setPreset(result.preset);
        const key = `${result.preset.id}:${result.preset.version}:${result.preset.hash}`;
        if (loadedNameKey.current !== key) { setName(result.preset.name); setNotes(result.preset.notes); loadedNameKey.current = key; }
      }
    }).catch((cause) => { if (current) setError(String(cause)); })
      .finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [active, busy, presetId, version, revision, attempt]);
  useEffect(() => {
    setMapping(selected?.channels.map((item) => ({ source: item.channel, target: item.channel < image.channels ? item.channel : "" })) ?? []);
  }, [selected?.hash, image.id, image.channels]);
  useEffect(() => {
    if (!active || !portableOpen || busy || exportFormat) return;
    let current = true;
    void latest.current<{ formats: DisplayPresetExportFormat[] }>("display.preset.export.catalogue").then((result) => {
      if (current) setExportFormat(result.formats.find((item) => item.id === "preset-json"));
    }).catch((cause) => { if (current) setError(String(cause)); });
    return () => { current = false; };
  }, [active, portableOpen, busy, exportFormat, attempt]);

  const applySettings = async () => {
    if (!selected || !mappingReady || locked || fixedMismatch) return;
    const generation = ++epoch.current; setActing(true); setError(""); setMessage(""); setWarnings([]);
    try {
      const resolved = await read<DisplayPresetResolution>("display.preset.resolve", {
        presetId: selected.id, version: selected.version, imageId: image.id,
        channelMapping: mapping as DisplayChannelMapping[],
      });
      if (generation !== epoch.current) return;
      apply(resolved); setWarnings([...resolved.compatibility.warnings, ...resolved.notes]);
      setMessage(`Applied ${resolved.presetRef.name}, version ${resolved.presetRef.version}, to the display draft. Render when ready; the previous display stays visible.`);
    } catch (cause) { if (generation === epoch.current) setError(cause instanceof Error ? cause.message : String(cause)); }
    finally { setActing(false); }
  };
  const save = async (asVersion: boolean) => {
    if (locked || writeBlocked || !validSettings || !name.trim() || (asVersion && (!selected || selected.archived))) return;
    setActing(true); setError(""); setMessage("");
    try {
      await mutate("display.preset.save", { ...settings, name: name.trim(), notes, ...(asVersion ? { presetId: selected!.id } : {}) }, ({ preset: saved }) => {
        setPreset(saved); setPresetId(saved.id); setVersion(saved.version); setName(saved.name); setNotes(saved.notes); setAttempt((value) => value + 1);
        setMessage(`Saved ${saved.name}, version ${saved.version}. The channel display draft is preserved.`);
      });
    } finally { setActing(false); }
  };
  const archive = async () => {
    if (locked || writeBlocked || !selected) return;
    const archived = !selected.archived;
    setActing(true); setError(""); setMessage("");
    try {
      await mutate("display.preset.archive", { presetId: selected.id, archived }, ({ preset: saved }) => {
        setPreset(saved); setVersion(0); setIncludeArchived(true); setAttempt((value) => value + 1);
        setMessage(`${saved.name} ${archived ? "archived" : "restored"}. Saved versions remain available.`);
      });
    } finally { setActing(false); }
  };
  const inspectImport = async () => {
    if (!importPath || locked) return;
    const generation = ++epoch.current; setActing(true); setError(""); setImportPreview(undefined);
    try {
      const result = await read<DisplayPresetImportPreview>("display.preset.import.preview", { path: importPath });
      if (generation === epoch.current) { setImportPreview({ path: importPath, revision, result }); setImportName(result.preset.name); }
    } catch (cause) { if (generation === epoch.current) setError(cause instanceof Error ? cause.message : String(cause)); }
    finally { setActing(false); }
  };
  const importPreset = async () => {
    if (!currentImport || !importName.trim() || locked || writeBlocked) return;
    setActing(true); setError(""); setMessage("");
    try {
      await mutate("display.preset.import.run", { path: importPath, previewFingerprint: currentImport.previewFingerprint, name: importName.trim() }, ({ preset: saved }) => {
        setPreset(saved); setPresetId(saved.id); setVersion(saved.version); setImportPreview(undefined); setAttempt((value) => value + 1);
        setMessage(`Imported ${saved.name} as a new local preset. Apply settings explicitly to change the display draft.`);
      });
    } finally { setActing(false); }
  };
  return <section className="workbench-display-presets" aria-label="Display presets">
    {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    <WorkbenchCatalogueBrowser catalogues={["displayPresets"]} title="Browse all display presets" disabled={locked}
      onChoose={(_, entry) => { setPresetId(String(entry.id)); setVersion(0); }} />
    <label>Display preset<select disabled={locked} value={presetId} onChange={(event) => {
      setPresetId(event.target.value); setVersion(0); setPreset(undefined); setMessage(""); setWarnings([]);
    }}><option value="">Choose a saved preset…</option>
      {presetId && !presets.some((item) => item.id === presetId) ? <option value={presetId}>{selected?.name ?? "Selected preset"}{selected?.archived ? " (archived)" : ""}</option> : null}
      {presets.map((item) => <option key={item.id} value={item.id}>{item.name} · v{item.version}{item.archived ? " (archived)" : ""}</option>)}
    </select></label>
    {loading ? <p role="status">Loading the saved preset…</p> : null}
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {message ? <p role="status">{message}</p> : null}
    {warnings.length ? <p>{warnings.join(" ")}</p> : null}
    {selected ? <>
      <p>{selected.channels.length} channels · {units(selected.intensityUnits)} · version {selected.version} of {selected.latestVersion}.
        {selected.archived ? " This preset is archived; restore it before saving another version." : ""}</p>
      {fixedMismatch ? <p className="workbench-error">This preset has fixed windows for {units(selected.intensityUnits)}; the selected image uses {units(settings.intensityUnits)}.
        Choose an automatic-window preset or an image with matching intensity units.</p> : null}
      {!mappingReady ? <p>Map every preset channel to a different available image channel before applying settings.</p> : null}
      <details open={!mappingReady}>
        <summary>Channel mapping and saved versions</summary>
        <p>Mappings use channel indices. Confirm that each target channel represents the intended signal; channel colors do not establish biological identity.</p>
        <fieldset disabled={locked || loading}>{mapping.map((item, index) => <label key={item.source}>Preset channel {item.source + 1} → image channel
          <select value={item.target} onChange={(event) => { epoch.current++; setWarnings([]); setMessage("");
            const target = event.target.value === "" ? "" : Number(event.target.value);
            setMapping((old) => old.map((value, i) => i === index ? { ...value, target } : value));
          }}><option value="">Choose target channel…</option>{Array.from({ length: image.channels }, (_, channel) =>
            <option key={channel} value={channel}>Channel {channel + 1}</option>)}</select>
        </label>)}</fieldset>
        <label>Saved version<select disabled={locked || loading} value={version} onChange={(event) => setVersion(Number(event.target.value))}>
          <option value={0}>Latest version ({selected.latestVersion})</option>{Array.from({ length: selected.latestVersion }, (_, index) => index + 1).map((value) =>
            <option key={value} value={value}>Version {value}</option>)}
        </select></label>
        <p>{selected.notes || "No preset notes."}</p>
        <small>Saved {selected.createdAt} · project revision {selected.createdRevision}</small>
        <p className="workbench-project-path">SHA-256: {selected.hash}</p>
        <button type="button" className="cc-btn" disabled={locked || writeBlocked} onClick={() => void archive()}>{selected.archived ? "Restore archived preset" : "Archive preset"}</button>
      </details>
      <button type="button" className="cc-btn" disabled={locked || loading || !mappingReady || fixedMismatch} onClick={() => void applySettings()}>Apply settings to display draft</button>
      <p>Apply settings replaces the channel display draft. It does not render, change the camera or modify the analysis.</p>
    </> : null}
    <details><summary>Save current display settings</summary>
      <fieldset disabled={locked || loading || writeBlocked}>
        <label>Preset name<input maxLength={200} value={name} onChange={(event) => setName(event.target.value)} /></label>
        <label>Notes<textarea maxLength={4000} rows={3} value={notes} onChange={(event) => setNotes(event.target.value)} /></label>
        <div className="workbench-actions">
          <button type="button" className="cc-btn" disabled={!validSettings || !name.trim()} onClick={() => void save(false)}>Save as new preset</button>
          <button type="button" className="cc-btn" disabled={!validSettings || !name.trim() || !selected || selected.archived}
            onClick={() => void save(true)}>Save next version{summary ? ` of ${summary.name}` : ""}</button>
        </div>
      </fieldset>
      {writeBlocked ? <p>Finish scientific edits and stop background work before saving or archiving presets. Applying settings is local and remains available.</p> : null}
      {!validSettings ? <p>Complete valid channel windows and preview dimensions before saving these settings.</p> : null}
    </details>
    <details onToggle={(event) => setPortableOpen(event.currentTarget.open)}><summary>Import or export a preset file</summary>
      <p>Preset JSON stores display settings and their origin. Import creates a new local preset and does not apply or render it.</p>
      <div className="workbench-actions">
        <button type="button" className="cc-btn" disabled={locked || writeBlocked} onClick={() => void files.chooseImport((path) => {
          epoch.current++; setImportPath(path); setImportPreview(undefined); setError("");
        })}>Choose preset JSON…</button>
        <button type="button" className="cc-btn" disabled={locked || !importPath} onClick={() => void inspectImport()}>Preview preset import</button>
      </div>
      {importPath ? <p className="workbench-project-path">{importPath}</p> : null}
      {currentImport ? <section aria-label="Preset import preview">
        <p>{currentImport.preset.name} · {currentImport.preset.channels.length} channels · {units(currentImport.preset.intensityUnits)}
          {" · "}{currentImport.source.bytes.toLocaleString()} bytes</p>
        <p className="workbench-project-path">SHA-256: {currentImport.source.sha256}</p>
        {currentImport.notes.length ? <p>{currentImport.notes.join(" ")}</p> : null}
        <label>Imported preset name<input disabled={locked} maxLength={200} value={importName} onChange={(event) => setImportName(event.target.value)} /></label>
        <button type="button" className="cc-btn" disabled={locked || writeBlocked || !importName.trim()} onClick={() => void importPreset()}>Import as new preset</button>
      </section> : importPreview ? <p>The project changed. Preview the file again before importing.</p> : null}
      <button type="button" className="cc-btn" disabled={locked || loading || writeBlocked || !selected || !exportFormat}
        onClick={() => { if (selected && exportFormat) void files.exportPreset(exportFormat,
          { presetId: selected.id, version: selected.version, format: exportFormat.id }, selected.name); }}>Export selected preset version…</button>
      {selected ? <p>Exports {selected.name}, version {selected.version}; unsaved display changes are excluded.</p> : <p>Select a saved preset version to export it.</p>}
      {writeBlocked ? <p>Finish scientific edits and stop background work before importing or exporting preset files.</p> : null}
    </details>
    <div className="workbench-actions">
      <label className="workbench-inline"><input type="checkbox" disabled={locked} checked={includeArchived}
        onChange={(event) => setIncludeArchived(event.target.checked)} />Show archived presets</label>
      <button type="button" className="cc-btn" disabled={locked} onClick={() => setAttempt((value) => value + 1)}>Refresh selected preset</button>
    </div>
  </section>;
}
