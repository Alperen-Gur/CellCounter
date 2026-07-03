/**
 * components/KeyboardShortcutsSheet.tsx — the global shortcuts reference overlay.
 *
 * Owned by feature task `feat-directory-nav-keyboard`. Renders every mapping in
 * `kernel/shortcuts/keymap.ts` (the frozen scheme), grouped by scope, as a
 * scrollable card — a port of `Views/Modals/KeyboardShortcutsSheet.swift`.
 *
 * Controlled by the shell: App.tsx toggles it with "?" and passes `open` /
 * `onClose`. This component imports nothing from sibling pages — only the kernel
 * keymap. Its internal styling is a scoped <style> block using the shared design
 * tokens from styles/theme.css, so it needs no edit to the shell's shell.css.
 */

import { useEffect } from "react";

import {
  allScopes,
  bindingDisplay,
  type KeyBinding,
} from "../kernel/shortcuts/keymap";
import { Icon } from "./Icon";
import { useFocusTrap } from "./useFocusTrap";

interface KeyboardShortcutsSheetProps {
  open: boolean;
  onClose: () => void;
}

/** A single "⌘⇧Z / ⌘Y" chord string split into individual key chips. */
function ChordChips({ display }: { display: string }) {
  // Synonyms are separated by " / "; keep the separator visible between chips.
  const alternatives = display.split(" / ");
  return (
    <span className="cc-ksh__chord">
      {alternatives.map((alt, i) => (
        <span key={i} className="cc-ksh__chord-alt">
          {i > 0 && <span className="cc-ksh__or">/</span>}
          <kbd className="cc-ksh__key">{alt}</kbd>
        </span>
      ))}
    </span>
  );
}

export function KeyboardShortcutsSheet({
  open,
  onClose,
}: KeyboardShortcutsSheetProps) {
  // Trap Tab focus inside the dialog, move focus in on open, and restore it to
  // the invoking control on close (aria-modal alone does not trap DOM tab order).
  const dialogRef = useFocusTrap<HTMLDivElement>(open);

  // Close on Escape while the sheet is open (also stops the key from leaking to
  // page handlers underneath). The shell binds "?"/Escape too; this is belt-and
  // -suspenders so the sheet is self-contained.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        onClose();
      }
    };
    // Capture phase so we win over page-scope Escape handlers.
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [open, onClose]);

  if (!open) return null;

  const scopes = allScopes();

  return (
    <div
      className="cc-shortcuts-backdrop"
      role="presentation"
      onClick={onClose}
    >
      <style>{SHEET_STYLES}</style>
      <div
        ref={dialogRef}
        className="cc-shortcuts-sheet cc-ksh"
        role="dialog"
        aria-modal="true"
        aria-label="Keyboard shortcuts"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="cc-ksh__header">
          <div>
            <div className="cc-ksh__title">Keyboard Shortcuts</div>
            <div className="cc-ksh__subtitle">
              Per-screen shortcuts — active only in the corresponding view.
            </div>
          </div>
          <button
            type="button"
            className="cc-ksh__close"
            aria-label="Close"
            onClick={onClose}
          >
            <Icon name="close" size={16} />
          </button>
        </header>

        <div className="cc-ksh__body">
          {scopes.map((scope) => {
            const rows = scope.bindings.filter(
              (b: KeyBinding) => bindingDisplay(b) !== "",
            );
            if (rows.length === 0) return null;
            return (
              <section key={scope.id} className="cc-ksh__group">
                <h3 className="cc-ksh__group-title">{scope.title}</h3>
                <div className="cc-ksh__rows">
                  {rows.map((b) => (
                    <div key={b.action} className="cc-ksh__row">
                      <ChordChips display={bindingDisplay(b)} />
                      <span className="cc-ksh__desc">{b.description}</span>
                    </div>
                  ))}
                </div>
              </section>
            );
          })}
        </div>

        <footer className="cc-ksh__footer">
          <button
            type="button"
            className="cc-btn cc-btn--primary cc-ksh__done"
            onClick={onClose}
          >
            Close
          </button>
        </footer>
      </div>
    </div>
  );
}

