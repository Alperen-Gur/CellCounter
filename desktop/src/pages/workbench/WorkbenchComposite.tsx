import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { WorkbenchImage } from "../../../../shared/workbench/protocol";
import type { CompositeArguments, CompositeCatalogue, CompositeChannel, CompositeExportArguments, CompositeExportFormat,
  CompositePreview, CompositeSelection, CompositeVolumeArguments, CompositeVolumeDisplay } from "../../../../shared/workbench/compositeProtocol";
import type { DisplayPresetFileActions, DisplayPresetMutation, DisplayPresetRef, DisplayPresetResolution } from "../../../../shared/workbench/displayPresetProtocol";
import WorkbenchDisplayPresets from "./WorkbenchDisplayPresets";
import { carriesDisplayRevision, type DisplayRevisionTransition } from "./displayRevision";

export interface CompositeVolumeState {
  imageId: string; sourceHash: string; revision: number; timeIndex: number; labelChannel: number;
  descriptor?: CompositeVolumeDisplay; settingsChanged: boolean; loading: boolean; error: string;
  completedAt?: number;
}

type Props = {
  image: WorkbenchImage; revision: number; selection: CompositeSelection; busy: boolean; exportBlocked: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  exportComposite: (format: CompositeExportFormat, args: CompositeExportArguments) => Promise<void>;
  mutatePreset: DisplayPresetMutation; presetFiles: DisplayPresetFileActions;
  displayTransition?: DisplayRevisionTransition;
  volume?: { labelChannel: number; available: boolean; onChange: (state: CompositeVolumeState) => void };
  children: (composite: CompositePreview | undefined) => ReactNode;
};
type ChannelDraft = Omit<CompositeChannel, "lower" | "upper"> & { lower: string; upper: string };
const COLORS = ["#00FFFF", "#FF00FF", "#FFFF00", "#00FF00", "#FF6600", "#6688FF", "#FF6699", "#FFFFFF"];
const defaults = (image: WorkbenchImage): ChannelDraft[] => Array.from({ length: Math.min(3, image.channels) }, (_, channel) =>
  ({ channel, color: COLORS[channel], enabled: true, lower: "", upper: "", gamma: 1, opacity: 1 }));
const format = (value: number | null | undefined) => value == null ? "—" : value.toLocaleString(undefined, { maximumFractionDigits: 4 });
type Resources = { catalogue: CompositeCatalogue; formats: CompositeExportFormat[] };
let resources: Resources | undefined;
let resourceRequest: Promise<Resources> | undefined;
const loadResources = (read: Props["read"]) => resources ? Promise.resolve(resources) : resourceRequest ??= Promise.all([
  read<CompositeCatalogue>("image.composite.catalogue"), read<{ formats: CompositeExportFormat[] }>("image.composite.export.catalogue"),
]).then(([catalogue, exported]) => resources = { catalogue, formats: exported.formats })
  .catch((cause) => { resourceRequest = undefined; throw cause; });

