import { useState } from "react";
import WorkbenchCatalogueBrowser, { useCatalogueEntries, useCataloguePins } from "./WorkbenchCatalogueBrowser";
import type { AnalysisParameters } from "../../../../shared/workbench/protocol";
import type { ParameterSpec, ParameterValue } from "../../../../shared/workbench/extensionProtocol";
import type { AssaySeriesActions, AssaySeriesExportFormat, AssaySeriesOutput, AssaySeriesRun } from "../../../../shared/workbench/assaySeriesProtocol";
import WorkbenchImageSelector, { useWorkbenchImage } from "./WorkbenchImageSelector";
import PluginParameters from "./PluginParameters";
import ScientificOutput from "./ScientificOutput";

type FrameDraft = { key: string; imageId: string; missing: boolean; missingReason: string; time: string;
  channel: number; zProjection: AnalysisParameters["zProjection"]; timeIndex: number; cropped: boolean; x: number; y: number; width: number; height: number };
type Catalogue = { definitionSchema: { properties: { parameters: { properties: Record<string, ParameterSpec>; required: string[] } } }; limits: { frames: number; pixelsPerFrame: number; totalPixels: number }; notes: string[] };
type Props = { imageId: string; revision: number; busy: boolean; writeBlocked: boolean; sourceParameters: Pick<AnalysisParameters, "channel" | "zProjection">;
  actions: AssaySeriesActions; read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T> };
const format = (value: number | null | undefined) => value == null ? "—" : value.toLocaleString(undefined, { maximumSignificantDigits: 6 });
const makeFrame = (imageId = "", parameters: Pick<AnalysisParameters, "channel" | "zProjection"> = { channel: 0, zProjection: "max" }): FrameDraft => ({ key: crypto.randomUUID(), imageId, ...parameters,
  missing: false, missingReason: "", time: "", timeIndex: 0, cropped: false, x: 0, y: 0, width: 1, height: 1 });

function FrameEditor({ frame, index, baseline, disabled, update, move, remove, onBaseline, canUp, canDown }: { frame: FrameDraft; index: number; baseline: boolean; disabled: boolean;
  update: (changes: Partial<FrameDraft>) => void; move: (offset: number) => void; remove: () => void; onBaseline: () => void; canUp: boolean; canDown: boolean }) {
  const image = useWorkbenchImage(frame.imageId);
  return <fieldset disabled={disabled}><legend>Observation {index + 1}{baseline ? " · baseline" : ""}</legend>
    <div className="workbench-editor-grid"><label>Observed time (seconds; blank means unknown)<input type="number" step="any" min={-1e12} max={1e12} value={frame.time} onChange={event => update({ time: event.target.value })} /></label>
      <label><input type="checkbox" checked={frame.missing} onChange={event => update({ missing: event.target.checked })} /> Missing observation</label></div>
    {frame.missing ? <label>Missing-observation reason<input value={frame.missingReason} maxLength={1000} onChange={event => update({ missingReason: event.target.value })} /></label> : <>
      <WorkbenchImageSelector label={`Source for observation ${index + 1}`} selectedIds={frame.imageId ? [frame.imageId] : []} disabled={disabled} onChange={ids => update({ imageId: ids[0] ?? "", channel: 0, timeIndex: 0 })} />
      <div className="workbench-editor-grid"><label>Acquired channel<select value={frame.channel} onChange={event => update({ channel: Number(event.target.value) })}>{Array.from({ length: image?.channels ?? 1 }, (_, channel) => <option key={channel} value={channel}>{image?.channelNames?.[channel] || `Channel ${channel + 1}`}</option>)}</select></label>
        <label>Acquisition time-point index (starting at 1)<input type="number" min={1} max={image?.timeCount ?? 1} step={1} value={frame.timeIndex + 1} onChange={event => update({ timeIndex: Number(event.target.value) - 1 })} /></label>
        <label>Z projection<select value={frame.zProjection} onChange={event => update({ zProjection: event.target.value as FrameDraft["zProjection"] })}><option value="max">Maximum</option><option value="mean">Mean</option><option value="middle">Middle plane</option></select></label></div>
      <label><input type="checkbox" checked={frame.cropped} onChange={event => update({ cropped: event.target.checked })} /> Explicit source region</label>
      {frame.cropped ? <div className="workbench-editor-grid">{(["x", "y", "width", "height"] as const).map(key => <label key={key}>{key === "x" ? "Left X (source pixels)" : key === "y" ? "Top Y (source pixels)" : `${key === "width" ? "Width" : "Height"} (source pixels)`}<input type="number" min={key === "x" || key === "y" ? 0 : 1} step={1} value={frame[key]} onChange={event => update({ [key]: Number(event.target.value) })} /></label>)}
        <button className="cc-btn" disabled={!image} onClick={() => image && update({ x: 0, y: 0, width: image.width, height: image.height })}>Use full source dimensions</button></div> : null}
    </>}
    <div className="workbench-actions"><button className="cc-btn" disabled={baseline} onClick={onBaseline}>Use as baseline</button><button className="cc-btn" disabled={!canUp} onClick={() => move(-1)}>Move earlier</button><button className="cc-btn" disabled={!canDown} onClick={() => move(1)}>Move later</button><button className="cc-btn" onClick={remove}>Remove observation</button></div>
  </fieldset>;
}

