import { useDialogFocus } from "../hooks/useDialogFocus";
import { X } from "lucide-react";

import { SHORTCUTS as shortcuts } from "../hooks/useKeyboard";

export function ShortcutDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const dialog = useDialogFocus(open);
  if (!open) return null;
  return <div className="dialog-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}><section ref={dialog} tabIndex={-1} className="shortcut-dialog" role="dialog" aria-modal="true" aria-labelledby="shortcut-title"><header><div><span className="eyebrow">Keyboard first</span><h2 id="shortcut-title">Shortcuts</h2></div><button className="icon-button" onClick={onClose} aria-label="Close"><X size={18} /></button></header><div>{shortcuts.map(([key, label]) => <p key={key}><span>{label}</span><kbd>{key}</kbd></p>)}</div></section></div>;
}
