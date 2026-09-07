import { Beaker, Boxes, ClipboardCheck, FlaskConical, Images, ListOrdered, Microscope, MoreHorizontal, PanelLeftClose, PanelLeftOpen, Settings2, CircleHelp } from "lucide-react";
import type { RouteId } from "../app/types";

const tasks = [
  { id: "library", label: "Library", icon: Images },
  { id: "workspace", label: "Analyze", icon: Microscope },
  { id: "processing", label: "Processing", icon: ListOrdered },
  { id: "review", label: "Review", icon: ClipboardCheck },
] as const;
const utilities = [
  { id: "lab", label: "Assays & protocols", icon: Beaker },
  { id: "compare", label: "Compare results", icon: FlaskConical },
  { id: "models", label: "Models", icon: Boxes },
  { id: "settings", label: "Settings", icon: Settings2 },
  { id: "help", label: "Help & about", icon: CircleHelp },
] as const;

export function Rail({ active, onChange, collapsed, onCollapse }: { active: RouteId; onChange: (route: RouteId) => void; collapsed: boolean; onCollapse: () => void }) {
  return <nav className={`rail ${collapsed ? "collapsed" : ""}`} aria-label="Primary">
    <div className="rail-tasks">{tasks.map(({ id, label, icon: Icon }) => <button key={id} className={active === id ? "active" : ""} onClick={() => onChange(id)} aria-current={active === id ? "page" : undefined} title={label}><Icon size={19} /><span>{label}</span></button>)}</div>
    <details className="rail-more"><summary title="More tools"><MoreHorizontal size={19} /><span>More</span></summary><div>{utilities.map(({ id, label, icon: Icon }) => <button key={id} className={active === id || (id === "help" && active === "capabilities") ? "active" : ""} onClick={(event) => { onChange(id); event.currentTarget.closest("details")?.removeAttribute("open"); }}><Icon size={18} /><span>{label}</span></button>)}</div></details>
    <button className="rail-collapse" onClick={onCollapse} aria-label={collapsed ? "Expand navigation" : "Collapse navigation"}>{collapsed ? <PanelLeftOpen size={19} /> : <PanelLeftClose size={19} />}<span>Collapse</span></button>
  </nav>;
}
