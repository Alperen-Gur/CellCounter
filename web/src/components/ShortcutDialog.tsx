import { X } from "lucide-react";

const shortcuts = [["I", "Import images"], ["⌘ / Ctrl + Enter", "Run analysis"], ["Esc", "Cancel analysis"], ["1 — 5", "Choose correction tool"], ["⌘ / Ctrl + E", "Export measurements"], ["T", "Toggle theme"]];

export function ShortcutDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  if (!open) return null;
  return <div className="dialog-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}><section className="shortcut-dialog" role="dialog" aria-modal="true" aria-labelledby="shortcut-title"><header><div><span className="eyebrow">Keyboard first</span><h2 id="shortcut-title">Shortcuts</h2></div><button className="icon-button" onClick={onClose} aria-label="Close"><X size={18} /></button></header><div>{shortcuts.map(([key, label]) => <p key={key}><span>{label}</span><kbd>{key}</kbd></p>)}</div></section></div>;
}
