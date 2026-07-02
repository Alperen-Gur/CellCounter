/**
 * pages/results/editing/EditingToolbar.tsx — the mode pill + undo/redo
 * (feature task `feat-mask-editing`).
 *
 * Ported from `EditorModeToolbar` in `Views/Results/EditableOverlay.swift`. A
 * compact segmented control that drives `store.editorMode` (the FROZEN
 * SessionSlice key), plus undo / redo buttons wired to the engine and an inline
 * manual-marker-diameter stepper shown only in Count mode.
 *
 * The Remove button doubles as "delete current selection" when a multi-select
 * set is active (Swift `onRemoveTapped`): one click clears the whole selection
 * instead of switching mode.
 *
 * This is chrome only — no gesture handling (that is EditingSurface). It reads
 * store state + the `MaskEditorApi` and calls their setters/methods.
 */

import type { EditorMode } from "../../../kernel/types";
import { useAppStore } from "../../../kernel/store/store";
import type { MaskEditorApi } from "./useMaskEditor";

interface ModeDef {
  mode: EditorMode;
  label: string;
  glyph: string;
  /** Single-key hint shown in the tooltip (bound by feat-directory-nav-keyboard). */
  key: string;
}

// Order + keys mirror EditorModeToolbar + KeyboardShortcutsSheet (V/A/R/M/C/G),
// with Split added as the first-class edit this port elevates (S).
const MODES: ModeDef[] = [
  { mode: "view", label: "View", glyph: "◉", key: "V" },
  { mode: "add", label: "Add", glyph: "＋", key: "A" },
  { mode: "remove", label: "Remove", glyph: "－", key: "R" },
  { mode: "merge", label: "Merge", glyph: "⧉", key: "M" },
  { mode: "split", label: "Split", glyph: "✂", key: "S" },
  { mode: "manualCount", label: "Count", glyph: "①", key: "C" },
  { mode: "annotate", label: "Annotate", glyph: "✜", key: "G" },
];

export interface EditingToolbarProps {
  editor: MaskEditorApi;
}

export function EditingToolbar({ editor }: EditingToolbarProps) {
  const editorMode = useAppStore((s) => s.editorMode);
  const setEditorMode = useAppStore((s) => s.setEditorMode);
  const selectedCellIds = useAppStore((s) => s.selectedCellIds);
  const setSelectedCellIds = useAppStore((s) => s.setSelectedCellIds);
  const manualMarkerDiameterUm = useAppStore((s) => s.manualMarkerDiameterUm);
  const setManualMarkerDiameterUm = useAppStore((s) => s.setManualMarkerDiameterUm);

  const selectMode = (m: EditorMode) => {
    // Remove button doubles as "delete selection" when a set is active.
    if (m === "remove" && selectedCellIds.size > 0) {
      editor.remove([...selectedCellIds]);
      setSelectedCellIds(new Set());
      return;
    }
    // Leaving view mode drops the selection set (clicks change meaning).
    if (m !== "view" && editorMode === "view") {
      setSelectedCellIds(new Set());
    }
    setEditorMode(m);
  };

  return (
    <div className="cc-edit-toolbar" role="toolbar" aria-label="Mask editing tools">
      <div className="cc-edit-toolbar__modes">
        {MODES.map((m) => {
          const active = editorMode === m.mode;
          return (
            <button
              key={m.mode}
              type="button"
              className={
                "cc-edit-toolbar__btn" +
                (active ? " cc-edit-toolbar__btn--active" : "")
              }
              aria-pressed={active}
              title={`${m.label} (${m.key})`}
              onClick={() => selectMode(m.mode)}
            >
              <span className="cc-edit-toolbar__glyph" aria-hidden="true">
                {m.glyph}
              </span>
              <span className="cc-edit-toolbar__label">{m.label}</span>
            </button>
          );
        })}
      </div>

      {editorMode === "manualCount" && (
        <div className="cc-edit-toolbar__stepper" aria-label="Manual marker diameter">
          <button
            type="button"
            className="cc-edit-toolbar__step"
            disabled={manualMarkerDiameterUm <= 5}
            onClick={() =>
              setManualMarkerDiameterUm(Math.max(5, manualMarkerDiameterUm - 1))
            }
            aria-label="Decrease diameter"
          >
            −
          </button>
          <span className="cc-edit-toolbar__value">
            {Math.round(manualMarkerDiameterUm)} µm
          </span>
          <button
            type="button"
            className="cc-edit-toolbar__step"
            disabled={manualMarkerDiameterUm >= 100}
            onClick={() =>
              setManualMarkerDiameterUm(Math.min(100, manualMarkerDiameterUm + 1))
            }
            aria-label="Increase diameter"
          >
            +
          </button>
        </div>
      )}

      <div className="cc-edit-toolbar__sep" aria-hidden="true" />

      <div className="cc-edit-toolbar__history">
        <button
          type="button"
          className="cc-edit-toolbar__btn"
          disabled={!editor.canUndo}
          title="Undo (⌘Z)"
          onClick={() => editor.undo()}
        >
          <span className="cc-edit-toolbar__glyph" aria-hidden="true">
            ↺
          </span>
          <span className="cc-edit-toolbar__label">Undo</span>
        </button>
        <button
          type="button"
          className="cc-edit-toolbar__btn"
          disabled={!editor.canRedo}
          title="Redo (⌘⇧Z)"
          onClick={() => editor.redo()}
        >
          <span className="cc-edit-toolbar__glyph" aria-hidden="true">
            ↻
          </span>
          <span className="cc-edit-toolbar__label">Redo</span>
        </button>
      </div>
    </div>
  );
}

export default EditingToolbar;
