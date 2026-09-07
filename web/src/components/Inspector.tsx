import { useEffect, useRef, useState, type ReactNode } from "react";
import { ChevronDown, Download, Scan, Target, X } from "lucide-react";
import { getModelManifest } from "../models/catalog";
import type { ModelId } from "../domain/types";
import type { EditTool, WorkspaceCell, WorkspaceImage } from "../app/types";
import type { GroundTruthMetrics } from "../analysis";

export interface AnalysisSettings {
  modelId: ModelId;
  sourceChannel?: number;
  projection?: "first" | "max" | "mean" | "sum";
  thresholdMethod?: "otsu" | "triangle" | "adaptive" | "manual";
  manualThreshold?: number;
  invert?: boolean;
  minimumAreaPx?: number;
  pxPerUm: number;
  confidence: number;
  diameterUm: number;
  backgroundSubtract: boolean;
  watershedSplit: boolean;
}

export const MODEL_OPTIONS = [
  { id: "classical" as const, name: "Classical threshold + watershed", detail: "Threshold-based segmentation", size: "Built in" },
  { id: "cpsam_v2" as const, name: "Cellpose-SAM v2", detail: "General cell segmentation", size: "~588 MB" },
  { id: "cp-cyto3" as const, name: "Cellpose cyto3", detail: "Cytoplasm segmentation", size: "~26 MB" },
  { id: "sd-fluo" as const, name: "StarDist fluorescence", detail: "Fluorescent nuclei", size: "~32 MB" },
];

interface InspectorProps {
  image?: WorkspaceImage; selectedCell?: WorkspaceCell; showingPreview?: boolean;
  tool: EditTool; onTool: (tool: EditTool) => void;
  onMetadata: (patch: Pick<WorkspaceImage, "note" | "reviewConfidence">) => void;
  truthMetrics?: GroundTruthMetrics; onClearValidation: (target: "truth" | "rois") => void;
  settings: AnalysisSettings; onSettings: (settings: AnalysisSettings) => void;
  count: number; meanDiameter: number; onModelFile: () => void; onExport: () => void; modelReady: boolean;
  mobileOpen: boolean; onClose: () => void; children?: ReactNode;
}

