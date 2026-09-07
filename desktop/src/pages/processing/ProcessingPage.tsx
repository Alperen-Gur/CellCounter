import { useEffect, useState, useSyncExternalStore } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";
import { analysisQueue } from "../../kernel/workflow/desktopQueue";
import { settingsKey, type AnalysisJob, type AnalysisTask } from "../../kernel/workflow/AnalysisQueue";
import { useAppStore } from "../../kernel/store/store";
import { getPort } from "../../kernel/persistence";
import { navigate } from "../../components/useHashRoute";
import { useKeymap } from "../../components/useKeymap";
import { MODEL_CATALOG } from "../models/catalog";
import { Viewport } from "../../kernel/viewport/Viewport";
import { MaskOverlay } from "../../kernel/overlay/MaskOverlay";
import type { CellDTO, ImageDTO } from "../../kernel/types";
import "./workflow.css";

export default function ProcessingPage() {
  const jobs = useSyncExternalStore(analysisQueue.subscribe, analysisQueue.getSnapshot);
  const [selected, setSelected] = useState<string>();
  const [error, setError] = useState<string>();
  const job = jobs.find(row => row.id === selected) ?? jobs[0];
  useEffect(() => { void analysisQueue.initialize().catch(error => setError(String(error))); }, []);
  return <div className="workflow-page">
    <header><h1>Processing</h1><p>Inspect a sample, preview the masks, then process the batch. Your jobs and settings are saved.</p></header>
    {error && <p role="alert">{error}</p>}
    {!jobs.length ? <section><h2>No processing jobs</h2><p>Open images from Home to set up an analysis.</p><button className="cc-btn" onClick={() => navigate("home")}>Open Home</button></section> :
      <div className="workflow-columns"><nav aria-label="Saved processing jobs">{jobs.map(row => <button key={row.id} aria-current={row.id === job?.id ? "true" : undefined} onClick={() => setSelected(row.id)}>
        <strong>{row.name}</strong><span>{row.items.filter(item => item.status === "completed").length} / {row.items.length} · {row.status}</span>
      </button>)}</nav>{job && <JobSetup key={job.id} job={job} />}</div>}
  </div>;
}

