/**
 * components/useKeymap.ts — per-page keyboard binder.
 *
 * Binds a page's active keyboard handlers to the frozen scheme in
 * `kernel/shortcuts/keymap.ts`. A page names ONE scope and passes a map of
 * `action-id → handler`; while the component is mounted (and `enabled`) this
 * hook listens for `keydown` on `window`, resolves each event to an action in
 * that scope — restricted to the actions the page actually registered — and
 * invokes the matching handler.
 *
 * Design points:
 *   - Only actions present in `handlers` can fire, so mounting the `navigation`
 *     scope never reacts to an `editor` chord. Two scopes on one page only
 *     collide if they register handlers whose chords are identical (a page
 *     concern); within a single scope the first matching binding wins.
 *   - Events originating from a text field (input / textarea / contentEditable /
 *     <select>) are ignored, so typing never triggers a shortcut. Pass
 *     `allowInInputs: true` to opt out (rarely needed).
 *   - `preventDefault()` is called on a handled event (configurable) so browser
 *     defaults (⌘0 zoom reset, Space scroll, ⌘Z page undo…) don't leak through.
 *   - Handlers are read through a ref, so passing a fresh inline map each render
 *     does not detach/reattach the listener.
 *
 * No page internals are imported — this hook depends only on the kernel keymap.
 * Runs identically under the desktop and the future browser build.
 */

import { useEffect, useRef } from "react";

import {
  matchAction,
  type KeymapScopeId,
} from "../kernel/shortcuts/keymap";

/** Map of action-id → handler for the current scope. */
export type KeymapHandlers = Record<string, (event: KeyboardEvent) => void>;

export interface UseKeymapOptions {
  /** When false the listener is detached (e.g. a modal is open). Default true. */
  enabled?: boolean;
  /** Call `preventDefault()` on a handled event. Default true. */
  preventDefault?: boolean;
  /** React even when a text field is focused. Default false. */
  allowInInputs?: boolean;
  /** Listen in the capture phase (wins over bubbling listeners). Default false. */
  capture?: boolean;
}

/** Is the event's target a text-entry surface we must not hijack? */
function isEditableTarget(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null;
  if (!el || !el.tagName) return false;
  const tag = el.tagName;
  return (
    tag === "INPUT" ||
    tag === "TEXTAREA" ||
    tag === "SELECT" ||
    el.isContentEditable === true
  );
}

/**
 * Bind `handlers` for `scope`. Safe to call with no scope/handlers (a no-op),
 * so a page can conditionally wire shortcuts without violating the rules of
 * hooks.
 *
 * @example
 *   useKeymap("navigation", {
 *     nextImage: () => store.nextImage(),
 *     prevImage: () => store.prevImage(),
 *   });
 */
export function useKeymap(
  scope?: KeymapScopeId,
  handlers?: KeymapHandlers,
  options?: UseKeymapOptions,
): void {
  const {
    enabled = true,
    preventDefault = true,
    allowInInputs = false,
    capture = false,
  } = options ?? {};

  // Keep the latest handlers in a ref so an inline map doesn't churn the effect.
  const handlersRef = useRef<KeymapHandlers | undefined>(handlers);
  handlersRef.current = handlers;

  useEffect(() => {
    if (!enabled || !scope) return;

    const onKeyDown = (e: KeyboardEvent) => {
      const map = handlersRef.current;
      if (!map) return;
      if (!allowInInputs && isEditableTarget(e.target)) return;

      const action = matchAction(scope, e, Object.keys(map));
      if (!action) return;

      const handler = map[action];
      if (!handler) return;

      if (preventDefault) e.preventDefault();
      handler(e);
    };

    window.addEventListener("keydown", onKeyDown, capture);
    return () => window.removeEventListener("keydown", onKeyDown, capture);
    // handlers deliberately excluded — read via ref, so the listener is stable.
  }, [scope, enabled, preventDefault, allowInInputs, capture]);
}

export default useKeymap;
