/**
 * components/useKeymap.ts — STUB.
 *
 * Owned by feature task `feat-directory-nav-keyboard`. The real hook binds a
 * page's active keyboard handlers to the frozen scheme in
 * `kernel/shortcuts/keymap.ts` (per-scope, no double-binding). Stubbed as a
 * no-op so pages can call `useKeymap(...)` today without the feature landing.
 * Imports nothing from sibling pages.
 *
 * The shape below is intentionally permissive (a scope name + a handler map);
 * the owning feature freezes the final signature against keymap.ts action ids.
 */

/** Map of action-id → handler for the current scope. */
export type KeymapHandlers = Record<string, (event: KeyboardEvent) => void>;

/**
 * No-op keymap binder. Accepts an optional scope + handler map so call sites
 * match the eventual signature; does nothing until `feat-directory-nav-keyboard`
 * replaces it.
 */
export function useKeymap(_scope?: string, _handlers?: KeymapHandlers): void {
  // Intentionally empty in the shell stub. The feature task wires listeners
  // against kernel/shortcuts/keymap.ts here.
  void _scope;
  void _handlers;
}

export default useKeymap;
