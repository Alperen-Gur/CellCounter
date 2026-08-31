import { Check, Image as ImageIcon, Plus } from "lucide-react";
import type { WorkspaceImage } from "../app/types";

export function Filmstrip({ images, activeId, onSelect, onImport }: { images: WorkspaceImage[]; activeId?: string; onSelect: (id: string) => void; onImport: () => void }) {
  if (!images.length) return null;
  return (
    <footer className="filmstrip">
      <span className="filmstrip-label">Study <b>{images.length}</b></span>
      <div className="filmstrip-items">
        {images.map((image, index) => (
          <button key={image.id} className={activeId === image.id ? "active" : ""} onClick={() => onSelect(image.id)} title={image.fileName}>
            <img src={image.thumbnailUrl || image.objectUrl} alt="" /><span>{index + 1}</span>{image.cells.length > 0 && <i><Check size={10} /></i>}
          </button>
        ))}
        <button className="add-frame" onClick={onImport} title="Import more images"><Plus size={18} /><ImageIcon size={11} /></button>
      </div>
    </footer>
  );
}
