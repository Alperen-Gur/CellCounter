import { Download, Play, Plus, Square } from "lucide-react";
import type { RunState, WorkspaceImage } from "../app/types";

interface WorkspaceToolbarProps {
  image?: WorkspaceImage;
  runState: RunState;
  modelLabel: string;
  onImport: () => void;
  onRun: () => void;
  onCancel: () => void;
  onExport: () => void;
}

export function WorkspaceToolbar({ image, runState, modelLabel, onImport, onRun, onCancel, onExport }: WorkspaceToolbarProps) {
  const isRunning = runState === "preparing" || runState === "running";
  return (
    <div className="workspace-toolbar">
      <div className="image-heading">
        <span className="eyebrow">Analysis workspace</span>
        <h1>{image?.fileName ?? "Untitled study"}</h1>
        {image && <p>{image.width.toLocaleString()} × {image.height.toLocaleString()} px <i /> {image.cells.length} objects</p>}
      </div>
      <div className="toolbar-actions">
        <button className="secondary-button" onClick={onImport}><Plus size={16} /> Import</button>
        <button className="secondary-button export-compact" onClick={onExport} disabled={!image?.cells.length}><Download size={16} /> Export</button>
        {isRunning ? (
          <button className="run-button cancel" onClick={onCancel}><Square size={14} fill="currentColor" /> Cancel</button>
        ) : (
          <button className="run-button" onClick={onRun} disabled={!image}>
            <Play size={16} fill="currentColor" />
            <span className="run-label">Run <em>· {modelLabel}</em></span>
          </button>
        )}
      </div>
    </div>
  );
}
