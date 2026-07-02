/**
 * kernel/shortcuts/keymap.ts — the frozen keyboard scheme (ARCHITECTURE.md §3,
 * feature: directory-nav-keyboard).
 *
 * This is the single import point pages use to register keyboard handlers
 * against stable action ids (§6.6). The scope + action-id vocabulary is the
 * frozen contract; the concrete key *bindings* (the `keys` arrays) are filled
 * in here, ported from `Views/Modals/KeyboardShortcutsSheet.swift`.
 *
 * Readers bind to the action ids via `actionKeys(scope, action)` /
 * `useKeymap(scope, handlers)` — the chord strings can change freely without a
 * page edit. Scope ids and action ids are stable forever.
 *
 * No React, no platform deps — a plain data + pure-function module so both the
 * desktop and the future WebGPU browser build consume the identical scheme and
 * the identical matching logic.
 *
 * ── Chord grammar ──────────────────────────────────────────────────────────
 * A chord is a `+`-joined string of zero or more modifiers followed by exactly
 * one key token, e.g. `"mod+shift+z"`, `"ArrowRight"`, `"x"`, `"Space"`.
 *   modifiers: "mod" (⌘ on macOS / Ctrl elsewhere), "shift", "alt".
 *   key token: a single character (case-insensitive, e.g. "a", "/", "?"),
 *              or a named key: "ArrowLeft" | "ArrowRight" | "ArrowUp" |
 *              "ArrowDown" | "Space" | "Enter" | "Escape" | "Delete" |
 *              "Backspace" | "Tab".
 * `keys` is a list so an action can have synonyms (e.g. ["Delete","Backspace"]
 * or ["mod+shift+z","mod+y"]). An empty `keys` list means "not bound".
 */

// ---------------------------------------------------------------------------
// Types (the `KeyBinding` / `KeymapScope` shape is frozen; `display` is an
// additive, optional field used only by the shortcuts sheet)
// ---------------------------------------------------------------------------

/**
 * A single key binding: the chord(s) that trigger an action, a human label for
 * the shortcuts sheet, and (optionally) a pretty display string.
 */
export interface KeyBinding {
  /** Stable, page-facing action id. Never renamed once shipped. */
  action: string;
  /** Chord synonyms, e.g. ["ArrowRight"], ["mod+z"], ["Delete", "Backspace"]. */
  keys: string[];
  /** One-line label for the shortcuts sheet. */
  description: string;
  /**
   * Optional pretty chord for the sheet (e.g. "⌘⇧Z / ⌘Y"). Additive: when
   * absent the sheet derives one from `keys` via {@link displayChord}.
   */
  display?: string;
}

/** A named group of bindings scoped to a screen / interaction context. */
export interface KeymapScope {
  /** Stable scope id (matches the property key on `keymap`). */
  id: string;
  /** Human-readable section title for the shortcuts sheet. */
  title: string;
  bindings: KeyBinding[];
}

// ---------------------------------------------------------------------------
// The frozen scheme
// ---------------------------------------------------------------------------

/**
 * The frozen scheme. Scopes and action ids are the contract; the `keys` arrays
 * are the port of `KeyboardShortcutsSheet.swift`. Pages look up bindings via
 * `actionKeys(scope, action)` or register handlers with `useKeymap`.
 *
 * Scopes (drawn from `KeyboardShortcutsSheet.swift` + the per-page handlers in
 * ARCHITECTURE §4):
 *   - global:     app-wide (fit-to-view, zoom, help)
 *   - navigation: Results directory next/prev (ResultsView ←/→)
 *   - editor:     MaskEditEngine modes + undo/redo + delete (EditableOverlay)
 *   - overlay:    Space/X/Z overlay + mode toggles (SessionSlice)
 *   - review:     Review-queue triage (Reject/Keep/Edit-Ø/Skip)
 */
