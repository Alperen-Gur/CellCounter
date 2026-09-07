import { useEffect, useRef } from "react";
import type { RouteId } from "../app/types";

export const SHORTCUTS = [
  ["⌘ / Ctrl + O", "Import images"],
  ["⌘ / Ctrl + Shift + O", "Import a folder"],
  ["I", "Import images in Analyze or Library"],
  ["⌘ / Ctrl + Alt + 1–4", "Library, Analyze, Processing, Review"],
  ["⌘ / Ctrl + Enter", "Preview or process the active Analyze image"],
  ["Esc", "Close dialog or cancel active processing"],
  ["1 — 6", "Choose Analyze correction tool"],
  ["⌘ / Ctrl + Z", "Undo Analyze correction"],
  ["⌘ / Ctrl + Shift + Z", "Redo Analyze correction"],
  ["⌘ / Ctrl + E", "Export Analyze measurements"],
  ["K / X / R", "Review: accept / reject / resize focused object"],
  ["T", "Toggle theme"],
  ["?", "Show keyboard shortcuts"],
] as const;
export interface KeyActions {
  disabled?: boolean;
  route?: RouteId;
  modalOpen?: boolean;
  hasImage?: boolean;
  busy?: boolean;
  canUndo?: boolean;
  canRedo?: boolean;
  closeDialog?: () => void;
  undo?: () => void;
  redo?: () => void;
  importImages: () => void;
  importFolder?: () => void;
  navigate?: (route: RouteId) => void;
  run: () => void;
  cancel: () => void;
  exportResults: () => void;
  setTool: (index: number) => void;
  toggleTheme: () => void;
  showHelp: () => void;
}

export function handleKeyboard(event: KeyboardEvent, actions: KeyActions): void {
  const target = event.target as HTMLElement | null;
  if (actions.disabled || event.isComposing || event.defaultPrevented || event.getModifierState("AltGraph")) return;
  if (actions.modalOpen || target?.closest("[role='dialog'], dialog[open]")) {
    if (event.key === "Escape") { event.preventDefault(); actions.closeDialog?.(); }
    return;
  }
  if (target?.closest("input, textarea, select, [contenteditable]:not([contenteditable='false'])")) return;
  const modifier = event.metaKey || event.ctrlKey;
  const workspace = (actions.route ?? "workspace") === "workspace";
  const hasImage = actions.hasImage ?? true;
  let action: (() => void) | undefined;
  const key = event.key.toLowerCase();
  if (event.key === "Escape" && actions.busy) action = actions.cancel;
  else if (modifier && event.altKey && !event.shiftKey && /^[1-4]$/.test(key) && actions.navigate) action = () => actions.navigate?.((["library", "workspace", "processing", "review"] as const)[Number(key) - 1]);
  else if (modifier && !event.altKey) {
    if (key === "o" && !actions.busy) action = event.shiftKey ? actions.importFolder : actions.importImages;
    else if (workspace && hasImage && !actions.busy) {
      if (event.key === "Enter") action = actions.run;
      else if (key === "e") action = actions.exportResults;
      else if (key === "z" && event.shiftKey && actions.canRedo) action = actions.redo;
      else if (key === "z" && !event.shiftKey && actions.canUndo) action = actions.undo;
    }
  } else if (!modifier && !event.altKey) {
    if (key === "i" && !actions.busy && (workspace || actions.route === "library")) action = actions.importImages;
    else if (/^[1-6]$/.test(key) && workspace && hasImage && !actions.busy) action = () => actions.setTool(Number(key) - 1);
    else if (key === "t") action = actions.toggleTheme;
    else if (event.key === "?") action = actions.showHelp;
  }
  if (action) { event.preventDefault(); action(); }
}

export function useKeyboard(actions: KeyActions): void {
  const latest = useRef(actions);
  latest.current = actions;
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => handleKeyboard(event, latest.current);
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);
}
