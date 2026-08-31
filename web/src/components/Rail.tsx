import { Beaker, Boxes, ClipboardCheck, FlaskConical, Images, ListChecks, Microscope, Settings2 } from "lucide-react";
import type { RouteId } from "../app/types";

const items: Array<{ id: RouteId; label: string; icon: typeof Microscope }> = [
  { id: "workspace", label: "Workspace", icon: Microscope },
  { id: "library", label: "Library", icon: Images },
  { id: "review", label: "Review", icon: ClipboardCheck },
  { id: "lab", label: "Lab", icon: Beaker },
  { id: "compare", label: "Compare", icon: FlaskConical },
  { id: "models", label: "Models", icon: Boxes },
  { id: "capabilities", label: "Parity", icon: ListChecks },
  { id: "settings", label: "Settings", icon: Settings2 },
];

export function Rail({ active, onChange }: { active: RouteId; onChange: (route: RouteId) => void }) {
  return (
    <nav className="rail" aria-label="Primary">
      {items.map(({ id, label, icon: Icon }) => (
        <button key={id} className={active === id ? "active" : ""} onClick={() => onChange(id)} aria-current={active === id ? "page" : undefined}>
          <Icon size={19} strokeWidth={1.8} />
          <span>{label}</span>
        </button>
      ))}
    </nav>
  );
}