export function AssaySeriesResults({ output }: { output: AssaySeriesOutput }) {
  const [page, setPage] = useState(0);
  return <><p>Baseline observation {output.baseline.index + 1}: {output.baseline.status}. Common acquired support: {output.commonSupport.samples.toLocaleString()} samples ({format(output.commonSupport.fraction * 100)}% of the selected region).</p>
    <p>Specimen status: {output.specimen.status}{output.specimen.specimen ? ` · ${output.specimen.specimen.name}` : ""}. {output.specimen.inferentiallyEligible ? "One coherent biological specimen, with repeated observations." : "This series is descriptive and cannot supply an eligible biological replicate until assignments and exclusions are coherent."}</p>
    <div className="workbench-table"><table><thead><tr><th>Observation</th><th>Time (s)</th><th>Source / status</th><th>Gap area (pixels²)</th><th>Gap area (µm²)</th><th>Closure fraction</th><th>Gap change (pixels²)</th></tr></thead><tbody>{output.frames.slice(page * 25, (page + 1) * 25).map(row => <tr key={row.index}><th>{row.index + 1}{row.index === output.baseline.index ? " · baseline" : ""}</th><td>{format(row.timeSeconds)}</td><td>{row.name ?? row.imageId ?? "Missing"} · {row.status}{row.missingReason ? ` · ${row.missingReason}` : ""}</td><td>{format(row.gapAreaPx)}</td><td>{format(row.gapAreaUm2)}</td><td>{format(row.closureFraction)}</td><td>{format(row.gapAreaChangePx)}</td></tr>)}</tbody></table></div>
    <div className="workbench-actions"><button className="cc-btn" disabled={!page} onClick={() => setPage(value => value - 1)}>Previous observations</button><button className="cc-btn" disabled={(page + 1) * 25 >= output.frames.length} onClick={() => setPage(value => value + 1)}>Next observations</button></div>
    <h4>Descriptive rates</h4><div className="workbench-table"><table><thead><tr><th>Outcome</th><th>Slope per second</th><th>Units</th><th>R²</th><th>Observations used</th></tr></thead><tbody>{(["gapAreaPx", "gapAreaUm2", "closureFraction"] as const).map(key => <tr key={key}><th>{key === "gapAreaPx" ? "Gap area in pixels" : key === "gapAreaUm2" ? "Calibrated gap area" : "Normalized closure"}</th><td>{format(output.rates[key].slopePerSecond)}</td><td>{output.rates.units[key]}</td><td>{format(output.rates[key].rSquared)}</td><td>{output.rates[key].usedIndices.map(index => index + 1).join(", ") || "None"}</td></tr>)}</tbody></table></div>
    <p>Area change per second is not cell migration speed. Negative closure remains visible; unknown timestamps and missing values remain unmeasured.</p>
    <details><summary>Rate intervals, omitted observations and acquired-support details</summary><ScientificOutput output={{ commonSupport: output.commonSupport, rates: output.rates, notes: output.notes }} /></details></>;
}