function JobSetup({ job }: { job: AnalysisJob }) {
  const [params, setParams] = useState(job.params);
  const [task, setTask] = useState<AnalysisTask>(job.task);
  const [scaleSource, setScaleSource] = useState(job.calibrationSource);
  const [imageId, setImageId] = useState(job.items[0]?.imageId ?? "");
  const [images, setImages] = useState<ImageDTO[]>([]);
  const [cells, setCells] = useState<CellDTO[]>([]);
  const [message, setMessage] = useState<string>();
  const [busy, setBusy] = useState(false);
  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const stage = useAppStore(store => store.stageLine);
  const running = job.status === "running";
  const selectedItem = job.items.find(item => item.imageId === imageId) ?? job.items[0];
  const image = images.find(image => image.id === selectedItem?.imageId);
  const completed = job.items.filter(item => item.status === "completed").length;
  const dirty = settingsKey(job.params) !== settingsKey(params) || task !== job.task || scaleSource !== job.calibrationSource;
  useEffect(() => {
    let alive = true;
    void getPort().imagesForBatch(job.batchId).then(images => { if (alive) setImages(images); }).catch(error => { if (alive) setMessage(String(error)); });
    return () => { alive = false; };
  }, [job.batchId]);
  useEffect(() => {
    let alive = true; setCells([]);
    if (selectedItem?.status === "completed" && selectedItem.settingsKey === settingsKey(params)) {
      void getPort().getDetection(selectedItem.imageId).then(detection => { if (alive) setCells(detection?.cells ?? []); }).catch(error => { if (alive) setMessage(String(error)); });
    }
    return () => { alive = false; };
  }, [selectedItem?.imageId, selectedItem?.status, selectedItem?.detectionId, selectedItem?.settingsKey, params]);
  const save = () => dirty ? analysisQueue.update(job.id, params, task, scaleSource) : Promise.resolve();
  const action = async (preview: boolean) => {
    if (busy || analysisQueue.isActive()) return;
    setBusy(true); setMessage(undefined);
    try { await save(); await analysisQueue.run(job.id, preview ? selectedItem?.imageId : undefined); }
    catch (error) { setMessage(error instanceof Error ? error.message : String(error)); }
    finally { setBusy(false); }
  };
  const inspect = async (targetId = selectedItem?.imageId) => {
    try {
      await save();
      const batch = await getPort().batch(job.batchId);
      if (!batch || !targetId || !batch.imageIds.includes(targetId)) throw new Error("This image is no longer in the library.");
      const store = useAppStore.getState(); store.openBatch(job.batchId); store.setCurrentImageIdx(batch.imageIds.indexOf(targetId)); navigate("results");
    } catch (error) { setMessage(String(error)); }
  };
  useKeymap("processing", {
    preview: () => { if (!running && !busy) void action(true); },
    process: () => { if (!running && !busy) void action(false); },
    pause: () => { if (running) analysisQueue.pause(job.id); },
    inspect: () => { void inspect(); },
  }, { allowInInputs: true });
  return <section className="workflow-detail" aria-label="Analysis setup">
    <header><h2>{job.name}</h2><p>{completed} of {job.items.length} completed · {job.status}</p></header>
    <div className="workflow-setup">
      <div><label>Representative image<select value={selectedItem?.imageId ?? ""} onChange={event => { setImageId(event.target.value); setZoom(1); setPan({ x: 0, y: 0 }); }}>
        {!job.items.length && <option value="">No images</option>}{job.items.map(item => <option key={item.imageId} value={item.imageId}>{item.fileName}</option>)}
      </select></label>
        <div className="workflow-preview">{image ? <Viewport imageSrc={convertFileSrc(image.storedPath)} sourceWidth={image.widthPx} sourceHeight={image.heightPx} zoom={zoom} pan={pan} onZoomChange={setZoom} onPanChange={setPan} onFit={() => { setZoom(1); setPan({ x: 0, y: 0 }); }}>
          <MaskOverlay cells={cells} thresholds={[params.smallThresholdUm, params.largeThresholdUm]} overlayMode="outline" confidenceCutoff={params.confidenceThreshold} showMaskFills showOutlines maskOpacity={0.2} selectedCellIds={new Set()} />
        </Viewport> : <p>Loading image…</p>}</div><p>{image?.widthPx} × {image?.heightPx} pixels · {cells.length} masks</p>
      </div>
      <fieldset disabled={running || busy}><legend>Saved analysis settings</legend>
        <label>Task<select value={task} onChange={event => setTask(event.target.value as AnalysisTask)}><option value="countCells">Cell counts and sizes</option><option value="nuclei">Nuclei</option><option value="markerPositive">Marker positivity</option><option value="woundClosure">Wound closure</option></select></label>
        {task !== "countCells" && <p className="workflow-note">Choose a model and channels appropriate to this task. Marker and wound measurements run in Results → Advanced assays after segmentation.</p>}
        <label>Model<select value={params.modelId} onChange={event => setParams({ ...params, modelId: event.target.value })}>{MODEL_CATALOG.filter(model => model.available).map(model => <option key={model.id} value={model.id}>{model.name}</option>)}</select></label>
        <label>Pixels per µm<input type="number" min="0.000001" step="any" value={params.pxPerUm} onChange={event => { setScaleSource("manual"); setParams({ ...params, pxPerUm: Number(event.target.value) }); }} /></label>
        <p className="workflow-note">Scale source: {scaleSource}. A screenshot needs a known scale for calibrated measurements.</p>
        <label>Confidence<input type="number" min="0" max="1" step="0.05" value={params.confidenceThreshold} onChange={event => setParams({ ...params, confidenceThreshold: Number(event.target.value) })} /></label>
        <label>Expected diameter (µm; 0 = automatic)<input type="number" min="0" step="1" value={params.expectedDiameterUm} onChange={event => setParams({ ...params, expectedDiameterUm: Number(event.target.value) })} /></label>
        {([0, 1] as const).map(index => <label key={index}>{index ? "Nuclear channel" : "Cell channel"}<select value={params.channels[index]} onChange={event => { const channels: [number, number] = [...params.channels]; channels[index] = Number(event.target.value); setParams({ ...params, channels }); }}><option value="0">Grayscale</option><option value="1">Red</option><option value="2">Green</option><option value="3">Blue</option></select></label>)}
        <label>Source channel (blank = automatic; zero-based)<input type="number" min="0" step="1" placeholder="Automatic" value={params.segmentChannel ?? ""} onChange={event => setParams({ ...params, segmentChannel: event.target.value === "" ? null : Number(event.target.value) })} /></label>
        <label>Z projection<select value={params.zProjection ?? "max"} onChange={event => setParams({ ...params, zProjection: event.target.value as NonNullable<typeof params.zProjection> })}><option value="max">Maximum</option><option value="mean">Mean</option><option value="sum">Sum</option><option value="none">Middle plane (no projection)</option></select></label>
        <label><input type="checkbox" checked={params.backgroundSubtract} onChange={event => setParams({ ...params, backgroundSubtract: event.target.checked })} /> Subtract background</label>
        <label><input type="checkbox" checked={params.watershedSplit} onChange={event => setParams({ ...params, watershedSplit: event.target.checked })} /> Split touching cells</label>
      </fieldset>
    </div>
    {(message || job.error || selectedItem?.error) && <p role="alert">{message ?? job.error ?? selectedItem?.error}</p>}
    {running && <p role="status">{stage || "Starting analysis…"}</p>}
    <div className="workflow-actions">
      <button className="cc-btn" disabled={busy && !running} onClick={() => void inspect()}>Import and inspect</button>
      <button className="cc-btn" onClick={() => navigate("models")}>Models</button>
      {running ? <><button className="cc-btn" onClick={() => analysisQueue.pause(job.id)}>{analysisQueue.isPausing(job.id) ? "Pausing after this image…" : "Pause after this image"}</button><button className="cc-btn" onClick={() => analysisQueue.cancel(job.id)}>Stop now</button></> : <>
        <button className="cc-btn" disabled={busy || analysisQueue.isActive() || !selectedItem} onClick={() => void action(true)}>Preview this image</button>
        <button className="cc-btn cc-btn--primary" disabled={busy || analysisQueue.isActive()} onClick={() => void action(false)}>{job.status === "failed" ? "Retry failed images" : job.status === "paused" ? "Resume batch" : "Process batch"}</button>
      </>}
    </div>
    <details><summary>Images and results ({job.items.length})</summary><div className="workflow-items">{job.items.map(item => <div key={item.imageId}><button className="cc-btn" onClick={() => void inspect(item.imageId)}>{item.fileName}</button><span>{item.status}</span>{item.error && <p role="alert">{item.error}</p>}</div>)}</div></details>
  </section>;
}
