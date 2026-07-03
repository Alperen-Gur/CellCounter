/**
 * components/useFocusTrap.ts — a small, dependency-free focus-trap hook for
 * `aria-modal` dialogs (KeyboardShortcutsSheet and any other overlay).
 *
 * `aria-modal="true"` alone does NOT keep DOM Tab order inside the dialog, so
 * keyboard/screen-reader users can Tab out into the page behind it. This hook,
 * while `active`:
 *   - moves focus into the dialog on open (the container itself, tabindex=-1),
 *   - traps Tab / Shift+Tab within the dialog's focusable elements (wrap-around),
 *   - restores focus to the element that had it before the dialog opened, on
 *     close/unmount.
 *
 * Pure DOM — no platform deps, runs identically in the desktop and future
 * browser builds. Attach the returned ref to the dialog container element.
 */

import { useEffect, useRef } from "react";

const FOCUSABLE = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  '[tabindex]:not([tabindex="-1"])',
].join(",");

export function useFocusTrap<T extends HTMLElement = HTMLElement>(
  active: boolean,
) {
  const ref = useRef<T | null>(null);

  useEffect(() => {
    if (!active) return;
    const container = ref.current;
    if (!container) return;

    // Remember what was focused so we can restore it on close.
    const previouslyFocused = document.activeElement as HTMLElement | null;

    const focusables = (): HTMLElement[] =>
      Array.from(container.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
        (el) => el.offsetParent !== null || el === document.activeElement,
      );

    // Move initial focus into the dialog: first focusable, else the container.
    const first = focusables()[0];
    if (first) {
      first.focus();
    } else {
      container.tabIndex = -1;
      container.focus();
    }

    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key !== "Tab") return;
      const items = focusables();
      if (items.length === 0) {
        // Nothing tabbable — keep focus pinned to the container.
        e.preventDefault();
        container.focus();
        return;
      }
      const firstEl = items[0];
      const lastEl = items[items.length - 1];
      const activeEl = document.activeElement;
      if (e.shiftKey) {
        if (activeEl === firstEl || !container.contains(activeEl)) {
          e.preventDefault();
          lastEl.focus();
        }
      } else {
        if (activeEl === lastEl || !container.contains(activeEl)) {
          e.preventDefault();
          firstEl.focus();
        }
      }
    };

    container.addEventListener("keydown", onKeyDown);
    return () => {
      container.removeEventListener("keydown", onKeyDown);
      // Restore focus to the invoking control, if it's still in the document.
      if (previouslyFocused && document.contains(previouslyFocused)) {
        previouslyFocused.focus();
      }
    };
  }, [active]);

  return ref;
}
