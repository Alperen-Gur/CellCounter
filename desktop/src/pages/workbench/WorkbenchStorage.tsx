import { useCataloguePins } from "./WorkbenchCatalogueBrowser";
import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { openWorkbench } from "../../components/workbenchNavigation";
import type { WorkbenchTaskId } from "../../../../shared/workbench/navigation";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import type { StorageActions, StorageExportFormat, StorageRegion, TiledAnalysis, TiledObject, TiledPlan } from "../../../../shared/workbench/storageProtocol";
import WorkbenchZarrSelection, { WorkbenchZarrRegion } from "./WorkbenchZarrSelection";
import { activeJobWorker, workerTargetId, workerTargetKind } from "../../../../shared/workbench/workerProtocol";

type Props = { snapshot: ProjectSnapshot; busy: boolean; writeBlocked: boolean; actions: StorageActions;
  analysisTarget: HTMLElement | null; measurementsTarget: HTMLElement | null; exportTarget: HTMLElement | null; activeTask: WorkbenchTaskId;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T> };
const fmt = (value: number | null | undefined) => value == null ? "—" : value.toLocaleString(undefined, { maximumFractionDigits: 4 });
const regionFields = ["x", "y", "width", "height"] as const;

export default function WorkbenchStorage({ snapshot, busy, writeBlocked, actions, read, analysisTarget, measurementsTarget, exportTarget, activeTask }: Props) {
  const sources = snapshot.zarrSources ?? [];
  const analyses = snapshot.tiledAnalyses ?? [];
  const [sourceId, setSourceId] = useState("");
  const [arrayPath, setArrayPath] = useState("");
  const [timeIndex, setTimeIndex] = useState(0);
  const [channel, setChannel] = useState(0);
  const [zIndex, setZIndex] = useState(0);
  const [region, setRegion] = useState<StorageRegion>({ x: 0, y: 0, width: 512, height: 512 });
  const [imageName, setImageName] = useState("");
  const [overview, setOverview] = useState<{ key: string; dataUrl: string; width: number; height: number; notes: string[] }>();
  const [method, setMethod] = useState<"otsu" | "manual">("otsu");
  const [threshold, setThreshold] = useState(0);
  const [polarity, setPolarity] = useState<"bright" | "dark">("bright");
  const [connectivity, setConnectivity] = useState<4 | 8>(8);
  const [minAreaPx, setMinAreaPx] = useState(9);
  const [tileSize, setTileSize] = useState(512);
  const [halo, setHalo] = useState(1);
  const [analysisName, setAnalysisName] = useState("");
  const [plan, setPlan] = useState<{ key: string; revision: number; value: TiledPlan }>();
  const [analysisId, setAnalysisId] = useState("");
  const [formats, setFormats] = useState<StorageExportFormat[]>([]);
  const [objectPage, setObjectPage] = useState<{ analysisId: string; objects: TiledObject[]; offset: number; total: number; nextOffset: number | null; revision: number }>();
  const [tilePage, setTilePage] = useState<{ analysisId: string; tiles: { index: number; x: number; y: number; width: number; height: number; status: string; componentCount?: number }[]; offset: number; total: number; nextOffset: number | null; revision: number }>();
  const [labelRegion, setLabelRegion] = useState<StorageRegion>({ x: 0, y: 0, width: 512, height: 512 });
  const [labelPreview, setLabelPreview] = useState<{ key: string; dataUrl: string; overlayDataUrl?: string; revision: number }>();
  const [error, setError] = useState("");
  const pinError = useCataloguePins([{ catalogue: "zarrSources", entryId: sourceId }, { catalogue: "tiledAnalyses", entryId: analysisId }]);
  const source = sources.find(item => item.id === sourceId);
  const array = source?.arrays.find(item => item.path === arrayPath);
  const dims = Object.fromEntries(array?.axes.map((axis, index) => [axis.name, array.shape[index]]) ?? []);
  const selection = { sourceId, arrayPath, timeIndex, channel, zIndex };
  const selectionKey = JSON.stringify([selection, source?.metadataHash]);
  const currentOverview = overview?.key === selectionKey ? overview : undefined;
  const parameters = { method, ...(method === "manual" ? { threshold } : {}), polarity, connectivity, minAreaPx };
  const planArgs = { ...selection, region, tileSize, halo, parameters };
  const planKey = JSON.stringify(planArgs);
  const currentPlan = plan?.key === planKey && plan.revision === snapshot.project.revision ? plan.value : undefined;
  const analysis = analyses.find(item => item.id === analysisId);
  const activeWorker = snapshot.jobWorkers?.find(activeJobWorker);
  const thisWorker = activeWorker && workerTargetKind(activeWorker) === "tiled-analysis" && workerTargetId(activeWorker) === analysisId ? activeWorker : undefined;
  const blocked = busy || writeBlocked || Boolean(activeWorker);
  const validRegion = Boolean(array && Object.values(region).every(Number.isInteger) && region.x >= 0 && region.y >= 0 && region.width > 0 && region.height > 0
    && region.x + region.width <= dims.x && region.y + region.height <= dims.y);
  const validSelection = Boolean(array && [[timeIndex, dims.t ?? 1], [channel, dims.c ?? 1], [zIndex, dims.z ?? 1]].every(([value, count]) => Number.isInteger(value) && value >= 0 && value < count));
  const validLabels = analysis && Object.values(labelRegion).every(Number.isInteger) && labelRegion.x >= analysis.region.x && labelRegion.y >= analysis.region.y
    && labelRegion.width > 0 && labelRegion.height > 0 && labelRegion.width * labelRegion.height <= 1_000_000
    && labelRegion.x + labelRegion.width <= analysis.region.x + analysis.region.width && labelRegion.y + labelRegion.height <= analysis.region.y + analysis.region.height;
  const labelKey = JSON.stringify([analysisId, labelRegion]);
  const operation = (action: () => Promise<void>) => actions.run(async () => { setError(""); try { await action(); } catch (cause) { setError(String(cause)); } });

  useEffect(() => { setSourceId(id => id || sources[0]?.id || ""); setAnalysisId(id => id || analyses[0]?.id || ""); }, [snapshot.project.revision]);
  useEffect(() => { setArrayPath(source?.arrays[0]?.path ?? ""); setOverview(undefined); }, [sourceId]);
  useEffect(() => { setTimeIndex(0); setChannel(0); setZIndex(0); setRegion({ x: 0, y: 0, width: Math.min(512, dims.x ?? 512), height: Math.min(512, dims.y ?? 512) }); setPlan(undefined); }, [sourceId, arrayPath]);
  useEffect(() => { if (analysis) setLabelRegion({ x: analysis.region.x, y: analysis.region.y, width: Math.min(512, analysis.region.width), height: Math.min(512, analysis.region.height) }); setObjectPage(undefined); setTilePage(undefined); setLabelPreview(undefined); }, [analysisId]);

  const objects = async (offset = 0) => {
    const result = await read<Omit<NonNullable<typeof objectPage>, "revision">>("tiled.analysis.objects", { analysisId, offset, limit: 100 });
    setObjectPage({ ...result, revision: snapshot.project.revision });
  };
  const tiles = async (offset = 0) => {
    const result = await read<Omit<NonNullable<typeof tilePage>, "revision">>("tiled.analysis.tiles", { analysisId, offset, limit: 50 });
    setTilePage({ ...result, revision: snapshot.project.revision });
  };
  const create = () => actions.mutate<{ analysis: TiledAnalysis }>("tiled.analysis.create", { ...planArgs, ...(analysisName.trim() ? { name: analysisName.trim() } : {}) }, result => setAnalysisId(result.analysis.id));

  return <><details className="workbench-automation">
    <summary>OME-Zarr sources</summary>
    <p>Choose a local NGFF image group, resolution level and exact T/C/Z plane. Extract a source-resolution region or process a larger region in durable tiles.</p>
    {activeTask === "preparation" && pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    {activeTask === "preparation" && error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <button className="cc-btn" disabled={blocked} onClick={() => void actions.chooseDirectory("zarr.import", undefined, source => setSourceId(source.id))}>Open local OME-Zarr…</button>
    <WorkbenchZarrSelection sources={sources} value={selection} disabled={busy} onChange={value => { setSourceId(value.sourceId); setArrayPath(value.arrayPath); setTimeIndex(value.timeIndex); setChannel(value.channel); setZIndex(value.zIndex); }} />
    {source ? <div className="workbench-actions"><button className="cc-btn" disabled={blocked} onClick={() => void actions.chooseDirectory("zarr.rebind", sourceId)}>Relocate identical source…</button>
      <button className="cc-btn" disabled={busy || !validSelection || !source.available} onClick={() => void operation(async () => {
        const result = await read<{ dataUrl: string; width: number; height: number; notes: string[] }>("zarr.overview", { ...selection, maxSize: 768 }); setOverview({ ...result, key: selectionKey });
      })}>Read selected-level overview</button></div> : null}
    {currentOverview ? <><img src={currentOverview.dataUrl} alt="Sampled display overview of the selected OME-Zarr plane" style={{ maxWidth: "100%", maxHeight: 420, objectFit: "contain" }} />
      <p>Overview sampling is for display. Region coordinates below refer to the {currentOverview.width} × {currentOverview.height} selected-level source grid.</p></> : overview ? <p>Source selection changed. Read the overview for the current selection.</p> : null}
    {array ? <fieldset disabled={busy}>
      <legend>Region on the selected resolution level</legend>
      <WorkbenchZarrRegion value={region} onChange={setRegion} disabled={busy} />
      <button className="cc-btn" onClick={() => setRegion({ x: 0, y: 0, width: dims.x, height: dims.y })}>Use whole selected plane</button>
      <p>{fmt(region.width * region.height)} source pixels. Ordinary image extraction is limited to 16 million pixels; tiled analysis has a separate bounded plan.</p>
      <label>Extracted image name<input value={imageName} maxLength={200} onChange={event => setImageName(event.target.value)} placeholder="Use source and region name" /></label>
      <button className="cc-btn" disabled={blocked || !validRegion || !validSelection || region.width * region.height > 16_000_000 || !source?.available} onClick={() => void actions.mutate("zarr.extract", { ...selection, ...region, ...(imageName.trim() ? { name: imageName.trim() } : {}) })}>Extract exact region for analysis</button>

    </fieldset> : null}

  </details>
  {analysisTarget ? createPortal(<section aria-label="Tiled segmentation">
    <h3>Tiled segmentation</h3>
    {activeTask === "segmentation" && pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    {activeTask === "segmentation" && error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <p>{source ? `Source: ${source.name} · level ${arrayPath} · time ${timeIndex + 1}, channel ${channel + 1}, Z ${zIndex + 1} · region ${region.width} × ${region.height} at ${region.x}, ${region.y}.` : "Choose an OME-Zarr source and region in Images before creating a tiled analysis."}</p>
    <button type="button" className="cc-btn" onClick={() => openWorkbench({ kind: "task", task: "preparation" })}>Choose source and region in Images</button>
    {array ? <>      <details><summary>Create tiled analysis</summary>
        <fieldset disabled={busy}>
        <p>Global threshold-connected components across tiles. Shared-edge objects are reconciled before minimum-area filtering. This method processes one plane; it does not run tiled watershed or learned models.</p>
        <div className="workbench-editor-grid">
          <label>Threshold method<select value={method} onChange={event => setMethod(event.target.value as typeof method)}><option value="otsu">Global Otsu</option><option value="manual">Manual raw-intensity threshold</option></select></label>
          {method === "manual" ? <label>Threshold (raw intensity)<input type="number" step="any" value={threshold} onChange={event => setThreshold(Number(event.target.value))} /></label> : null}
          <label>Foreground<select value={polarity} onChange={event => setPolarity(event.target.value as typeof polarity)}><option value="bright">Brighter than threshold</option><option value="dark">Darker than threshold</option></select></label>
          <label>Connectivity<select value={connectivity} onChange={event => setConnectivity(Number(event.target.value) as 4 | 8)}><option value={4}>4 neighbours</option><option value={8}>8 neighbours, including diagonals</option></select></label>
          <label>Minimum global object area (pixels)<input type="number" min={1} value={minAreaPx} onChange={event => setMinAreaPx(Number(event.target.value))} /></label>
          <label>Tile edge (pixels)<input type="number" min={64} max={1024} value={tileSize} onChange={event => setTileSize(Number(event.target.value))} /></label>
          <label>Halo width (pixels)<input type="number" min={1} max={64} value={halo} onChange={event => setHalo(Number(event.target.value))} /></label>
        </div>
        <button className="cc-btn" disabled={!validRegion || !validSelection || Boolean(activeWorker)} onClick={() => void operation(async () => { const result = await read<{ plan: TiledPlan }>("tiled.analysis.preview", planArgs); setPlan({ key: planKey, revision: snapshot.project.revision, value: result.plan }); })}>Preview tile plan</button>
        {currentPlan ? <><p>{currentPlan.tileCount} tiles · {currentPlan.checkpointCount} durable checkpoints · estimated maximum working memory {fmt(currentPlan.estimatedMaximumWorkingBytes / 1024 ** 2)} MiB.</p>
          <p>Plan preview does not segment the source. Completed tiles and source identities are retained; a background worker can continue after the app closes.</p>
          <details><summary>Processing limits and scientific notes</summary><ul>{currentPlan.notes.map(note => <li key={note}>{note}</li>)}</ul><p>Maximum 4,096 tiles, one billion region pixels, one million local components and 8 GiB retained artifacts.</p></details></> : plan ? <p>The plan is no longer current. Preview the edited settings at this project revision.</p> : null}
        <label>Saved analysis name<input value={analysisName} maxLength={200} onChange={event => setAnalysisName(event.target.value)} placeholder="Use source name" /></label>
        <button className="cc-btn" disabled={blocked || !currentPlan} onClick={() => void create()}>Create tiled analysis</button>
        </fieldset>
      </details></> : null}
    <section aria-label="Saved tiled analyses"><h3>Saved tiled analyses</h3>
      <label>Analysis<select disabled={busy} value={analysisId} onChange={event => setAnalysisId(event.target.value)}>{!analyses.length ? <option value="">Create a tile plan first</option> : null}{analyses.map(item => <option key={item.id} value={item.id}>{item.name} · {item.status}</option>)}</select></label>
      {analysis ? <><p>{analysis.status} · {analysis.phase} · {analysis.progress.completed} / {analysis.progress.total} checkpoints · {fmt(analysis.retainedBytes / 1024 ** 2)} MiB retained</p>
        <progress aria-label={`${analysis.name} progress`} value={analysis.progress.completed} max={analysis.progress.total || 1} />
        <p>Source {analysis.sourceName}; level {analysis.selection.arrayPath}; time {analysis.selection.timeIndex + 1}, channel {analysis.selection.channel + 1}, Z {analysis.selection.zIndex + 1}.</p>
        {analysis.error ? <p className="workbench-error" role="alert">{analysis.error.message}</p> : null}
        <p>{analysis.sourceVerifiedAt ? `Source last verified at ${analysis.sourceVerifiedAt}.` : "Source has not completed final verification."} External source currentness is not checked continuously.</p>
        {analysis.nextUnit ? <p>Next: {analysis.nextUnit.type.replace("tiled-", "")}{analysis.nextUnit.tileIndex == null ? "" : ` · tile ${analysis.nextUnit.tileIndex + 1}`}</p> : null}
        <div className="workbench-actions">
          {["pending", "running"].includes(analysis.status) ? <><button className="cc-btn" disabled={blocked} onClick={() => void actions.mutate("tiled.analysis.advance", { analysisId })}>Run next checkpoint</button>
            <button className="cc-btn" disabled={blocked} onClick={() => void actions.mutate("tiled.analysis.worker.start", { analysisId })}>Run in background</button>
            <button className="cc-btn" disabled={blocked} onClick={() => void actions.mutate("tiled.analysis.pause", { analysisId })}>Pause before next checkpoint</button></> : null}
          {["paused", "failed"].includes(analysis.status) ? <button className="cc-btn" disabled={blocked} onClick={() => void actions.mutate("tiled.analysis.resume", { analysisId })}>Resume retained checkpoints</button> : null}
          {!["completed", "cancelled"].includes(analysis.status) ? <button className="cc-btn" disabled={blocked} onClick={() => void actions.mutate("tiled.analysis.cancel", { analysisId })}>Cancel remaining work</button> : null}
          {thisWorker ? <button className="cc-btn" disabled={thisWorker.stopRequested} onClick={() => void actions.stopWorker(thisWorker.workerId)}>{thisWorker.stopRequested ? "Stop requested" : "Stop after current checkpoint"}</button> : null}
        </div>
        {activeWorker && !thisWorker ? <p>Another background operation owns this project. Stop it from Background execution before changing this analysis.</p> : null}
        {analysis.objectCount != null ? <p>{fmt(analysis.objectCount)} globally reconciled objects{analysis.status === "completed" ? "" : " · publication or verification may still be pending"}.</p> : null}


      </> : null}
    </section>
  </section>, analysisTarget) : null}
  {measurementsTarget && analysis ? createPortal(<section aria-label="Tiled analysis measurements">
    <h3>Tiled analysis · {analysis.name}</h3>
    {activeTask === "measurements" && error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <button type="button" className="cc-btn" onClick={() => openWorkbench({ kind: "task", task: "segmentation" })}>Choose another tiled analysis in Segmentation</button>
        <details><summary>Object measurements and retained tiles</summary>
          <div className="workbench-actions"><button className="cc-btn" disabled={busy || analysis.objectCount == null} onClick={() => void operation(() => objects())}>Read object measurements</button><button className="cc-btn" disabled={busy} onClick={() => void operation(() => tiles())}>Read tile checkpoints</button></div>
          {objectPage?.analysisId === analysisId ? <><p>{objectPage.offset + 1}–{objectPage.offset + objectPage.objects.length} of {objectPage.total} objects · read at revision {objectPage.revision}{objectPage.revision !== snapshot.project.revision ? " (refresh to read current retained outputs)" : ""}</p>
            <div className="workbench-table-wrap"><table><thead><tr><th>Object</th><th>Area (pixels)</th><th>Area (µm²)</th><th>X (source px)</th><th>Y (source px)</th><th>Mean raw intensity</th></tr></thead><tbody>{objectPage.objects.map(item => <tr key={item.id}><td>{item.id}</td><td>{fmt(item.areaPx)}</td><td>{fmt(item.areaUm2)}</td><td>{fmt(item.centroidX)}</td><td>{fmt(item.centroidY)}</td><td>{fmt(item.meanIntensity)}</td></tr>)}</tbody></table></div>
            <button className="cc-btn" disabled={busy || !objectPage.offset} onClick={() => void operation(() => objects(Math.max(0, objectPage.offset - 100)))}>Previous objects</button><button className="cc-btn" disabled={busy || objectPage.nextOffset == null} onClick={() => void operation(() => objects(objectPage.nextOffset!))}>Next objects</button></> : null}
          {tilePage?.analysisId === analysisId ? <><div className="workbench-table-wrap"><table><thead><tr><th>Tile</th><th>Source region</th><th>Checkpoint</th><th>Local components</th></tr></thead><tbody>{tilePage.tiles.map(item => <tr key={item.index}><td>{item.index + 1}</td><td>{item.x}, {item.y} · {item.width} × {item.height}</td><td>{item.status}</td><td>{fmt(item.componentCount)}</td></tr>)}</tbody></table></div>
            <p>Read at revision {tilePage.revision}.</p><button className="cc-btn" disabled={busy || !tilePage.offset} onClick={() => void operation(() => tiles(Math.max(0, tilePage.offset - 50)))}>Previous tiles</button><button className="cc-btn" disabled={busy || tilePage.nextOffset == null} onClick={() => void operation(() => tiles(tilePage.nextOffset!))}>Next tiles</button></> : null}
        </details>
  </section>, measurementsTarget) : null}
  {exportTarget && analysis ? createPortal(<details><summary>Tiled analysis results</summary>
    <p>{analysis.name} · {analysis.status}</p>
    {activeTask === "export" && error ? <p className="workbench-error" role="alert">{error}</p> : null}
        <details><summary>Retained label region</summary>
          <p>Read up to one million retained label pixels. Coordinates use the selected source level, not the display overview.</p>
          <div className="workbench-editor-grid">{regionFields.map(key => <label key={key}>Label region {key}<input disabled={busy} type="number" value={labelRegion[key]} min={key === "x" || key === "y" ? 0 : 1} onChange={event => setLabelRegion(previous => ({ ...previous, [key]: Number(event.target.value) }))} /></label>)}</div>
          <button className="cc-btn" disabled={busy || !validLabels} onClick={() => void operation(async () => { const result = await read<{ dataUrl: string; overlayDataUrl?: string }>("tiled.analysis.labels.region", { analysisId, ...labelRegion, maxSize: 768 }); setLabelPreview({ ...result, key: labelKey, revision: snapshot.project.revision }); })}>Read retained label region</button>
          {labelPreview?.key === labelKey ? <><img src={labelPreview.overlayDataUrl ?? labelPreview.dataUrl} alt="Display of the exact retained label region" style={{ maxWidth: "100%", maxHeight: 420, objectFit: "contain" }} /><p>Retained labels read at revision {labelPreview.revision}; display is scaled.</p></> : null}

        </details>
          <button className="cc-btn" disabled={busy} onClick={() => void operation(async () => setFormats((await read<{ formats: StorageExportFormat[] }>("tiled.analysis.export.catalogue")).formats))}>Show result export formats</button>
          {formats.map(format => <p key={format.id}><button className="cc-btn" disabled={blocked || analysis.status !== "completed"} onClick={() => void actions.exportResults(analysis, format)}>Export {format.name}…</button> {format.description}</p>)}
          <p>Export verifies the external source identities again. Existing exported files remain immutable.</p>
  </details>, exportTarget) : null}
  </>;
}
