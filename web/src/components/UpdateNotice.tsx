import { RefreshCw } from "lucide-react";
export function UpdateNotice({ busy, onReload }: { busy: boolean; onReload(): void }) {
  return <aside className="app-update" role="status"><RefreshCw size={18} /><div><strong>Update available</strong><p>{busy ? "Reload after processing finishes or pauses." : "Reload to use the latest version."}</p></div><button className="secondary-button" disabled={busy} onClick={onReload}>Reload app</button></aside>;
}