export default function WorkbenchAssaySeries({ imageId, revision, busy, writeBlocked, sourceParameters, actions, read }: Props) {
  const [catalogue, setCatalogue] = useState<Catalogue>();
  const [formats, setFormats] = useState<AssaySeriesExportFormat[]>([]), [formatId, setFormatId] = useState<AssaySeriesExportFormat["id"]>("results-json");
  const [error, setError] = useState("");
  const [name, setName] = useState("Scratch-wound time series");
  const [frames, setFrames] = useState<FrameDraft[]>(() => [makeFrame(imageId, sourceParameters)]);
  const [baseline, setBaseline] = useState(() => frames[0].key);
  const [page, setPage] = useState(0);
  const [parameters, setParameters] = useState<Record<string, ParameterValue>>({});
  const [preview, setPreview] = useState<{ key: string; revision: number; output: AssaySeriesOutput }>();
  const runs = useCatalogueEntries<AssaySeriesRun>("assaySeriesRuns");
  const [runId, setRunId] = useState("");
  const pinError = useCataloguePins([{ catalogue: "assaySeriesRuns", entryId: runId }]);
  const [result, setResult] = useState<{ run: AssaySeriesRun; output: AssaySeriesOutput; revision: number }>();
  const [replacement, setReplacement] = useState<{ runId: string; revision: number; output: AssaySeriesOutput }>();
  const perform = (action: () => Promise<void>) => actions.run(async () => { setError(""); try { await action(); } catch (cause) { setError(String(cause)); } });
  const args = { assay: "scratch_wound", name: name.trim(), baselineIndex: frames.findIndex(frame => frame.key === baseline), parameters,
    frames: frames.map(frame => ({ timeSeconds: frame.time.trim() ? Number(frame.time) : null, ...(frame.missing ? { missingReason: frame.missingReason.trim() }
      : { imageId: frame.imageId, sourceParameters: { channel: frame.channel, zProjection: frame.zProjection }, timeIndex: frame.timeIndex,
        ...(frame.cropped ? { region: { x: frame.x, y: frame.y, width: frame.width, height: frame.height } } : {}) }) })) };
  const key = JSON.stringify(args);
  const currentPreview = preview?.key === key && preview.revision === revision ? preview.output : undefined;
  const currentResult = result?.run.runId === runId ? result : undefined;
  const currentReplacement = replacement?.runId === runId && replacement.revision === revision ? replacement.output : undefined;
  const selectedFormat = formats.find(format => format.id === formatId);
  const invalid = !name.trim() || frames.length < 2 || args.baselineIndex < 0 || frames.every(frame => frame.missing) || frames.some(frame =>
    frame.time.trim() && (!Number.isFinite(Number(frame.time)) || Math.abs(Number(frame.time)) > 1e12) || frame.missing && !frame.missingReason.trim() || !frame.missing && (!frame.imageId || frame.cropped && (![frame.x, frame.y, frame.width, frame.height].every(Number.isInteger) || frame.x < 0 || frame.y < 0 || frame.width < 1 || frame.height < 1)));
  const accept = (value: { run: AssaySeriesRun; output: AssaySeriesOutput }) => { setResult({ ...value, revision: value.run.revision }); setRunId(value.run.runId); setPreview(undefined); setReplacement(undefined); };
  return <details><summary>Scratch-wound time series</summary><p>Measure aligned observations over the same acquired source region. Set observed times explicitly; acquisition indices and file order do not supply elapsed time.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    <WorkbenchCatalogueBrowser catalogues={["assaySeriesRuns"]} title="Browse all retained time series" disabled={busy} onChoose={(_, entry) => setRunId(String(entry.runId))} />
    <button className="cc-btn" disabled={busy} onClick={() => void perform(async () => { setCatalogue(await read<Catalogue>("assay.series.catalogue")); setFormats((await read<{ formats: AssaySeriesExportFormat[] }>("assay.series.export.catalogue")).formats); })}>Read series controls and export options</button>
    <details><summary>Define observations and preview</summary><fieldset disabled={busy}><legend>Ordered observations</legend><label>Series name<input value={name} maxLength={200} onChange={event => setName(event.target.value)} /></label>
      {frames.slice(page * 10, (page + 1) * 10).map((frame, offset) => { const index = page * 10 + offset; return <FrameEditor key={frame.key} frame={frame} index={index} baseline={frame.key === baseline} disabled={busy}
        update={changes => setFrames(old => old.map(item => item.key === frame.key ? { ...item, ...changes } : item))} canUp={index > 0} canDown={index < frames.length - 1}
        onBaseline={() => setBaseline(frame.key)} move={direction => setFrames(old => { const next = [...old]; [next[index], next[index + direction]] = [next[index + direction], next[index]]; return next; })}
        remove={() => { setFrames(old => old.filter(value => value.key !== frame.key)); if (baseline === frame.key) setBaseline(""); setPage(Math.min(page, Math.max(0, Math.ceil((frames.length - 1) / 10) - 1))); }} />; })}
      <div className="workbench-actions"><button className="cc-btn" disabled={!page} onClick={() => setPage(value => value - 1)}>Previous observation drafts</button><button className="cc-btn" disabled={(page + 1) * 10 >= frames.length} onClick={() => setPage(value => value + 1)}>Next observation drafts</button><button className="cc-btn" disabled={frames.length >= (catalogue?.limits.frames ?? 128)} onClick={() => { setFrames(old => [...old, makeFrame()]); setPage(Math.floor(frames.length / 10)); }}>Add observation</button></div>
      <p>{frames.length} observations · {args.baselineIndex < 0 ? "Choose a baseline observation." : `Baseline: observation ${args.baselineIndex + 1}.`} Known times must increase in observation order. Missing observations are retained, not interpolated.</p>
      {catalogue ? <><PluginParameters schema={catalogue.definitionSchema.properties.parameters} values={parameters} onChange={setParameters} /><p>Limits: {catalogue.limits.frames} observations, {catalogue.limits.pixelsPerFrame.toLocaleString()} pixels per frame, {catalogue.limits.totalPixels.toLocaleString()} pixels total.</p></> : <p>Read series controls above before previewing.</p>}
      <button className="cc-btn" disabled={!!invalid || !catalogue} onClick={() => void perform(async () => { const value = await read<{ preview: AssaySeriesOutput }>("assay.series.preview", args); setPreview({ key, revision, output: value.preview }); })}>Preview series and rates</button></fieldset>
      {preview && !currentPreview ? <p>Observation settings or project inputs changed. Preview again before retaining the series.</p> : null}
      {currentPreview ? <><AssaySeriesResults key={currentPreview.previewFingerprint} output={currentPreview} /><button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void actions.mutate<{ run: AssaySeriesRun; output: AssaySeriesOutput }>("assay.series.run", { ...args, previewFingerprint: currentPreview.previewFingerprint }, accept)}>Save previewed series</button></> : null}
    </details>
    <details><summary>Saved series and replacement results</summary><fieldset disabled={busy}><label>Saved series<select value={runId} onChange={event => { setRunId(event.target.value); setReplacement(undefined); }}><option value="">Choose a retained series</option>{runs.map(run => <option key={run.runId} value={run.runId}>{run.name} · {run.measuredCount}/{run.frameCount} measured · r{run.revision}</option>)}</select></label>
      <button className="cc-btn" disabled={!runId} onClick={() => void perform(async () => { const value = await read<{ run: AssaySeriesRun; output: AssaySeriesOutput }>("assay.series.results", { runId }); setResult({ ...value, revision }); })}>Read retained series</button></fieldset>
      {currentResult ? <><p>{currentResult.run.outputsCurrent && currentResult.revision === revision ? "Retained inputs are current." : "Retained historical result; read again to check current input status."}{currentResult.run.predecessorRunId ? ` Replaces ${currentResult.run.predecessorRunId}.` : ""}</p><AssaySeriesResults key={currentResult.output.previewFingerprint} output={currentResult.output} />
        <button className="cc-btn" disabled={busy} onClick={() => void perform(async () => setReplacement({ runId, revision, output: (await read<{ preview: AssaySeriesOutput }>("assay.series.recompute.preview", { runId })).preview }))}>Preview replacement from current inputs</button>
        {replacement && !currentReplacement ? <p>Project inputs changed. Preview replacement again before saving.</p> : null}
        {currentReplacement ? <><AssaySeriesResults key={currentReplacement.previewFingerprint} output={currentReplacement} /><button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void actions.mutate<{ run: AssaySeriesRun; output: AssaySeriesOutput }>("assay.series.recompute.run", { runId, previewFingerprint: currentReplacement.previewFingerprint }, accept)}>Save linked replacement series</button></> : null}
        <fieldset disabled={busy || writeBlocked}><label>Report format<select value={formatId} onChange={event => setFormatId(event.target.value as typeof formatId)}>{formats.map(format => <option key={format.id} value={format.id}>{format.name}</option>)}</select></label><button className="cc-btn" disabled={!selectedFormat} onClick={() => selectedFormat && void actions.exportReport(selectedFormat, currentResult.run)}>Export retained series…</button></fieldset>
      </> : null}
    </details>
  </details>;
}
