import type { EditorMode } from "../../../kernel/types";
import { useAppStore } from "../../../kernel/store/store";
import { useKeymap } from "../../../components/useKeymap";
import type { MaskEditorApi } from "./useMaskEditor";

export interface UseEditingKeymapArgs { editor: MaskEditorApi; enabled?: boolean }

/** Bind actual editor actions to the single shared shortcut registry. */
export function useEditingKeymap({ editor, enabled = true }: UseEditingKeymapArgs): void {
  const mode = (next: EditorMode) => {
    useAppStore.getState().setEditorMode(next);
    if (next !== "view") useAppStore.getState().setSelectedCellIds(new Set());
  };
  useKeymap("editor", {
    modeView: () => mode("view"), modeAdd: () => mode("add"), modeRemove: () => mode("remove"),
    modeMerge: () => mode("merge"), modeSplit: () => mode("split"),
    modeManualCount: () => mode("manualCount"), modeAnnotate: () => mode("annotate"),
    undo: () => editor.undo(), redo: () => editor.redo(),
    delete: () => { editor.remove([...useAppStore.getState().selectedCellIds]); useAppStore.getState().setSelectedCellIds(new Set()); },
    escape: () => { mode("view"); useAppStore.getState().setSelectedCellIds(new Set()); },
  }, { enabled });
}
export default useEditingKeymap;
