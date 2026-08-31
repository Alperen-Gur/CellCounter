import { AlertCircle, CheckCircle2, Info, TriangleAlert, X } from "lucide-react";
import type { Notice } from "../app/types";

const icons = { info: Info, success: CheckCircle2, warning: TriangleAlert, error: AlertCircle };

export function NoticeBar({ notice, onClose }: { notice: Notice; onClose: () => void }) {
  const Icon = icons[notice.tone];
  return (
    <aside className={`notice notice-${notice.tone}`} role={notice.tone === "error" ? "alert" : "status"}>
      <Icon size={18} />
      <span><strong>{notice.title}</strong>{notice.detail}</span>
      <button onClick={onClose} aria-label="Dismiss"><X size={16} /></button>
    </aside>
  );
}