export default function WorkbenchComposite({ image, revision, selection, busy, exportBlocked, read, exportComposite, mutatePreset, presetFiles, displayTransition, volume, children }: Props) {
  const [open, setOpen] = useState(false);
  const [channels, setChannels] = useState(() => defaults(image));
  const [maxSize, setMaxSize] = useState(768);
  const [maxDimension, setMaxDimension] = useState(128);
  const [appliedPreset, setAppliedPreset] = useState<DisplayPresetRef>();
  const [shown, setShown] = useState(false);
  const [loadedResources, setLoadedResources] = useState(resources);
  const [attempt, setAttempt] = useState(0);
  const [resourceError, setResourceError] = useState("");
  const [rendered, setRendered] = useState<{ inputKey: string; draftKey: string; args: CompositeArguments; result: CompositePreview; completedAt: number }>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [volumeRendered, setVolumeRendered] = useState<{ inputKey: string; draftKey: string; args: CompositeVolumeArguments; result: CompositeVolumeDisplay; completedAt: number }>();
  const [volumeShown, setVolumeShown] = useState(false);
  const [volumeLoading, setVolumeLoading] = useState(false);
  const [volumeError, setVolumeError] = useState("");
  const epoch = useRef(0);
  const volumeEpoch = useRef(0);
  const latest = useRef(read); latest.current = read;
  const inputKey = JSON.stringify({ imageId: image.id, sourceHash: image.sourceHash, revision, selection });
  const previousRevision = carriesDisplayRevision(displayTransition, image, revision, displayTransition?.fromRevision)
    ? displayTransition!.fromRevision : undefined;
  const previousInputKey = previousRevision === undefined ? undefined : JSON.stringify({ imageId: image.id,
    sourceHash: image.sourceHash, revision: previousRevision, selection });
  const currentInput = useRef(inputKey); currentInput.current = inputKey;
  const draftKey = JSON.stringify({ channels, maxSize, presetRef: appliedPreset });
  const current = rendered && (rendered.inputKey === inputKey || (rendered.inputKey === previousInputKey &&
    rendered.completedAt <= displayTransition!.startedAt)) ? rendered : undefined;
  const changed = !!current && current.draftKey !== draftKey;
  const volumeTime = selection.target === "volume" ? selection.timeIndex : -1;
  const labelChannel = volume?.labelChannel ?? -1;
  const volumeInputKey = JSON.stringify({ imageId: image.id, sourceHash: image.sourceHash, revision,
    timeIndex: volumeTime, labelChannel, available: volume?.available ?? false });
  const previousVolumeInputKey = previousRevision === undefined ? undefined : JSON.stringify({ imageId: image.id,
    sourceHash: image.sourceHash, revision: previousRevision, timeIndex: volumeTime, labelChannel, available: volume?.available ?? false });
  const latestVolumeInput = useRef(volumeInputKey); latestVolumeInput.current = volumeInputKey;
  const volumeDraftKey = JSON.stringify({ channels, maxDimension, presetRef: appliedPreset });
  const currentVolume = volumeRendered && (volumeRendered.inputKey === volumeInputKey || (volumeRendered.inputKey === previousVolumeInputKey &&
    volumeRendered.completedAt <= displayTransition!.startedAt))
    ? volumeRendered : undefined;
  const volumeChanged = !!currentVolume && currentVolume.draftKey !== volumeDraftKey;
  const volumeCallback = useRef(volume?.onChange); volumeCallback.current = volume?.onChange;
  const volumeState = useMemo<CompositeVolumeState>(() => ({ imageId: image.id, sourceHash: image.sourceHash, revision,
    timeIndex: volumeTime, labelChannel, descriptor: volumeShown && volume?.available ? currentVolume?.result : undefined,
    settingsChanged: volumeChanged, loading: volumeLoading, error: volumeError, completedAt: currentVolume?.completedAt,
  }), [image.id, image.sourceHash, revision, volumeTime, labelChannel, volumeShown, volume?.available, currentVolume?.result, currentVolume?.completedAt, volumeChanged, volumeLoading, volumeError]);
  const exportFormat = loadedResources?.formats.find((item) => item.id === "composite-png");
  const channelLimit = loadedResources?.catalogue.limits.channels ?? 8;
  const sizeLimit = loadedResources?.catalogue.limits.maxSize ?? 2048;
  const dimensionLimit = loadedResources?.catalogue.limits.maxDimension ?? 128;
  const intensity = image.intensityUnits === "processed-source" ? "processed intensity" : "raw intensity";
  const invalidChannel = channels.some((item) => (item.lower.trim() === "") !== (item.upper.trim() === "") ||
    (item.lower.trim() !== "" && (!Number.isFinite(Number(item.lower)) || !Number.isFinite(Number(item.upper)) || Number(item.lower) >= Number(item.upper))) ||
    !Number.isFinite(item.gamma) || item.gamma < .05 || item.gamma > 20 || !Number.isFinite(item.opacity) || item.opacity < 0 || item.opacity > 1);
  const validChannels = channels.length > 0 && channels.length <= channelLimit && !invalidChannel;
  const valid = validChannels && Number.isInteger(maxSize) && maxSize >= 64 && maxSize <= sizeLimit;
  const validVolume = !!volume?.available && selection.target === "volume" && validChannels && Number.isInteger(maxDimension) && maxDimension >= 16 && maxDimension <= dimensionLimit;
  const available = Array.from({ length: image.channels }, (_, index) => index).filter((channel) => !channels.some((item) => item.channel === channel));

  useEffect(() => {
    epoch.current++; setChannels(defaults(image)); setAppliedPreset(undefined); setRendered(undefined); setShown(false); setLoading(false); setError("");
    volumeEpoch.current++; setVolumeRendered(undefined); setVolumeShown(false); setVolumeLoading(false); setVolumeError("");
    return () => { epoch.current++; volumeEpoch.current++; };
  }, [image.id]);
  useEffect(() => {
    epoch.current++; setLoading(false); setError("");
    if (previousInputKey) setRendered((old) => old?.inputKey === previousInputKey && old.completedAt <= displayTransition!.startedAt ? { ...old, inputKey } : old);
  }, [inputKey, previousInputKey]);
  useEffect(() => {
    volumeEpoch.current++; setVolumeLoading(false); setVolumeError("");
    if (previousVolumeInputKey) setVolumeRendered((old) => old?.inputKey === previousVolumeInputKey && old.completedAt <= displayTransition!.startedAt ? { ...old, inputKey: volumeInputKey } : old);
  }, [volumeInputKey, previousVolumeInputKey]);
  useEffect(() => { volumeCallback.current?.(volumeState); }, [volumeState]);
  useEffect(() => {
    if (!open || busy || loadedResources) return;
    let active = true; setResourceError("");
    void loadResources(latest.current).then((value) => { if (active) setLoadedResources(value); })
      .catch((cause) => { if (active) setResourceError(String(cause)); });
    return () => { active = false; };
  }, [open, busy, loadedResources, attempt]);
  const update = (index: number, change: Partial<ChannelDraft>) => {
    setAppliedPreset(undefined);
    epoch.current++; setLoading(false); setError("");
    volumeEpoch.current++; setVolumeLoading(false); setVolumeError("");
    setChannels((old) => old.map((item, itemIndex) => itemIndex === index ? { ...item, ...change } : item));
  };
  const channelArguments = (): CompositeChannel[] => channels.map(({ lower, upper, ...item }) => ({
    ...item, ...(lower.trim() === "" ? {} : { lower: Number(lower), upper: Number(upper) }),
  }));
  const applyPreset = (resolved: DisplayPresetResolution) => {
    epoch.current++; volumeEpoch.current++; setLoading(false); setVolumeLoading(false); setError(""); setVolumeError("");
    setChannels(resolved.settings.channels.map((item) => ({ ...item, lower: item.lower === undefined ? "" : String(item.lower),
      upper: item.upper === undefined ? "" : String(item.upper) })));
    setMaxSize(resolved.settings.maxSize); setMaxDimension(resolved.settings.maxDimension); setAppliedPreset(resolved.presetRef);
  };
  const render = async () => {
    if (!valid || busy) return;
    const generation = ++epoch.current; setLoading(true); setError("");
    const args: CompositeArguments = { imageId: image.id, ...selection, maxSize, channels: channelArguments(), ...(appliedPreset ? { presetRef: appliedPreset } : {}) };
    try {
      const result = await read<CompositePreview>("image.composite.preview", { ...args });
      if (generation !== epoch.current || currentInput.current !== inputKey) return;
      const width = selection.target === "volume" && selection.plane === "yz" ? image.height : image.width;
      const height = selection.target === "volume" && selection.plane !== "xy" ? image.zCount || 1 : image.height;
      if (result.imageId !== image.id || result.sourceHash !== image.sourceHash || result.width !== width || result.height !== height)
        throw new Error("The composite no longer matches this source image grid. Refresh the project and render the display again.");
      setRendered({ inputKey, draftKey, args, result, completedAt: performance.now() }); setShown(true);
    } catch (cause) { if (generation === epoch.current) setError(cause instanceof Error ? cause.message : String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  const renderVolume = async () => {
    if (!validVolume || busy || !volume || selection.target !== "volume") return;
    const generation = ++volumeEpoch.current; setVolumeLoading(true); setVolumeError("");
    const args: CompositeVolumeArguments = { imageId: image.id, timeIndex: selection.timeIndex,
      channels: channelArguments(), maxDimension, labelChannel: volume.labelChannel, ...(appliedPreset ? { presetRef: appliedPreset } : {}) };
    try {
      const result = await read<CompositeVolumeDisplay>("image.composite.volume", { ...args });
      if (generation !== volumeEpoch.current || latestVolumeInput.current !== volumeInputKey) return;
      if (result.imageId !== image.id || result.sourceHash !== image.sourceHash || result.timeIndex !== args.timeIndex ||
        result.labelChannel !== args.labelChannel || result.displayKind !== "composite" || result.components !== 4 ||
        result.originalDimensions[0] !== image.width || result.originalDimensions[1] !== image.height || result.originalDimensions[2] !== (image.zCount || 1))
        throw new Error("The 3D composite no longer matches this source frame and analysis channel. Select the current frame and render again.");
      if (result.labelStatus === "current" && (!result.labelSource || result.labelSource.channel !== args.labelChannel || result.labelSource.timeIndex !== args.timeIndex))
        throw new Error("The 3D composite labels do not match the selected analysis channel and time point.");
      setVolumeRendered({ inputKey: volumeInputKey, draftKey: volumeDraftKey, args, result, completedAt: performance.now() }); setVolumeShown(true);
    } catch (cause) { if (generation === volumeEpoch.current) setVolumeError(cause instanceof Error ? cause.message : String(cause)); }
    finally { if (generation === volumeEpoch.current) setVolumeLoading(false); }
  };
  return <>
    <details className="workbench-composite-controls" onToggle={(event) => setOpen(event.currentTarget.open)}>
      <summary>Channel display · {shown && current ? (volume ? "slice composite shown" : "composite shown") : "analysis channel shown"}</summary>
      <p>Colors, windows and blending affect this image display only. Segmentation, source intensities and saved measurements use their analysis settings.</p>
      {selection.target === "volume" ? <p>{selection.plane.toUpperCase()} slice {selection.index + 1} · time {selection.timeIndex + 1}.
        {volume ? ` These channel settings can render the source slice or the full 3D frame. Saved masks remain on analysis channel ${volume.labelChannel + 1}.`
          : "These settings affect the source slice display."}</p> : null}
      {error ? <p className="workbench-error" role="alert">{error}</p> : null}
      {resourceError ? <p className="workbench-error" role="alert">{resourceError} <button type="button" className="cc-btn"
        onClick={() => setAttempt((value) => value + 1)}>Retry display resources</button></p> : null}
      <WorkbenchDisplayPresets image={image} revision={revision} active={open} busy={busy || loading || volumeLoading}
        writeBlocked={exportBlocked} read={read} mutate={mutatePreset} files={presetFiles} apply={applyPreset}
        settings={{ channels: channelArguments(), maxSize, maxDimension, intensityUnits: image.intensityUnits ?? "raw-source" }}
        validSettings={valid && Number.isInteger(maxDimension) && maxDimension >= 16 && maxDimension <= dimensionLimit} />
      {appliedPreset ? <p>Display draft: {appliedPreset.name} · version {appliedPreset.version}. Changing a control detaches this draft from the preset.</p> : null}
      <fieldset disabled={busy || loading || volumeLoading}>
        <ul className="workbench-composite-channels">{channels.map((item, index) => <li key={item.channel}>
          <div className="workbench-composite-channel-heading">
            <label className="workbench-inline"><input type="checkbox" checked={item.enabled}
              onChange={(event) => update(index, { enabled: event.target.checked })} />Channel {item.channel + 1}</label>
            <label>Color<input type="color" aria-label={`Channel ${item.channel + 1} display color`} value={item.color}
              onChange={(event) => update(index, { color: event.target.value })} /></label>
            <button type="button" className="cc-btn" disabled={channels.length <= 1} onClick={() => { setAppliedPreset(undefined); setChannels((old) => old.filter((_, i) => i !== index)); }}
              aria-label={`Remove channel ${item.channel + 1} from composite`}>Remove</button>
          </div>
          <div className="workbench-composite-channel-fields">
            <label>Lower ({intensity})<input type="number" step="any" value={item.lower} placeholder="Automatic"
              onChange={(event) => update(index, { lower: event.target.value })} /></label>
            <label>Upper ({intensity})<input type="number" step="any" value={item.upper} placeholder="Automatic"
              onChange={(event) => update(index, { upper: event.target.value })} /></label>
            <label>Gamma<input type="number" min=".05" max="20" step=".05" value={item.gamma}
              onChange={(event) => update(index, { gamma: Number(event.target.value) })} /></label>
            <label>Opacity<input type="number" min="0" max="1" step=".05" value={item.opacity}
              onChange={(event) => update(index, { opacity: Number(event.target.value) })} /></label>
          </div>
          {item.lower !== "" || item.upper !== "" ? <button type="button" className="cc-btn" onClick={() => update(index, { lower: "", upper: "" })}>Use automatic window for channel {item.channel + 1}</button> : null}
        </li>)}</ul>
        {available.length && channels.length < channelLimit ? <label>Add display channel<select value="" onChange={(event) => {
          if (event.target.value === "") return;
          const channel = Number(event.target.value);
          setAppliedPreset(undefined);
          const palette = loadedResources?.catalogue.defaultColors?.length ? loadedResources.catalogue.defaultColors : COLORS;
          setChannels((old) => [...old, { channel, color: palette[channel % palette.length], enabled: true, lower: "", upper: "", gamma: 1, opacity: 1 }]);
        }}><option value="">Choose a channel…</option>{available.map((channel) => <option key={channel} value={channel}>Channel {channel + 1}</option>)}</select></label> : null}
        <p>Leave both window fields empty for automatic supported-sample min/max. Gamma above 1 brightens the display. Up to {channelLimit} channels are added and clamped to the display range.</p>
        {!validChannels ? <p className="workbench-error">Use both lower and upper values, with lower below upper, or clear both. Gamma must be 0.05–20 and opacity 0–1.</p> : null}
        <label>Maximum {volume ? "slice " : ""}preview dimension (pixels)<input type="number" min="64" max={sizeLimit} step="1" value={maxSize}
          onChange={(event) => { setAppliedPreset(undefined); setMaxSize(Number(event.target.value)); }} /></label>
        <div className="workbench-actions">
          <button type="button" className="cc-btn" disabled={!valid} onClick={() => void render()}>{loading ? "Rendering slice…" : volume ? "Render slice composite" : "Render channel display"}</button>
          <button type="button" className="cc-btn" disabled={!shown} onClick={() => setShown(false)}>{volume ? "Show analysis channel on slice" : "Show analysis channel"}</button>
          {!shown && current ? <button type="button" className="cc-btn" onClick={() => setShown(true)}>{volume ? "Show last rendered slice composite" : "Show last rendered composite"}</button> : null}
        </div>
        {!Number.isInteger(maxSize) || maxSize < 64 || maxSize > sizeLimit ? <p className="workbench-error">The slice preview dimension must be 64–{sizeLimit} pixels.</p> : null}
        {volume && selection.target === "volume" ? <section aria-label="3D composite display">
          <h4>3D channel display</h4>
          <label>Maximum 3D preview dimension (voxels)<input type="number" min="16" max={dimensionLimit} step="1" value={maxDimension}
            onChange={(event) => { setAppliedPreset(undefined); setMaxDimension(Number(event.target.value)); }} /></label>
          <p>Automatic windows use the full supported volume. Slice windows use the selected slice, so their brightness can differ. Manual windows apply the same limits to both.</p>
          {!volume.available ? <p>Load the saved frame and finish the segmentation preview before rendering its 3D composite.</p> : null}
          {!Number.isInteger(maxDimension) || maxDimension < 16 || maxDimension > dimensionLimit ? <p className="workbench-error">The 3D preview dimension must be 16–{dimensionLimit} voxels.</p> : null}
          <div className="workbench-actions">
            <button type="button" className="cc-btn" disabled={!validVolume} onClick={() => void renderVolume()}>{volumeLoading ? "Rendering 3D composite…" : "Render 3D composite"}</button>
            <button type="button" className="cc-btn" disabled={!volumeShown} onClick={() => setVolumeShown(false)}>Show analysis channel in 3D</button>
            {!volumeShown && currentVolume ? <button type="button" className="cc-btn" onClick={() => setVolumeShown(true)}>Show last rendered 3D composite</button> : null}
          </div>
        </section> : null}
      </fieldset>
      {changed ? <p role="status">Display settings changed. The rendered image still uses the previous settings. Render again before exporting.</p> : null}
      {shown && !current ? <p role="status">The image or slice changed. Render the composite for this selection; the analysis channel is shown meanwhile.</p> : null}
      {volumeError ? <p className="workbench-error" role="alert">3D display: {volumeError}</p> : null}
      {volumeLoading ? <p role="status">Preparing the bounded 3D composite. Existing display settings remain visible until it is ready.</p> : null}
      {volumeChanged ? <p role="status">3D display settings changed. The 3D renderer still uses the previously rendered settings.</p> : null}
      {volumeShown && !currentVolume ? <p role="status">The source frame, saved revision or analysis channel changed. Render a new 3D composite for this selection.</p> : null}
      {currentVolume ? <details><summary>Rendered 3D ranges and provenance</summary>
        <p>{currentVolume.result.dimensions.join(" × ")} display voxels from {currentVolume.result.originalDimensions.join(" × ")} source voxels at time {currentVolume.result.timeIndex + 1}.</p>
        <p>{currentVolume.result.labelStatus === "current" ? `Saved masks: analysis channel ${(currentVolume.result.labelChannel ?? 0) + 1}, revision ${currentVolume.result.labelSource?.analysisRevision}.`
          : "No saved masks are available on the selected analysis channel."}</p>
        <ul>{currentVolume.result.channels.map((item) => <li key={item.channel}>Channel {item.channel + 1} · {item.enabled ? "visible" : "hidden"}
          {" · "}{item.windowMode} window {format(item.lower)}–{format(item.upper)}
          {item.constantRange ? " · constant range displayed black" : ""} · {format(item.supportedSamples)} supported voxels</li>)}</ul>
        <p>Source SHA-256: {currentVolume.result.sourceHash}</p>
        {currentVolume.result.notes.length ? <p>{currentVolume.result.notes.join(" ")}</p> : null}
      </details> : null}
      {current ? <details><summary>Rendered intensity ranges and provenance</summary>
        <p>{current.result.previewWidth} × {current.result.previewHeight} display pixels from {current.result.width} × {current.result.height} source samples.</p>
        <ul>{current.result.channels.map((item) => <li key={item.channel}>Channel {item.channel + 1} · {item.enabled ? "visible" : "hidden"}
          {" · "}{item.windowMode} window {format(item.lower)}–{format(item.upper)}
          {item.constantRange ? " · constant range displayed black" : ""} · {format(item.supportedSamples)} supported samples</li>)}</ul>
        <p>Source SHA-256: {current.result.sourceHash}</p>
        {current.result.notes.length ? <p>{current.result.notes.join(" ")}</p> : null}
      </details> : null}
      <button type="button" className="cc-btn" disabled={busy || loading || volumeLoading || exportBlocked || !current || changed || !exportFormat}
        onClick={() => { if (current && exportFormat && !changed) void exportComposite(exportFormat, { ...current.args, format: exportFormat.id }); }}>{volume ? "Save rendered slice composite…" : "Save rendered composite…"}</button>
      {exportBlocked ? <p>Finish scientific edits and stop background work before saving the composite export.</p> : null}
      <p>The PNG export retains the rendered {volume ? "source slice" : "image"} settings and source provenance.
        {volume ? " It exports the source slice, not a screenshot of the 3D view." : " It contains display pixels; scientific source data remain available in image exports."}</p>
    </details>
    {shown && current && changed ? <p className="workbench-display-notice">Composite shown with previous display settings.</p> : null}
    {shown && current ? <p className="workbench-display-notice">Composite display · masks and measurements remain on the analysis channel.</p> : null}
    {children(shown ? current?.result : undefined)}
  </>;
}