export const keymap = {
  global: {
    id: "global",
    title: "General",
    bindings: [
      { action: "fitToView", keys: ["mod+0"], description: "Fit image to view", display: "⌘0" },
      { action: "zoomIn", keys: ["mod+=", "mod++"], description: "Zoom in", display: "⌘+" },
      { action: "zoomOut", keys: ["mod+-"], description: "Zoom out", display: "⌘-" },
      { action: "showShortcuts", keys: ["mod+/", "?"], description: "Show keyboard shortcuts", display: "⌘/" },
    ],
  },
  navigation: {
    id: "navigation",
    title: "Navigation",
    bindings: [
      { action: "nextImage", keys: ["ArrowRight"], description: "Next image in directory", display: "→" },
      { action: "prevImage", keys: ["ArrowLeft"], description: "Previous image in directory", display: "←" },
    ],
  },
  editor: {
    id: "editor",
    title: "Editing",
    bindings: [
      { action: "modeView", keys: ["v"], description: "View mode", display: "V" },
      { action: "modeAdd", keys: ["a"], description: "Add mode", display: "A" },
      { action: "modeRemove", keys: ["r"], description: "Remove mode", display: "R" },
      { action: "modeMerge", keys: ["m"], description: "Merge mode", display: "M" },
      // Split has no dedicated key in the Swift scheme (it was a button-driven
      // watershed action). Left unbound; the mode is still reachable via UI.
      { action: "modeSplit", keys: [], description: "Split mode", display: "" },
      { action: "modeManualCount", keys: ["c"], description: "Manual-count mode", display: "C" },
      { action: "modeAnnotate", keys: ["g"], description: "Annotate (ground truth) mode", display: "G" },
      { action: "delete", keys: ["Delete", "Backspace"], description: "Delete selection", display: "Delete" },
      { action: "undo", keys: ["mod+z"], description: "Undo", display: "⌘Z" },
      { action: "redo", keys: ["mod+shift+z", "mod+y"], description: "Redo", display: "⌘⇧Z / ⌘Y" },
      { action: "escape", keys: ["Escape"], description: "Clear selection / cancel", display: "Esc" },
    ],
  },
  overlay: {
    id: "overlay",
    title: "Overlay",
    bindings: [
      // Master overlay toggle (fills + outlines together) — additive to the
      // frozen trio so the Swift `Space` binding is honoured.
      { action: "toggleOverlay", keys: ["Space"], description: "Toggle overlay (fills + outlines)", display: "Space" },
      { action: "toggleMaskFills", keys: ["x"], description: "Toggle mask fills", display: "X" },
      { action: "toggleOutlines", keys: ["z"], description: "Toggle outlines", display: "Z" },
      { action: "cycleOverlayMode", keys: ["mod+1", "mod+2"], description: "Cycle outline / bbox", display: "⌘1 / ⌘2" },
    ],
  },
  review: {
    id: "review",
    title: "Review Queue",
    bindings: [
      { action: "reject", keys: ["r"], description: "Reject cell", display: "R" },
      { action: "keep", keys: ["k"], description: "Keep cell", display: "K" },
      { action: "editDiameter", keys: ["e"], description: "Edit diameter", display: "E" },
      { action: "skip", keys: ["ArrowRight"], description: "Skip", display: "→" },
      { action: "exit", keys: ["Escape"], description: "Exit review queue", display: "Esc" },
    ],
  },
} as const satisfies Record<string, KeymapScope>;

/** All scope ids the keymap defines (stable). */
export type KeymapScopeId = keyof typeof keymap;

// ---------------------------------------------------------------------------
// Lookup helpers
// ---------------------------------------------------------------------------

/**
 * Look up the chord synonyms bound to `(scope, action)`. Returns `[]` when the
 * action isn't bound (e.g. `modeSplit`) — callers treat an empty list as "no
 * shortcut".
 */
export function actionKeys(scope: KeymapScopeId, action: string): string[] {
  const found = keymap[scope].bindings.find((b) => b.action === action);
  return found ? [...found.keys] : [];
}

/** Flat list of every scope (for rendering the shortcuts sheet). */
export function allScopes(): KeymapScope[] {
  return Object.values(keymap);
}

// ---------------------------------------------------------------------------
// Chord parsing + event matching (pure; shared by useKeymap and any consumer)
// ---------------------------------------------------------------------------

/** A parsed chord: the required modifier state + the (normalised) key token. */
export interface ParsedChord {
  mod: boolean; // ⌘ (macOS) / Ctrl (elsewhere)
  shift: boolean;
  alt: boolean;
  /** Normalised key token: single lower-case char, or a NamedKey. */
  key: string;
}

/** The set of recognised multi-character key tokens (case-sensitive spelling). */
const NAMED_KEYS = new Set<string>([
  "ArrowLeft",
  "ArrowRight",
  "ArrowUp",
  "ArrowDown",
  "Space",
  "Enter",
  "Escape",
  "Delete",
  "Backspace",
  "Tab",
]);

/**
 * Parse a chord string like `"mod+shift+z"` into its structured form. Modifiers
 * are order-insensitive; the final non-modifier segment is the key token. Named
 * keys keep their canonical spelling; single characters are lower-cased.
 */
export function parseChord(chord: string): ParsedChord {
  const parts = chord.split("+");
  const result: ParsedChord = { mod: false, shift: false, alt: false, key: "" };
  for (const raw of parts) {
    const p = raw.trim();
    if (p === "") {
      // Empty segment happens for the literal "+" key ("mod++" → ["mod","",""]).
      // Treat a trailing empty as the "+" character key.
      result.key = "+";
      continue;
    }
    const low = p.toLowerCase();
    if (low === "mod" || low === "cmd" || low === "ctrl" || low === "meta") {
      result.mod = true;
    } else if (low === "shift") {
      result.shift = true;
    } else if (low === "alt" || low === "option" || low === "opt") {
      result.alt = true;
    } else if (NAMED_KEYS.has(p)) {
      result.key = p;
    } else {
      // A plain character key. Store lower-cased so matching is case-insensitive.
      result.key = p.length === 1 ? low : p;
    }
  }
  return result;
}

