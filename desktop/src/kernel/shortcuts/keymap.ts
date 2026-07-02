/**
 * kernel/shortcuts/keymap.ts — the frozen keyboard scheme (ARCHITECTURE.md §3,
 * feature: directory-nav-keyboard).
 *
 * FROZEN STUB. This is the single import point pages use to register keyboard
 * handlers against stable action ids (§6.6). The scope + action-id vocabulary
 * below is the contract; the actual key *bindings* are intentionally left empty
 * (or minimal) and are filled in by the later `directory-nav-keyboard` feature —
 * porting the full scheme from `Views/Modals/KeyboardShortcutsSheet.swift`.
 *
 * Why freeze the shape now: pages (Results, Review, …) are written against
 * `keymap.<scope>` and `KeymapAction` ids *before* the feature lands, so adding
 * bindings later must not rename a scope or an action id. Readers bind to the
 * action ids; the binding strings can change freely.
 *
 * No React, no platform deps — a plain data module so both the desktop and the
 * future WebGPU browser build consume the identical scheme.
 */

/**
 * A single key binding: the human-facing chord(s) that trigger an action, plus
 * a description for the shortcuts sheet. `keys` is a list so an action can have
 * synonyms (e.g. Delete + Backspace). Empty `keys` ⇒ "not yet bound" — the
 * later feature fills these in. Modifier syntax (when populated) is the Swift
 * `KeyboardShortcutsSheet` convention: "mod" = ⌘/Ctrl, "shift", "alt".
 */
export interface KeyBinding {
  /** Stable, page-facing action id. Never renamed once shipped. */
  action: string;
  /** Chord synonyms, e.g. ["ArrowRight"], ["mod+z"], ["Delete", "Backspace"]. */
  keys: string[];
  /** One-line label for the shortcuts sheet. */
  description: string;
}

/** A named group of bindings scoped to a screen / interaction context. */
export interface KeymapScope {
  /** Stable scope id (matches the property key on `keymap`). */
  id: string;
  /** Human-readable section title for the shortcuts sheet. */
  title: string;
  bindings: KeyBinding[];
}

/**
 * The frozen scheme. Scopes and action ids are the contract; `keys` arrays are
 * deliberately empty for now (the `directory-nav-keyboard` feature populates
 * them). Pages should look up bindings via `actionKeys(scope, action)` so they
 * keep working the moment the bindings are filled in — no page edit required.
 *
 * Scope / action ids are drawn from `KeyboardShortcutsSheet.swift` and the
 * per-page handlers referenced in ARCHITECTURE §4:
 *   - global:     app-wide (fit-to-view, help)
 *   - navigation: Results directory next/prev (ResultsView ←/→)
 *   - editor:     MaskEditEngine modes + undo/redo + delete (EditableOverlay)
 *   - overlay:    Space/X/Z overlay + opacity toggles (SessionSlice)
 *   - review:     Review-queue triage (Reject/Keep/Edit-Ø/Skip)
 */
export const keymap = {
  global: {
    id: "global",
    title: "General",
    bindings: [
      { action: "fitToView", keys: [], description: "Fit image to view" },
      { action: "showShortcuts", keys: [], description: "Show keyboard shortcuts" },
    ],
  },
  navigation: {
    id: "navigation",
    title: "Navigation",
    bindings: [
      { action: "nextImage", keys: [], description: "Next image in directory" },
      { action: "prevImage", keys: [], description: "Previous image in directory" },
    ],
  },
  editor: {
    id: "editor",
    title: "Editing",
    bindings: [
      { action: "modeView", keys: [], description: "View mode" },
      { action: "modeAdd", keys: [], description: "Add mode" },
      { action: "modeRemove", keys: [], description: "Remove mode" },
      { action: "modeMerge", keys: [], description: "Merge mode" },
      { action: "modeSplit", keys: [], description: "Split mode" },
      { action: "modeManualCount", keys: [], description: "Manual-count mode" },
      { action: "modeAnnotate", keys: [], description: "Annotate (ground truth) mode" },
      { action: "delete", keys: [], description: "Delete selection" },
      { action: "undo", keys: [], description: "Undo" },
      { action: "redo", keys: [], description: "Redo" },
      { action: "escape", keys: [], description: "Clear selection / cancel" },
    ],
  },
  overlay: {
    id: "overlay",
    title: "Overlay",
    bindings: [
      { action: "toggleMaskFills", keys: [], description: "Toggle mask fills" },
      { action: "toggleOutlines", keys: [], description: "Toggle outlines" },
      { action: "cycleOverlayMode", keys: [], description: "Cycle outline / bbox" },
    ],
  },
  review: {
    id: "review",
    title: "Review Queue",
    bindings: [
      { action: "reject", keys: [], description: "Reject cell" },
      { action: "keep", keys: [], description: "Keep cell" },
      { action: "editDiameter", keys: [], description: "Edit diameter" },
      { action: "skip", keys: [], description: "Skip" },
    ],
  },
} as const satisfies Record<string, KeymapScope>;

/** All scope ids the keymap defines (stable). */
export type KeymapScopeId = keyof typeof keymap;

/**
 * Look up the chord synonyms bound to `(scope, action)`. Returns `[]` when the
 * action isn't bound yet (the frozen-stub state) — callers should treat an empty
 * list as "no shortcut" and not crash. Once the later feature fills `keys`, the
 * same call starts returning real chords with no page change.
 */
export function actionKeys(scope: KeymapScopeId, action: string): string[] {
  const found = keymap[scope].bindings.find((b) => b.action === action);
  return found ? [...found.keys] : [];
}

/** Flat list of every scope (for rendering the shortcuts sheet). */
export function allScopes(): KeymapScope[] {
  return Object.values(keymap);
}
