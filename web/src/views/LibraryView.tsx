import { FolderOpen, Image as ImageIcon, Search, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import type { WorkspaceImage } from "../app/types";

interface LibraryViewProps {
  images: WorkspaceImage[];
  activeId?: string;
  onOpen: (id: string) => void;
  onRemove: (id: string) => void;
  onCondition: (id: string, condition: string) => void;
  onImport: () => void;
  onImportFolder: () => void;
}

export function LibraryView({ images, activeId, onOpen, onRemove, onCondition, onImport, onImportFolder }: LibraryViewProps) {
  const [query, setQuery] = useState("");
  const visible = useMemo(() => images.filter((image) => image.fileName.toLowerCase().includes(query.toLowerCase())), [images, query]);
  return (
    <main className="page-view library-view">
      <header className="page-heading"><div><span className="eyebrow">Local study</span><h1>Image library</h1><p>Every source image and correction stays in this browser profile.</p></div><div className="toolbar-actions"><button className="secondary-button" onClick={onImportFolder}><FolderOpen size={15} /> Import folder</button><button className="run-button" onClick={onImport}>Import images</button></div></header>
      <div className="view-toolbar"><label className="search-field"><Search size={16} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Find an image" /></label><span>{visible.length} of {images.length}</span></div>
      {visible.length ? (
        <div className="library-table" role="table" aria-label="Imported images">
          <div className="table-header" role="row"><span>Image</span><span>Condition</span><span>Objects</span><span>Calibration</span><span /></div>
          {visible.map((image) => (
            <div className={`table-row ${image.id === activeId ? "active" : ""}`} role="row" key={image.id}>
              <button className="image-cell" onClick={() => onOpen(image.id)}><img src={image.thumbnailUrl || image.objectUrl} alt="" /><span><strong>{image.fileName}</strong><small>{image.width} × {image.height} px</small></span></button>
              <label><span className="sr-only">Condition for {image.fileName}</span><input value={image.condition} onChange={(event) => onCondition(image.id, event.target.value)} /></label>
              <strong className="mono-value">{image.cells.length}</strong>
              <span className="mono-value">{image.pxPerUm} px/µm</span>
              <button className="row-action" onClick={() => onRemove(image.id)} aria-label={`Remove ${image.fileName}`}><Trash2 size={16} /></button>
            </div>
          ))}
        </div>
      ) : (
        <div className="page-empty"><ImageIcon size={26} /><h2>{images.length ? "Nothing matches" : "No local images yet"}</h2><p>{images.length ? "Try another search." : "Import a field of view to begin a private study."}</p></div>
      )}
    </main>
  );
}
