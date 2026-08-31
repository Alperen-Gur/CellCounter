import { Check, Expand, ScanSearch, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import type { WorkspaceImage } from "../app/types";

interface ReviewViewProps {
  images: readonly WorkspaceImage[];
  onOpen: (imageId: string, cellId: string) => void;
  onAccept: (imageId: string, cellId: string) => void;
  onReject: (imageId: string, cellId: string) => void;
  onResize: (imageId: string, cellId: string) => void;
}

export function ReviewView({ images, onOpen, onAccept, onReject, onResize }: ReviewViewProps) {
  const [limit, setLimit] = useState(100);
  const queue = useMemo(() => images.flatMap((image) => image.cells
    .filter((cell) => cell.confidence < 0.65 || image.reviewConfidence === "low")
    .map((cell) => ({ image, cell }))).sort((a, b) => a.cell.confidence - b.cell.confidence), [images]);

  return (
    <main className="page-view review-view">
      <header className="page-heading"><div><span className="eyebrow">Quality control</span><h1>Review queue</h1><p>Low-confidence objects are ordered for quick accept, reject, resize, or source-image inspection.</p></div><div className="review-total"><strong>{queue.length}</strong><span>to review</span></div></header>
      {!queue.length ? <div className="page-empty"><ScanSearch size={27} /><h2>The queue is clear</h2><p>Objects below 65% confidence, and cells in images marked low confidence, appear here automatically.</p></div> : (
        <div className="review-list" role="list" aria-label="Low-confidence cells">
          {queue.slice(0, limit).map(({ image, cell }) => (
            <article role="listitem" className="review-row" key={`${image.id}:${cell.id}`}>
              <button className="review-source" onClick={() => onOpen(image.id, cell.id)}><span className="review-thumb">{(image.thumbnailUrl || image.objectUrl) ? <img src={image.thumbnailUrl || image.objectUrl} alt="" /> : <ScanSearch size={18} />}</span><span><strong>{image.fileName}</strong><small>{cell.id} · {cell.diameterUm.toFixed(1)} µm</small></span></button>
              <span className="review-score">{Math.round(cell.confidence * 100)}%</span>
              <div className="review-actions"><button onClick={() => onAccept(image.id, cell.id)}><Check size={14} /> Accept</button><button onClick={() => onResize(image.id, cell.id)}><Expand size={14} /> Resize</button><button className="reject" onClick={() => onReject(image.id, cell.id)}><Trash2 size={14} /> Reject</button></div>
            </article>
          ))}
          {limit < queue.length && <button className="wide-secondary review-more" onClick={() => setLimit((value) => value + 100)}>Show next {Math.min(100, queue.length - limit)}</button>}
        </div>
      )}
    </main>
  );
}
