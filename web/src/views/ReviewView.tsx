import { Check, Expand, ScanSearch, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import type { WorkspaceImage } from "../app/types";

interface ReviewViewProps {
  images: readonly WorkspaceImage[];
  onOpen: (imageId: string, cellId: string) => void | Promise<void>;
  onAccept: (imageId: string, cellId: string) => void | Promise<void>;
  onReject: (imageId: string, cellId: string) => void | Promise<void>;
  onResize: (imageId: string, cellId: string) => void | Promise<void>;
}

export function ReviewView({ images, onOpen, onAccept, onReject, onResize }: ReviewViewProps) {
  const [pending, setPending] = useState<string>();
  const [error, setError] = useState<string>();
  const [page, setPage] = useState(0);
  const [all, setAll] = useState(true);
  const [grid, setGrid] = useState(false);
  const queue = useMemo(() => images.flatMap((image) => image.cells
    .filter((cell) => !cell.reviewed && (all || cell.confidence < 0.65 || image.reviewConfidence === "low"))
    .map((cell) => ({ image, cell }))).sort((a, b) => a.cell.confidence - b.cell.confidence), [images, all]);
  const currentPage = Math.min(page, Math.max(0, Math.ceil(queue.length / 100) - 1));

  const perform = async (action: "accept" | "reject" | "resize", imageId: string, cellId: string) => {
    if (pending) return;
    setPending(`${imageId}:${cellId}`); setError(undefined);
    try { await ({ accept: onAccept, reject: onReject, resize: onResize }[action])(imageId, cellId); }
    catch (cause) { setError(cause instanceof Error ? cause.message : "The review change could not be saved."); }
    finally { setPending(undefined); }
  };

  return (
    <main className="page-view review-view">
      <header className="page-heading"><div><span className="eyebrow">Quality control</span><h1>Review queue</h1><p>Inspect individual objects, then accept, resize, or reject them. Focus a row to use K, R, or X.</p></div><div className="review-total"><strong>{queue.length}</strong><span>to review</span></div></header>
      <div className="processing-actions"><label><input type="checkbox" checked={all} onChange={(event) => { setAll(event.target.checked); setPage(0); }} /> All unreviewed objects</label><button aria-pressed={grid} onClick={() => setGrid((value) => !value)}>{grid ? "List view" : "Grid view"}</button></div>
      {error && <p className="export-error" role="alert">{error}</p>}
      {!queue.length ? <div className="page-empty"><ScanSearch size={27} /><h2>The queue is clear</h2><p>{all ? "All objects in the current results have been reviewed. Process an image to add new objects." : "No objects meet the low-confidence filter. Choose all unreviewed objects to inspect the complete result."}</p></div> : (
        <div className={`review-list ${grid ? "review-grid" : ""}`} role="list" aria-label="Cells awaiting review">
          {queue.slice(currentPage * 100, (currentPage + 1) * 100).map(({ image, cell }) => (
            <article role="listitem" tabIndex={0} aria-label={`Review ${cell.id} in ${image.fileName}`} className="review-row" key={`${image.id}:${cell.id}`} onKeyDown={(event) => {
              if (event.defaultPrevented || event.nativeEvent.isComposing || event.ctrlKey || event.metaKey || event.altKey || event.nativeEvent.getModifierState("AltGraph") || (event.target as HTMLElement).closest("input, textarea, select, [contenteditable]")) return;
              const action = ({ k: "accept", x: "reject", r: "resize" } as const)[event.key.toLowerCase() as "k" | "x" | "r"];
              if (action && !pending) { event.preventDefault(); void perform(action, image.id, cell.id); }
            }}>
              <button className="review-source" onClick={() => onOpen(image.id, cell.id)}><span className="review-thumb">{(image.thumbnailUrl || image.objectUrl) ? <img src={image.thumbnailUrl || image.objectUrl} alt="" /> : <ScanSearch size={18} />}</span><span><strong>{image.fileName}</strong><small>{cell.id} · {cell.diameterUm.toFixed(1)} µm</small></span></button>
              <span className="review-score">{image.modelId === "classical" ? "Threshold object" : `${Math.round(cell.confidence * 100)}%`}</span>
              <div className="review-actions"><button disabled={Boolean(pending)} onClick={() => void perform("accept", image.id, cell.id)} title="Accept · K"><Check size={14} /> Accept</button><button disabled={Boolean(pending)} onClick={() => void perform("resize", image.id, cell.id)} title="Resize · R"><Expand size={14} /> Resize</button><button className="reject" disabled={Boolean(pending)} onClick={() => void perform("reject", image.id, cell.id)} title="Reject · X"><Trash2 size={14} /> Reject</button></div>
            </article>
          ))}
          <div className="processing-actions"><button disabled={currentPage === 0} onClick={() => setPage(currentPage - 1)}>Previous 100</button><span>{currentPage * 100 + 1}–{Math.min(queue.length, (currentPage + 1) * 100)} of {queue.length}</span><button disabled={(currentPage + 1) * 100 >= queue.length} onClick={() => setPage(currentPage + 1)}>Next 100</button></div>
        </div>
      )}
    </main>
  );
}
