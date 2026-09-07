import { Microscope } from "lucide-react";

export function BrandMark({ compact = false }: { compact?: boolean }) {
  return <div className="brand-mark" aria-label="CellCounter"><Microscope size={25} strokeWidth={1.6} aria-hidden="true" />{!compact && <span className="brand-word">CellCounter</span>}</div>;
}
