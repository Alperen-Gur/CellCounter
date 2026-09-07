import { Play, Plus, SlidersHorizontal, Square } from "lucide-react";
import type { RunState, WorkspaceImage } from "../app/types";

interface WorkspaceToolbarProps {
  image?: WorkspaceImage; imageCount: number; runState: RunState;
  previewCount?: number; previewMatches: boolean; showingPreview: boolean; modelReady: boolean;
  scope: "image" | "all"; onScopeChange(scope: "image" | "all"): void;
  onImport(): void; onRun(): void; onProcess(all: boolean): void; onCancel(): void; onInspector(): void;
}

export function WorkspaceToolbar({ image, imageCount, runState, previewCount, previewMatches, showingPreview, modelReady, scope, onScopeChange, onImport, onRun, onProcess, onCancel, onInspector }: WorkspaceToolbarProps) {
  const busy = runState === "preparing" || runState === "running";
  const readyToProcess = showingPreview && previewMatches;
  return <div className="workspace-toolbar">
    <div className="image-heading"><h1 title={image?.fileName}>{image?.fileName ?? "Analyze images"}</h1><p>{image ? showingPreview ? `${previewCount ?? 0} objects · Preview${previewMatches ? " · settings match" : " · settings changed"}` : `${image.width.toLocaleString()} × ${image.height.toLocaleString()} px · ${image.analysis ? `${image.cells.length} objects · Saved result` : "Source image"}` : "Import a microscopy image to begin"}</p></div>
    <div className="toolbar-actions">
      {!image && <button className="run-button" onClick={onImport}><Plus size={16} /> Import images</button>}
      {image && <>
        {readyToProcess && imageCount > 1 && <select className="process-scope" aria-label="Processing scope" value={scope} onChange={(event) => onScopeChange(event.target.value as "image" | "all")}><option value="image">This image</option><option value="all">All {imageCount} images</option></select>}
        {busy ? <button className="secondary-button cancel" onClick={onCancel}><Square size={15} /> Cancel</button> : <button className="run-button" disabled={!image.sourceLoaded || !modelReady} onClick={() => readyToProcess ? onProcess(scope === "all") : onRun()}><Play size={16} />{readyToProcess ? scope === "all" && imageCount > 1 ? "Process all" : "Process image" : "Preview image"}</button>}
      </>}
      {image && <button className="secondary-button inspector-toggle" onClick={onInspector} aria-controls="analysis-inspector"><SlidersHorizontal size={16} /><span>Inspector</span></button>}
    </div>
  </div>;
}
