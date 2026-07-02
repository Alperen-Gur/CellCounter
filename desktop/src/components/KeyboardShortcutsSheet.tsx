/**
 * components/KeyboardShortcutsSheet.tsx — STUB.
 *
 * Owned by feature task `feat-directory-nav-keyboard`. It will render the global
 * shortcuts overlay listing every mapping from `kernel/shortcuts/keymap.ts`
 * (the frozen scheme). Stubbed as a controlled sheet so the shell can wire a
 * "?" toggle without pulling in feature logic. Imports nothing from sibling
 * pages.
 */

interface KeyboardShortcutsSheetProps {
  open: boolean;
  onClose: () => void;
}

export function KeyboardShortcutsSheet({
  open,
  onClose,
}: KeyboardShortcutsSheetProps) {
  if (!open) return null;
  return (
    <div className="cc-shortcuts-backdrop" role="dialog" aria-modal="true">
      <div className="cc-shortcuts-sheet">
        <div className="cc-stub__title">Keyboard shortcuts — coming in feature pass</div>
        <p className="cc-stub__msg">
          The full shortcut reference arrives with{" "}
          <span className="cc-stub__owner">feat-directory-nav-keyboard</span>.
        </p>
        <button type="button" className="cc-btn" onClick={onClose}>
          Close
        </button>
      </div>
    </div>
  );
}

export default KeyboardShortcutsSheet;