export default KeyboardShortcutsSheet;

// ---------------------------------------------------------------------------
// Scoped styles (design tokens from styles/theme.css; no shell.css edit needed)
// ---------------------------------------------------------------------------

const SHEET_STYLES = `
.cc-shortcuts-backdrop {
  position: fixed;
  inset: 0;
  z-index: 60;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: var(--cc-space-5);
  background: rgba(24, 24, 27, 0.28);
}
.cc-shortcuts-sheet {
  display: flex;
  flex-direction: column;
  background: var(--cc-bg-elevated);
  border: 1px solid var(--cc-border);
  border-radius: var(--cc-radius-lg);
  box-shadow: var(--cc-shadow-3);
}
.cc-ksh {
  width: min(600px, calc(100vw - 32px));
  max-width: none;
  max-height: min(680px, calc(100vh - 48px));
  padding: 0;
  text-align: left;
  gap: 0;
  overflow: hidden;
}
.cc-ksh__header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--cc-space-4);
  padding: var(--cc-space-5) var(--cc-space-5) var(--cc-space-4);
}
.cc-ksh__title {
  font-family: var(--cc-font-display);
  font-size: var(--cc-text-lg);
  font-weight: 650;
  color: var(--cc-text);
  letter-spacing: -0.01em;
}
.cc-ksh__subtitle {
  margin-top: 2px;
  font-size: var(--cc-text-sm);
  color: var(--cc-text-tertiary);
}
.cc-ksh__close {
  flex: 0 0 auto;
  width: 30px;
  height: 30px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: none;
  border-radius: var(--cc-radius-md);
  background: transparent;
  color: var(--cc-text-secondary);
  cursor: pointer;
  transition: background 0.12s ease, color 0.12s ease;
}
.cc-ksh__close:hover {
  background: var(--cc-bg-hover);
  color: var(--cc-text);
}
.cc-ksh__close:focus-visible {
  outline: none;
  box-shadow: 0 0 0 3px var(--cc-focus-ring);
}
.cc-ksh__body {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  padding: 0 var(--cc-space-5) var(--cc-space-4);
  display: flex;
  flex-direction: column;
  gap: var(--cc-space-5);
}
.cc-ksh__group-title {
  margin: 0 0 var(--cc-space-2);
  font-size: var(--cc-text-xs);
  font-weight: 650;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--cc-text-tertiary);
}
.cc-ksh__rows {
  border: 1px solid var(--cc-border);
  border-radius: var(--cc-radius-md);
  overflow: hidden;
  background: var(--cc-bg-elevated);
}
.cc-ksh__row {
  display: flex;
  align-items: center;
  gap: var(--cc-space-3);
  padding: var(--cc-space-2) var(--cc-space-3);
}
.cc-ksh__row + .cc-ksh__row {
  border-top: 1px solid var(--cc-border);
}
.cc-ksh__chord {
  flex: 0 0 132px;
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: var(--cc-space-1);
  flex-wrap: wrap;
}
.cc-ksh__chord-alt {
  display: inline-flex;
  align-items: center;
  gap: var(--cc-space-1);
}
.cc-ksh__or {
  color: var(--cc-text-tertiary);
  font-size: var(--cc-text-xs);
}
.cc-ksh__key {
  display: inline-block;
  min-width: 22px;
  padding: 2px 7px;
  border-radius: 5px;
  background: var(--cc-bg-sidebar);
  border: 1px solid var(--cc-border-strong);
  border-bottom-width: 2px;
  color: var(--cc-text);
  font-family: var(--cc-font-mono);
  font-size: 12px;
  font-weight: 500;
  line-height: 1.4;
  text-align: center;
  white-space: nowrap;
}
.cc-ksh__desc {
  flex: 1 1 auto;
  font-size: var(--cc-text-sm);
  color: var(--cc-text-secondary);
}
.cc-ksh__footer {
  flex: 0 0 auto;
  display: flex;
  justify-content: flex-end;
  padding: var(--cc-space-3) var(--cc-space-5);
  border-top: 1px solid var(--cc-border);
  background: var(--cc-bg-sidebar);
}
`;
