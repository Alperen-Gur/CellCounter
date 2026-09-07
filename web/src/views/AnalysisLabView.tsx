import { Activity, Beaker, Download, FileInput, FlaskConical, Play, Save, Square } from "lucide-react";
import { useMemo, useRef, useState } from "react";
import type { WorkspaceImage } from "../app/types";
import { filterCellsByRois } from "../app/roi";
import type { AnalysisSettings } from "../components/Inspector";
import { ANALYSIS_PROTOCOL_KIND, applyAnalysisProtocol, parseAnalysisProtocol, serializeAnalysisProtocol, type AnalysisProtocolV1 } from "../analysis";
import { runAssay, type AssayKind } from "../workers/AssayWorkerClient";

const modelNames = { classical: "Classical threshold + watershed", cpsam_v2: "Cellpose-SAM v2", "cp-cyto3": "Cellpose cyto3", "sd-fluo": "StarDist fluorescence" } as const;
const assays: readonly { id: AssayKind; name: string; detail: string; source: boolean }[] = [
  { id: "qc", name: "Focus & illumination", detail: "Laplacian sharpness and block illumination residual", source: true },
  { id: "intensity", name: "Intensity suite", detail: "Positivity, transfection, viability, colocalization, N:C and cell cycle", source: true },
  { id: "area", name: "Area & regions", detail: "Confluence, scratch wound, spheroid and colony statistics", source: true },
  { id: "puncta", name: "Puncta & foci", detail: "DoG peaks assigned to source-coordinate cell polygons", source: true },
  { id: "spatial", name: "Spatial statistics", detail: "Nearest-neighbour, local density and Clark–Evans", source: false },
  { id: "tracking", name: "Tracking & migration", detail: "Calibrated assignment across the ordered image library", source: false },
  { id: "neurite", name: "Neurite outgrowth", detail: "Mask skeletonization and soma attribution", source: true },
  { id: "line-profile", name: "Line profile", detail: "Bilinear channel and luminance samples between exact endpoints", source: true },
  { id: "ground-truth", name: "Ground-truth metrics", detail: "Live precision, recall and F1 against gold marks", source: false },
];

function download(name: string, bytes: BlobPart, type: string) {
  const url = URL.createObjectURL(new Blob([bytes], { type }));
  const anchor = document.createElement("a"); anchor.href = url; anchor.download = name; anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}

function savedProtocols(): AnalysisProtocolV1[] {
  try {
    const values = JSON.parse(localStorage.getItem("cellcounter-analysis-protocols-v1") ?? "[]") as unknown[];
    return values.flatMap((value) => { try { return [parseAnalysisProtocol(JSON.stringify(value), Object.keys(modelNames))]; } catch { return []; } });
  } catch { return []; }
}

function scalarSummary(value: unknown, prefix = "", depth = 0): Array<[string, string]> {
  if (depth > 2 || value === null || value === undefined) return [];
  if (typeof value === "number") return [[prefix, Number.isInteger(value) ? value.toLocaleString() : value.toLocaleString(undefined, { maximumFractionDigits: 4 })]];
  if (typeof value === "string" || typeof value === "boolean") return [[prefix, String(value)]];
  if (Array.isArray(value)) return [[prefix || "Rows", `${value.length.toLocaleString()} entries`]];
  if (typeof value === "object") return Object.entries(value).flatMap(([key, child]) => scalarSummary(child, prefix ? `${prefix} · ${key}` : key, depth + 1)).slice(0, 12);
  return [];
}

interface AnalysisLabProps {
  image?: WorkspaceImage;
  images: readonly WorkspaceImage[];
  settings: AnalysisSettings;
  onSettings: (settings: AnalysisSettings) => void;
  onWorkspace: () => void;
}