export function Inspector({ image, selectedCell, showingPreview, tool, onTool, onMetadata, truthMetrics, onClearValidation, settings, onSettings, count, meanDiameter, onModelFile, onExport, modelReady, mobileOpen, onClose, children }: InspectorProps) {
  const [section, setSection] = useState<"setup" | "selection" | "image">("setup");
  const [narrow, setNarrow] = useState(() => typeof matchMedia === "function" && matchMedia("(max-width: 1000px)").matches);
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    if (typeof matchMedia !== "function") return;
    const query = matchMedia("(max-width: 1000px)");
    const update = () => setNarrow(query.matches);
    query.addEventListener("change", update);
    return () => query.removeEventListener("change", update);
  }, []);
  useEffect(() => {
    if (!narrow) { if (mobileOpen) onClose(); return; }
    if (mobileOpen && !dialog.current?.open) dialog.current?.showModal();
    if (!mobileOpen && dialog.current?.open) dialog.current?.close();
  }, [narrow, mobileOpen, onClose]);
  const classical = settings.modelId === "classical";
  const buildRequired = !classical && getModelManifest(settings.modelId).artifact.availability === "buildRequired";
  const patch = <K extends keyof AnalysisSettings>(key: K, value: AnalysisSettings[K]) => onSettings({ ...settings, [key]: value });
  const content = <aside id="analysis-inspector" className="inspector" aria-label="Analysis inspector">
    <div className="inspector-heading"><h2>Inspector</h2>{narrow && <button className="icon-button" onClick={onClose} aria-label="Close inspector"><X size={20} /></button>}</div>
    <div className="inspector-tabs" role="group" aria-label="Inspector sections">{(["setup", "selection", "image"] as const).map((id) => <button key={id} aria-pressed={section === id} onClick={() => setSection(id)}>{id === "setup" ? "Setup" : id === "selection" ? "Selection" : "Image"}{id === "selection" && selectedCell ? <i aria-hidden="true" title="Object selected" /> : null}</button>)}</div>
    {section === "setup" && <>
      <section className="inspector-section"><div className="section-label"><span>Analysis method</span><em className={modelReady ? "ready" : "needed"}>{modelReady ? "Available" : "Unavailable"}</em></div><label className="select-field"><select value={settings.modelId} onChange={(event) => patch("modelId", event.target.value as ModelId)} aria-label="Segmentation model">{MODEL_OPTIONS.map((model) => <option key={model.id} value={model.id}>{model.name}</option>)}</select><ChevronDown size={15} /></label>
        <p className="field-help">{classical ? "Finds objects by intensity. Preview a representative image to check the result." : modelReady ? "Ready to analyze on this device." : "Not available in this browser version. Choose the built-in classical method to continue."}</p>
        {!modelReady && !buildRequired && <button className="wide-secondary" onClick={onModelFile}>Add model file</button>}
      </section>
      {classical && <section className="inspector-section parameters"><div className="section-label"><span>Detection</span></div>
        <label className="compact-field"><span>Threshold method</span><select value={settings.thresholdMethod ?? "otsu"} onChange={(event) => patch("thresholdMethod", event.target.value as AnalysisSettings["thresholdMethod"])}><option value="otsu">Otsu (automatic)</option><option value="triangle">Triangle (automatic)</option><option value="adaptive">Adaptive local threshold</option><option value="manual">Manual</option></select></label>
        {settings.thresholdMethod === "manual" && <label className="range-field"><span>Normalized threshold <output>{(settings.manualThreshold ?? .5).toFixed(2)}</output></span><input type="range" min="0" max="1" step=".01" value={settings.manualThreshold ?? .5} onChange={(event) => patch("manualThreshold", Number(event.target.value))} /></label>}
        <label className="unit-field"><span>Minimum area</span><input type="number" min="1" value={settings.minimumAreaPx ?? 9} onChange={(event) => patch("minimumAreaPx", Math.max(1, Number(event.target.value)))} /><em>px²</em></label>
        <label className="toggle-row"><span>Dark objects on light background</span><input type="checkbox" checked={settings.invert ?? false} onChange={(event) => patch("invert", event.target.checked)} /></label>
        <label className="toggle-row"><span>Split touching cells</span><input type="checkbox" checked={settings.watershedSplit} onChange={(event) => patch("watershedSplit", event.target.checked)} /></label>
      </section>}
      <details className="inspector-section"><summary>Source & calibration</summary>
        {classical && <><label className="compact-field"><span>Source channel</span><select value={settings.sourceChannel ?? -1} onChange={(event) => patch("sourceChannel", Number(event.target.value))}><option value={-1}>Luminance / grayscale</option>{Array.from({ length: image?.originalFile ? image.samplesPerPixel ?? 1 : 3 }, (_, index) => <option key={index} value={index}>Channel {index + 1}</option>)}</select></label><label className="compact-field"><span>Z projection</span><select value={settings.projection ?? "first"} onChange={(event) => patch("projection", event.target.value as AnalysisSettings["projection"])}><option value="first">First plane</option><option value="max">Maximum</option><option value="mean">Mean</option><option value="sum">Sum</option></select></label></>}
        <label className="unit-field"><span>Pixels per µm</span><input type="number" min="0.001" step="0.01" value={settings.pxPerUm} onChange={(event) => patch("pxPerUm", Math.max(.001, Number(event.target.value)))} /><em>px/µm</em></label><p className="field-help">{image?.calibrationSource && image.calibrationSource !== "default" ? `Calibration source: ${image.calibrationSource}.` : "Scale is unverified. Set the image calibration before interpreting measurements in µm."}</p>
      </details>
      <details className="inspector-section parameters"><summary>Advanced settings</summary>
        {!classical && <label className="range-field"><span>Confidence <output>{Math.round(settings.confidence * 100)}%</output></span><input type="range" min="0" max="1" step="0.01" value={settings.confidence} onChange={(event) => patch("confidence", Number(event.target.value))} /></label>}
        <label className="unit-field"><span>Expected diameter</span><input type="number" min="0" step="1" value={settings.diameterUm} onChange={(event) => patch("diameterUm", Math.max(0, Number(event.target.value)))} /><em>µm</em></label>
        <label className="toggle-row"><span>Subtract background<small>{classical ? "Local mean · 50 px radius" : "Rolling-ball correction"}</small></span><input type="checkbox" checked={settings.backgroundSubtract} onChange={(event) => patch("backgroundSubtract", event.target.checked)} /></label>
        {!classical && <label className="toggle-row"><span>Split touching cells</span><input type="checkbox" checked={settings.watershedSplit} onChange={(event) => patch("watershedSplit", event.target.checked)} /></label>}
      </details>
    </>}
    {section === "selection" && <>
      <section className="inspector-section"><div className="section-label">{showingPreview ? "Preview selection" : "Selected object"}</div>{selectedCell ? <><strong className="object-identity">{selectedCell.id}</strong><dl className="image-facts"><div><dt>Diameter</dt><dd>{selectedCell.diameterUm.toFixed(2)} µm</dd></div><div><dt>Area</dt><dd>{selectedCell.areaUm2?.toFixed(2) ?? "—"} µm²</dd></div><div><dt>Center</dt><dd>{selectedCell.cx.toFixed(1)}, {selectedCell.cy.toFixed(1)} px</dd></div><div><dt>Review</dt><dd>{selectedCell.reviewed ? "Accepted" : "Unreviewed"}</dd></div></dl>{showingPreview && <p className="field-help">Process this preview to save it for correction and review.</p>}</> : <p className="field-help">Select an object in the image or measurement table to inspect it here.</p>}</section>
      <details className="inspector-section validation-section"><summary>Validation & regions</summary><p className="field-help">Mark reference objects or draw regions in the image.</p><div className="validation-tools"><button className={tool === "ground-truth" ? "active" : ""} onClick={() => onTool("ground-truth")} disabled={!image || showingPreview}><Target size={14} /> Truth</button><button className={tool === "roi-include" ? "active" : ""} onClick={() => onTool("roi-include")} disabled={!image || showingPreview}><Scan size={14} /> Include</button><button className={tool === "roi-exclude" ? "active exclude" : ""} onClick={() => onTool("roi-exclude")} disabled={!image || showingPreview}><Scan size={14} /> Exclude</button></div><p className="validation-counts">{image?.groundTruth.length ?? 0} truth marks · {image?.rois.length ?? 0} regions</p>
        {image?.groundTruth.length ? <div className="truth-score"><span><b>{Math.round((truthMetrics?.precision ?? 0) * 100)}%</b>Precision</span><span><b>{Math.round((truthMetrics?.recall ?? 0) * 100)}%</b>Recall</span><span><b>{Math.round((truthMetrics?.f1 ?? 0) * 100)}%</b>F1</span></div> : null}
        <div className="validation-clear"><button onClick={() => onClearValidation("truth")} disabled={!image?.groundTruth.length || showingPreview}>Clear truth</button><button onClick={() => onClearValidation("rois")} disabled={!image?.rois.length || showingPreview}>Clear regions</button></div>
      </details>
    </>}
    {section === "image" && <>
      <section className="inspector-section"><div className="section-label">Image information</div>{image ? <><p className="object-identity">{image.fileName}</p><dl className="image-facts"><div><dt>Dimensions</dt><dd>{image.width} × {image.height} px</dd></div><div><dt>Planes</dt><dd>{image.planeCount ?? 1}</dd></div><div><dt>Calibration</dt><dd>{image.pxPerUm} px/µm</dd></div><div><dt>Scale source</dt><dd>{image.calibrationSource === "default" || !image.calibrationSource ? "Unverified default" : image.calibrationSource}</dd></div></dl></> : <p className="field-help">Import an image to see its source information.</p>}</section>
      {children}
      <section className="inspector-section"><label className="compact-field"><span>Review confidence</span><select disabled={!image} value={image?.reviewConfidence ?? "high"} onChange={(event) => onMetadata({ note: image?.note ?? "", reviewConfidence: event.target.value as WorkspaceImage["reviewConfidence"] })}><option value="high">High</option><option value="medium">Medium</option><option value="low">Low</option></select></label><label className="note-field"><span>Image notes</span><textarea disabled={!image} value={image?.note ?? ""} onChange={(event) => onMetadata({ note: event.target.value, reviewConfidence: image?.reviewConfidence ?? "high" })} placeholder="Protocol deviations, morphology, review notes…" /></label></section>
    </>}
    <section className="inspector-summary" aria-label="Detection summary"><div><span>{showingPreview ? "Preview objects" : "Included objects"}</span><strong>{count.toLocaleString()}</strong></div><div><span>Mean diameter</span><strong>{meanDiameter ? `${meanDiameter.toFixed(1)} µm` : "—"}</strong></div></section>
    {(!image?.calibrationSource || image.calibrationSource === "default") && <p className="field-help">Scale unverified · measurements use {settings.pxPerUm} px/µm.</p>}
    <button className="export-button" onClick={onExport} disabled={!image?.cells.length}><Download size={16} /> Export saved measurements</button>
  </aside>;
  return narrow ? <dialog ref={dialog} className="inspector-sheet" aria-label="Analysis inspector" onCancel={onClose} onClose={onClose} onClick={(event) => { if (event.target === event.currentTarget) onClose(); }}>{content}</dialog> : content;
}
