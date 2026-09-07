import { Combine, Crosshair, Expand, MousePointer2, Redo2, Scissors, Undo2, UserRoundPlus } from "lucide-react";
import type { EditTool } from "../app/types";

const tools: Array<{ id: EditTool; label: string; key: number; icon: typeof Crosshair }> = [
  { id: "inspect", label: "Inspect", key: 1, icon: MousePointer2 },
  { id: "add", label: "Add", key: 2, icon: UserRoundPlus },
  { id: "remove", label: "Remove", key: 3, icon: Crosshair },
  { id: "resize", label: "Resize", key: 4, icon: Expand },
  { id: "merge", label: "Merge", key: 5, icon: Combine },
  { id: "split", label: "Split", key: 6, icon: Scissors },
];

export function EditDock({ active, onChange, canUndo, onUndo, canRedo, onRedo, readOnly = false }: { active: EditTool; onChange: (tool: EditTool) => void; canUndo: boolean; onUndo: () => void; canRedo: boolean; onRedo: () => void; readOnly?: boolean }) {
  return (
    <div className="edit-dock" aria-label="Correction tools">
      {tools.map(({ id, label, key, icon: Icon }) => (
        <button key={id} className={active === id ? "active" : ""} onClick={() => onChange(id)} disabled={readOnly && id !== "inspect"} aria-pressed={active === id} title={`${label} · ${key}`}>
          <Icon size={17} /><span>{label}</span>
        </button>
      ))}
      <span className="dock-divider" />
      <button onClick={onUndo} disabled={!canUndo} title="Undo correction"><Undo2 size={17} /><span>Undo</span></button>
      <button onClick={onRedo} disabled={!canRedo} title="Redo correction"><Redo2 size={17} /><span>Redo</span></button>
    </div>
  );
}
