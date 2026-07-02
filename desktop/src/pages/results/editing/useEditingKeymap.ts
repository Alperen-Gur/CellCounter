/**
 * pages/results/editing/useEditingKeymap.ts — keyboard bindings for mask editing
 * (feature task `feat-mask-editing`).
 *
 * The task contract requires the editor interactions to work from the keyboard:
 * undo (⌘Z) / redo (⌘⇧Z, ⌘Y), Delete/Backspace to remove the selection, Escape
 * to clear, and the V/A/R/M/S/C/G mode switches (ported from the `.onKeyPress`
 * handlers in `Views/Results/EditableOverlay.swift`).
 *
 * Ownership note (avoids double-binding, §feat-directory-nav-keyboard boundary):
 * the global `kernel/shortcuts/keymap.ts` reserves the `editor` scope +
 * action ids (modeView…redo, delete, escape) but ships them UNBOUND (empty
 * `keys`). That feature's `useKeymap` hook will later populate + dispatch them.
 * To coexist safely we consult `actionKeys("editor", …)`:
 *   - while the editor scope is still unbound (the current frozen state) we own
 *     ALL editor keys here so editing is usable today;
 *   - once that feature binds them, we DEFER the mode-switch + delete/escape keys
 *     to it and keep only undo/redo (edit-specific, always safe to own) — no key
 *     is handled twice.
 *
 * This hook lives entirely in the feature's own directory and never edits
 * `components/useKeymap.ts` (owned by the other task). It calls only store
 * setters + the `MaskEditorApi` — no engine logic is duplicated.
 */

import { useEffect } from "react";

import type { EditorMode } from "../../../kernel/types";
import { useAppStore } from "../../../kernel/store/store";
import { actionKeys } from "../../../kernel/shortcuts/keymap";
import type { MaskEditorApi } from "./useMaskEditor";

/** True when the global keymap has populated the `editor` scope bindings. */
function editorScopeBound(): boolean {
  // Any populated editor action means the directory-nav-keyboard feature has
  // taken ownership of the mode/delete/escape keys.
  const probes = ["modeView", "modeAdd", "delete", "undo", "escape"];
  return probes.some((a) => actionKeys("editor", a).length > 0);
}

/** Single-key → EditorMode map (Swift EditableOverlay .onKeyPress scheme + S=split). */
const MODE_KEYS: Record<string, EditorMode> = {
  v: "view",
  a: "add",
  r: "remove",
  m: "merge",
  s: "split",
  c: "manualCount",
  g: "annotate",
};

export interface UseEditingKeymapArgs {
  editor: MaskEditorApi;
  /** When false the listener is not installed (e.g. Results not focused). */
  enabled?: boolean;
}

/**
 * Bind the editor keyboard scheme while `enabled`. Handlers dispatch to the
 * store (mode / selection) and the engine (undo / redo / remove).
 */
export function useEditingKeymap({ editor, enabled = true }: UseEditingKeymapArgs): void {
  useEffect(() => {
    if (!enabled) return;
    const deferModeKeys = editorScopeBound();

    const onKeyDown = (e: KeyboardEvent) => {
      // Never hijack typing into inputs / textareas / contenteditable.
      const target = e.target as HTMLElement | null;
      if (
        target &&
        (target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.isContentEditable)
      ) {
        return;
      }

      const mod = e.metaKey || e.ctrlKey;
      const key = e.key;
      const lower = key.length === 1 ? key.toLowerCase() : key;

      // ── undo / redo (always owned here — edit-specific) ──
      if (mod && lower === "z") {
        e.preventDefault();
        if (e.shiftKey) editor.redo();
        else editor.undo();
        return;
      }
      if (mod && lower === "y") {
        e.preventDefault();
        editor.redo();
        return;
      }

      // Modifier combos other than the above aren't ours.
      if (mod) return;

      // ── delete selection (Delete / Backspace) ──
      if (!deferModeKeys && (key === "Delete" || key === "Backspace")) {
        const sel = useAppStore.getState().selectedCellIds;
        if (sel.size > 0) {
          e.preventDefault();
          editor.remove([...sel]);
          useAppStore.getState().setSelectedCellIds(new Set());
        }
        return;
      }

      // ── escape: clear selection + return to view mode ──
      if (!deferModeKeys && key === "Escape") {
        e.preventDefault();
        useAppStore.getState().setSelectedCellIds(new Set());
        useAppStore.getState().setEditorMode("view");
        return;
      }

      // ── mode switches (single letters) ──
      if (!deferModeKeys && lower in MODE_KEYS) {
        e.preventDefault();
        const nextMode = MODE_KEYS[lower];
        // Leaving view mode drops the selection set.
        if (nextMode !== "view") {
          useAppStore.getState().setSelectedCellIds(new Set());
        }
        useAppStore.getState().setEditorMode(nextMode);
        return;
      }
    };

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [editor, enabled]);
}

export default useEditingKeymap;