export function AnalysisLabView({ image, images, settings, onSettings, onWorkspace }: AnalysisLabProps) {
  const [kind, setKind] = useState<AssayKind>("qc");
  const [projection, setProjection] = useState<"first" | "max">("first");
  const [auxiliary, setAuxiliary] = useState<File>();
  const [running, setRunning] = useState(false);
  const [result, setResult] = useState<unknown>();
  const [error, setError] = useState<string>();
  const [protocols, setProtocols] = useState(savedProtocols);
  const [frameInterval, setFrameInterval] = useState(10);
  const [maxDisplacement, setMaxDisplacement] = useState(50);
  const [trackingCondition, setTrackingCondition] = useState(image?.condition ?? "Unassigned");
  const [line, setLine] = useState({ x1: 0, y1: Math.round((image?.height ?? 1) / 2), x2: Math.max(0, (image?.width ?? 1) - 1), y2: Math.round((image?.height ?? 1) / 2) });
  const abortRef = useRef<AbortController | undefined>(undefined);
  const protocolInput = useRef<HTMLInputElement>(null);
  const auxiliaryInput = useRef<HTMLInputElement>(null);
  const selected = assays.find((assay) => assay.id === kind)!;
  const conditions = useMemo(() => [...new Set(images.map((entry) => entry.condition))].sort(), [images]);
  const trackingImages = useMemo(() => [...images].filter((entry) => entry.condition === trackingCondition && entry.cells.length).sort((a, b) => a.importedAt.localeCompare(b.importedAt)), [images, trackingCondition]);
  const summary = useMemo(() => scalarSummary(result), [result]);

  const execute = async () => {
    if (!image) { setError("Open an image before running an assay."); return; }
    if (selected.source && !image.sourceLoaded) { setError("Open this image in Workspace once to load its local source bytes."); return; }
    const controller = new AbortController(); abortRef.current = controller; setRunning(true); setError(undefined); setResult(undefined);
    try {
      if (kind === "tracking" && trackingImages.length < 2) throw new Error(`Condition “${trackingCondition}” needs at least two analyzed images for tracking.`);
      const frames = trackingImages.map((entry, frame) => ({ frame, points: filterCellsByRois(entry).map((cell) => ({ id: cell.id, x: cell.cx, y: cell.cy })) }));
      const assayCells = filterCellsByRois(image);
      const output = await runAssay(kind, {
        source: selected.source ? image.originalFile ?? image.file : undefined,
        fileName: image.fileName, auxiliary, auxiliaryFileName: auxiliary?.name, projection,
        width: image.width, height: image.height, pxPerUm: image.pxPerUm, cells: assayCells,
        truth: image.groundTruth, frames, frameIntervalMin: frameInterval, maxDisplacementUm: maxDisplacement,
        lineStart: { x: line.x1, y: line.y1 }, lineEnd: { x: line.x2, y: line.y2 },
      }, controller.signal);
      setResult(kind === "tracking" ? { ...(output as Record<string, unknown>), sequence: { condition: trackingCondition, imageIds: trackingImages.map(({ id }) => id), fileNames: trackingImages.map(({ fileName }) => fileName), orderedBy: "importedAt", frameIntervalMin: frameInterval } } : output);
    } catch (cause) { if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : String(cause)); }
    finally { setRunning(false); abortRef.current = undefined; }
  };

  const currentProtocol = (): AnalysisProtocolV1 => ({
    schemaVersion: 1, kind: ANALYSIS_PROTOCOL_KIND, id: crypto.randomUUID(), name: `${image?.condition ?? "Local"} analysis`, notes: image?.note ?? "",
    createdAt: new Date().toISOString(), appVersion: "0.2.0", appBuild: "web",
    model: { id: settings.modelId, name: modelNames[settings.modelId], family: settings.modelId === "classical" ? "classical" : settings.modelId === "sd-fluo" ? "stardist" : "cellpose" },
    browser: { sourceChannel: settings.sourceChannel ?? -1, projection: settings.projection ?? "first", thresholdMethod: settings.thresholdMethod ?? "otsu", manualThreshold: settings.manualThreshold ?? .5, invert: settings.invert ?? false, minimumAreaPx: settings.minimumAreaPx ?? 9 },
    detection: { expectedDiameterUm: settings.diameterUm, channelsCyto: 0, channelsNuclei: 0, confidenceThreshold: settings.confidence },
    calibration: { pxPerUm: settings.pxPerUm }, sizeBins: { thresholdsUm: [20, 30] },
    preprocessing: { backgroundSubtract: settings.backgroundSubtract, rollingBallRadiusPx: 50, watershedSplit: settings.watershedSplit, watershedMinDistanceUm: 8 }, manualMarkerDiameterUm: settings.diameterUm || 30,
  });

  const saveProtocol = () => {
    const protocol = currentProtocol(); const next = [...protocols, protocol].slice(-20); setProtocols(next);
    localStorage.setItem("cellcounter-analysis-protocols-v1", JSON.stringify(next));
    download(`${protocol.name.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}.ccproto.json`, serializeAnalysisProtocol(protocol), "application/json");
  };
  const applyProtocol = (protocol: AnalysisProtocolV1) => {
    const applied = applyAnalysisProtocol(protocol, Object.keys(modelNames));
    onSettings({ ...settings, sourceChannel: applied.sourceChannel ?? -1, projection: applied.projection ?? "first", thresholdMethod: applied.thresholdMethod ?? "otsu", manualThreshold: applied.manualThreshold ?? .5, invert: applied.invert ?? false, minimumAreaPx: applied.minimumAreaPx ?? 9, modelId: applied.modelId as AnalysisSettings["modelId"], diameterUm: applied.expectedDiameterUm, confidence: applied.confidenceThreshold, pxPerUm: applied.pxPerUm, backgroundSubtract: applied.backgroundSubtract, watershedSplit: applied.watershedSplit });
  };
  const loadProtocol = async (file?: File) => {
    if (!file) return;
    try { const protocol = parseAnalysisProtocol(await file.text(), Object.keys(modelNames)); applyProtocol(protocol); setProtocols((items) => items.some(({ id }) => id === protocol.id) ? items : [...items, protocol].slice(-20)); setError(undefined); }
    catch (cause) { setError(cause instanceof Error ? cause.message : String(cause)); }
  };

  return (
    <main className="page-view analysis-lab">
      <header className="page-heading"><div><span className="eyebrow">Browser-native assays</span><h1>Analysis lab</h1><p>Typed-array kernels run in disposable workers against local source pixels. TIFF max projection is explicit, never inferred.</p></div><button className="secondary-button" onClick={onWorkspace}>Back to image</button></header>
      <div className="lab-layout">
        <aside className="assay-picker" aria-label="Available assays">{assays.map((assay) => <button key={assay.id} className={kind === assay.id ? "active" : ""} onClick={() => { setKind(assay.id); setResult(undefined); setError(undefined); }}><span><FlaskConical size={15} /></span><strong>{assay.name}</strong><small>{assay.detail}</small></button>)}</aside>
        <section className="assay-console">
          <header><div><span className="eyebrow">{selected.source ? "Source-pixel assay" : "Geometry assay"}</span><h2>{selected.name}</h2><p>{image ? `${image.fileName} · ${image.width} × ${image.height} · ${image.pxPerUm} px/µm` : "No image open"}</p></div><Beaker size={22} /></header>
          {selected.source && <div className="lab-controls"><label><span>TIFF planes</span><select value={projection} onChange={(event) => setProjection(event.target.value as "first" | "max")}><option value="first">First plane</option><option value="max">Max projection</option></select></label><label><span>Optional nuclei / neurite mask</span><button className="secondary-button" onClick={() => auxiliaryInput.current?.click()}><FileInput size={14} /> {auxiliary?.name ?? "Choose mask"}</button></label></div>}
          {kind === "tracking" && <><div className="lab-controls"><label><span>Sequence condition</span><select value={trackingCondition} onChange={(event) => setTrackingCondition(event.target.value)}>{conditions.map((condition) => <option key={condition}>{condition}</option>)}</select></label><label><span>Frame interval (min)</span><input type="number" min="0.01" value={frameInterval} onChange={(event) => setFrameInterval(Math.max(.01, Number(event.target.value)))} /></label><label><span>Maximum displacement (µm)</span><input type="number" min="0.01" value={maxDisplacement} onChange={(event) => setMaxDisplacement(Math.max(.01, Number(event.target.value)))} /></label></div><ol className="sequence-order" aria-label="Tracking sequence order">{trackingImages.map((entry, index) => <li key={entry.id}><span>{index + 1}</span>{entry.fileName}</li>)}</ol></>}
          {kind === "line-profile" && <div className="line-controls">{(["x1", "y1", "x2", "y2"] as const).map((key) => <label key={key}><span>{key.toUpperCase()}</span><input type="number" value={line[key]} onChange={(event) => setLine((value) => ({ ...value, [key]: Number(event.target.value) }))} /></label>)}</div>}
          <div className="assay-runbar">{running ? <button className="run-button cancel" onClick={() => abortRef.current?.abort()}><Square size={13} /> Cancel</button> : <button className="run-button" onClick={() => void execute()} disabled={!image}><Play size={14} /> Run locally</button>}<span><Activity size={13} /> {running ? "Worker is analyzing local pixels…" : "No network path"}</span></div>
          {error && <div className="lab-error" role="alert">{error}</div>}
          {result !== undefined && <div className="assay-result"><header><div><span className="eyebrow">Completed</span><h3>Result summary</h3></div><button className="secondary-button" onClick={() => download(`${kind}-result.json`, `${JSON.stringify(result, null, 2)}\n`, "application/json")}><Download size={14} /> JSON</button></header><div className="result-grid">{summary.map(([label, value]) => <div key={label}><span>{label}</span><strong>{value}</strong></div>)}</div><details><summary>Inspect full deterministic result</summary><pre>{JSON.stringify(result, null, 2)}</pre></details></div>}
        </section>
        <aside className="protocol-panel"><header><span className="eyebrow">Reproducibility</span><h2>Protocols</h2><p>Versioned, validated and applied atomically.</p></header><button className="wide-secondary" onClick={saveProtocol}><Save size={14} /> Save current</button><button className="wide-secondary" onClick={() => protocolInput.current?.click()}><FileInput size={14} /> Open .ccproto.json</button><div className="protocol-list">{protocols.map((protocol) => <button key={protocol.id} onClick={() => applyProtocol(protocol)}><strong>{protocol.name}</strong><span>{protocol.model.name} · {protocol.calibration.pxPerUm} px/µm</span></button>)}{!protocols.length && <p>No saved protocols yet.</p>}</div></aside>
      </div>
      <input ref={auxiliaryInput} className="sr-only" type="file" accept="image/*,.tif,.tiff,.ome.tif,.ome.tiff" onChange={(event) => setAuxiliary(event.target.files?.[0])} />
      <input ref={protocolInput} className="sr-only" type="file" accept=".json,.ccproto.json,application/json" onChange={(event) => void loadProtocol(event.target.files?.[0])} />
    </main>
  );
}
