import { ChevronDown, Download, Gauge, HardDriveDownload, Info, Scan, SlidersHorizontal, Target } from "lucide-react";
import { getModelManifest } from "../models/catalog";
import type { EditTool, WorkspaceImage } from "../app/types";
import type { GroundTruthMetrics } from "../analysis";

export interface AnalysisSettings {
  modelId: "cpsam_v2" | "cp-cyto3" | "sd-fluo";
  pxPerUm: number;
  confidence: number;
  diameterUm: number;
  backgroundSubtract: boolean;
  watershedSplit: boolean;
}

export const MODEL_OPTIONS = [
  { id: "cpsam_v2" as const, name: "Cellpose-SAM v2", detail: "Best generalist", size: "~588 MB" },
  { id: "cp-cyto3" as const, name: "Cellpose cyto3", detail: "Fast cytoplasm", size: "~26 MB" },
  { id: "sd-fluo" as const, name: "StarDist fluorescence", detail: "Fast nuclei", size: "~32 MB" },
];

interface InspectorProps {
  image?: WorkspaceImage;
  tool: EditTool;
  onTool: (tool: EditTool) => void;
  onMetadata: (patch: Pick<WorkspaceImage, "note" | "reviewConfidence">) => void;
  truthMetrics?: GroundTruthMetrics;
  onClearValidation: (target: "truth" | "rois") => void;
  settings: AnalysisSettings;
  onSettings: (settings: AnalysisSettings) => void;
  count: number;
  meanDiameter: number;
  onModelFile: () => void;
  onExport: () => void;
  modelReady: boolean;
}

export function Inspector({ image, tool, onTool, onMetadata, truthMetrics, onClearValidation, settings, onSettings, count, meanDiameter, onModelFile, onExport, modelReady }: InspectorProps) {
  const selected = MODEL_OPTIONS.find((model) => model.id === settings.modelId)!;
  const buildRequired = getModelManifest(settings.modelId).artifact.availability === "buildRequired";
  const patch = <K extends keyof AnalysisSettings>(key: K, value: AnalysisSettings[K]) => onSettings({ ...settings, [key]: value });
  return (
    <aside className="inspector" aria-label="Analysis settings">
      <div className="inspector-heading">
        <div><span className="eyebrow">Context</span><h2>Analyze</h2></div>
        <SlidersHorizontal size={18} />
      </div>

      <section className="metric-strip" aria-label="Detection summary">
        <div><span>Objects</span><strong>{count.toLocaleString()}</strong></div>
        <div><span>Mean ø</span><strong>{meanDiameter ? `${meanDiameter.toFixed(1)} µm` : "—"}</strong></div>
      </section>

      <section className="inspector-section">
        <div className="section-label"><span>Model</span><em className={modelReady ? "ready" : "needed"}>{modelReady ? "Ready" : "Weights needed"}</em></div>
        <label className="select-field">
          <select value={settings.modelId} onChange={(event) => patch("modelId", event.target.value as AnalysisSettings["modelId"])} aria-label="Segmentation model">
            {MODEL_OPTIONS.map((model) => <option key={model.id} value={model.id}>{model.name}</option>)}
          </select>
          <ChevronDown size={15} />
        </label>
        <div className="model-detail"><span>{selected.detail}</span><span>{selected.size}</span></div>
        {!modelReady && <button className="wide-secondary" onClick={onModelFile} disabled={buildRequired}><HardDriveDownload size={16} /> {buildRequired ? "Validated build pending" : "Add verified model file"}</button>}
      </section>

      <section className="inspector-section">
        <div className="section-label"><span>Calibration</span><Info size={14} /></div>
        <label className="unit-field"><span>Pixels per µm</span><input type="number" min="0.001" step="0.01" value={settings.pxPerUm} onChange={(event) => patch("pxPerUm", Math.max(.001, Number(event.target.value)))} /><em>px/µm</em></label>
      </section>

      <section className="inspector-section parameters">
        <div className="section-label"><span>Parameters</span><Gauge size={14} /></div>
        <label className="range-field">
          <span>Confidence <output>{Math.round(settings.confidence * 100)}%</output></span>
          <input type="range" min="0" max="1" step="0.01" value={settings.confidence} onChange={(event) => patch("confidence", Number(event.target.value))} />
        </label>
        <label className="unit-field"><span>Expected diameter</span><input type="number" min="0" step="1" value={settings.diameterUm} onChange={(event) => patch("diameterUm", Math.max(0, Number(event.target.value)))} /><em>µm</em></label>
        <details>
          <summary>Advanced <ChevronDown size={14} /></summary>
          <label className="toggle-row"><span>Subtract background<small>Rolling-ball correction</small></span><input type="checkbox" checked={settings.backgroundSubtract} onChange={(event) => patch("backgroundSubtract", event.target.checked)} /></label>
          <label className="toggle-row"><span>Split touching cells<small>Watershed refinement</small></span><input type="checkbox" checked={settings.watershedSplit} onChange={(event) => patch("watershedSplit", event.target.checked)} /></label>
        </details>
      </section>

      <section className="inspector-section validation-section">
        <div className="section-label"><span>Validation & regions</span><Target size={14} /></div>
        <div className="validation-tools">
          <button className={tool === "ground-truth" ? "active" : ""} onClick={() => onTool("ground-truth")} disabled={!image}><Target size={14} /> Truth</button>
          <button className={tool === "roi-include" ? "active" : ""} onClick={() => onTool("roi-include")} disabled={!image}><Scan size={14} /> Include</button>
          <button className={tool === "roi-exclude" ? "active exclude" : ""} onClick={() => onTool("roi-exclude")} disabled={!image}><Scan size={14} /> Exclude</button>
        </div>
        <p className="validation-counts"><span>{image?.groundTruth.length ?? 0} truth marks</span><span>{image?.rois.length ?? 0} regions</span></p>
        {image?.groundTruth.length ? <div className="truth-score"><span><b>{Math.round((truthMetrics?.precision ?? 0) * 100)}%</b>Precision</span><span><b>{Math.round((truthMetrics?.recall ?? 0) * 100)}%</b>Recall</span><span><b>{Math.round((truthMetrics?.f1 ?? 0) * 100)}%</b>F1</span></div> : null}
        {(image?.groundTruth.length || image?.rois.length) ? <div className="validation-clear"><button onClick={() => onClearValidation("truth")} disabled={!image?.groundTruth.length}>Clear truth</button><button onClick={() => onClearValidation("rois")} disabled={!image?.rois.length}>Clear regions</button></div> : null}
        <label className="compact-field"><span>Review confidence</span><select disabled={!image} value={image?.reviewConfidence ?? "high"} onChange={(event) => onMetadata({ note: image?.note ?? "", reviewConfidence: event.target.value as WorkspaceImage["reviewConfidence"] })}><option value="high">High</option><option value="medium">Medium</option><option value="low">Low</option></select></label>
        <label className="note-field"><span>Image notes</span><textarea disabled={!image} value={image?.note ?? ""} onChange={(event) => onMetadata({ note: event.target.value, reviewConfidence: image?.reviewConfidence ?? "high" })} placeholder="Protocol deviations, morphology, review notes…" /></label>
      </section>

      <button className="export-button" onClick={onExport} disabled={!count}><Download size={16} /> Export measurements <kbd>⌘E</kbd></button>
    </aside>
  );
}