/**
 * Normalise a `KeyboardEvent`'s key into a token comparable with a chord's key.
 * `event.key` gives us named keys ("ArrowRight", "Escape", "Delete", "Enter",
 * "Tab") directly; " " (space) maps to "Space"; single printable characters are
 * lower-cased. Modifier keys themselves ("Shift"/"Meta"/…) return "".
 */
function eventKeyToken(e: KeyboardEvent): string {
  const k = e.key;
  if (k === " " || k === "Spacebar") return "Space";
  if (NAMED_KEYS.has(k)) return k;
  if (k === "Shift" || k === "Meta" || k === "Control" || k === "Alt") return "";
  if (k.length === 1) return k.toLowerCase();
  return k; // any other named key (e.g. "F1") — spelled as-is
}

/** True for single-character keys whose glyph already encodes Shift (e.g. "?", "+"). */
function isShiftedPunctuation(key: string): boolean {
  return key.length === 1 && !/[a-z0-9]/.test(key);
}

/**
 * Does `event` satisfy the parsed `chord`? We accept EITHER ⌘ or Ctrl for `mod`
 * (cross-platform). `alt` must match exactly. `shift` must match exactly for
 * letters/digits/named keys (so `z` does not fire on `⇧Z`), but is IGNORED for
 * shifted-punctuation keys like `?` or `+`, whose glyph already implies Shift —
 * this mirrors the shell treating `?` as a bare shortcut. The key token must be
 * equal (case-insensitive for single chars).
 */
export function chordMatchesEvent(chord: ParsedChord, e: KeyboardEvent): boolean {
  if (chord.key === "") return false;
  const eventMod = e.metaKey || e.ctrlKey;
  if (chord.mod !== eventMod) return false;
  if (chord.alt !== e.altKey) return false;
  if (!isShiftedPunctuation(chord.key) && chord.shift !== e.shiftKey) return false;
  return eventKeyToken(e) === chord.key;
}

/**
 * Resolve a `KeyboardEvent` to the FIRST action in `scope` whose chord list
 * contains a matching chord, restricted to `allowed` action ids when provided
 * (so a page only reacts to actions it registered a handler for). Returns the
 * matched action id, or `undefined` when nothing in scope matches.
 */
export function matchAction(
  scope: KeymapScopeId,
  e: KeyboardEvent,
  allowed?: Iterable<string>,
): string | undefined {
  const allowSet = allowed ? new Set(allowed) : undefined;
  for (const binding of keymap[scope].bindings) {
    if (allowSet && !allowSet.has(binding.action)) continue;
    for (const chord of binding.keys) {
      if (chordMatchesEvent(parseChord(chord), e)) return binding.action;
    }
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// Display helpers (shortcuts sheet)
// ---------------------------------------------------------------------------

const MOD_GLYPH = "⌘";
const SHIFT_GLYPH = "⇧";
const ALT_GLYPH = "⌥";

/** Pretty-print a single chord string into its glyph form (e.g. "mod+shift+z" → "⌘⇧Z"). */
export function displayChord(chord: string): string {
  const p = parseChord(chord);
  let out = "";
  if (p.mod) out += MOD_GLYPH;
  if (p.alt) out += ALT_GLYPH;
  if (p.shift) out += SHIFT_GLYPH;
  out += keyTokenLabel(p.key);
  return out;
}

/** Human label for a key token used in the shortcuts sheet. */
function keyTokenLabel(key: string): string {
  switch (key) {
    case "ArrowLeft":
      return "←";
    case "ArrowRight":
      return "→";
    case "ArrowUp":
      return "↑";
    case "ArrowDown":
      return "↓";
    case "Space":
      return "Space";
    case "Enter":
      return "Return";
    case "Escape":
      return "Esc";
    case "Delete":
      return "Delete";
    case "Backspace":
      return "⌫";
    case "Tab":
      return "Tab";
    case "":
      return "";
    default:
      return key.length === 1 ? key.toUpperCase() : key;
  }
}

/**
 * The chord string(s) for a binding rendered for the shortcuts sheet. Uses the
 * binding's explicit `display` when present; otherwise joins each chord's glyph
 * form with " / ". Returns "" for unbound actions.
 */
export function bindingDisplay(binding: KeyBinding): string {
  if (binding.display !== undefined) return binding.display;
  if (binding.keys.length === 0) return "";
  return binding.keys.map(displayChord).join(" / ");
}
