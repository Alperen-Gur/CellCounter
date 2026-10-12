import { Check, Expand, ScanSearch, Trash2, SkipForward, Undo2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { imageReviewRisk } from "../app/reviewMetrics";
import type { WorkspaceImage } from "../app/types";

function ReviewCrop({ image, cell }: { image: WorkspaceImage; cell: WorkspaceImage["cells"][number] }) {
  const plane = image.analysis?.displayPlane;
  const [captured, setCaptured] = useState<{ blob: Blob; url: string }>();
  useEffect(() => { if (!plane) { setCaptured(undefined); return; } const url = URL.createObjectURL(plane); setCaptured({ blob: plane, url }); return () => URL.revokeObjectURL(url); }, [plane]);
  const url = plane ? captured?.blob === plane ? captured.url : undefined : !image.analysisId && !image.analysis ? image.thumbnailUrl || image.objectUrl : undefined;
  return <span className="review-thumb" title={url ? "Captured source-plane object crop" : "Open this field to load its captured analysis plane"}>{url ? <img src={url} alt="" style={{ position: "absolute", width: image.width * 64 / Math.max(8, cell.diameterPx * 2), height: image.height * 64 / Math.max(8, cell.diameterPx * 2), left: 32 - cell.cx * 64 / Math.max(8, cell.diameterPx * 2), top: 32 - cell.cy * 64 / Math.max(8, cell.diameterPx * 2), maxWidth: "none" }} /> : <ScanSearch size={18} />}</span>;
}

interface ReviewViewProps {
  images: readonly WorkspaceImage[];
  onOpen: (imageId: string, cellId: string) => void | Promise<void>;
  onAccept: (imageId: string, cellId: string) => void | Promise<void>;
  onReject: (imageId: string, cellId: string) => void | Promise<void>;
  onUndo?: () => void | Promise<void>;
  canUndo?: boolean;
  onResize: (imageId: string, cellId: string) => void | Promise<void>;
}

export function ReviewView({ images, onOpen, onAccept, onReject, onResize, onUndo, canUndo }: ReviewViewProps) {
  const [pending, setPending] = useState<string>();
  const [error, setError] = useState<string>();
  const [page, setPage] = useState(0);
  const [all, setAll] = useState(true);
  const [grid, setGrid] = useState(false);
  const [skipped, setSkipped] = useState<Set<string>>(() => new Set());
  const [skipHistory, setSkipHistory] = useState<string[]>([]);
  const [rankFields, setRankFields] = useState(true);
  const risks = useMemo(() => new Map(images.map((image) => [image.id, imageReviewRisk(image)])), [images]);
  const queue = useMemo(() => images.flatMap((image) => image.cells
    .filter((cell) => !cell.reviewed && !skipped.has(`${image.id}:${image.analysisId ?? "manual"}:${cell.id}`) && (all || cell.confidence < 0.65 || image.reviewConfidence === "low"))
    .map((cell) => ({ image, cell }))).sort((a, b) => (rankFields ? (risks.get(b.image.id)?.score ?? 0) - (risks.get(a.image.id)?.score ?? 0) : 0) || a.cell.confidence - b.cell.confidence), [images, all, skipped, rankFields, risks]);
  const currentPage = Math.min(page, Math.max(0, Math.ceil(queue.length / 100) - 1));

  const perform = async (action: "accept" | "reject" | "resize" | "skip", imageId: string, cellId: string) => {
    if (pending) return;
    setPending(`${imageId}:${cellId}`); setError(undefined);
    try {
      if (action === "skip") { const image = images.find((entry) => entry.id === imageId); const key = `${imageId}:${image?.analysisId ?? "manual"}:${cellId}`; setSkipped((old) => new Set([...old, key])); setSkipHistory((old) => [...old, key]); return; }
      setSkipHistory([]);
      await ({ accept: onAccept, reject: onReject, resize: onResize }[action])(imageId, cellId); }
    catch (cause) { setError(cause instanceof Error ? cause.message : "The review change could not be saved."); }
    finally { setPending(undefined); }
  };

  return (
    <main className="page-view review-view">
      <header className="page-heading"><div><span className="eyebrow">Quality control</span><h1>Review queue</h1><p>Inspect individual objects, then accept, resize, or reject them. Focus a row to use K, R, X, or S. Skips stay in this queue session and can be restored.</p></div><div className="review-total"><strong>{queue.length}</strong><span>to review</span></div></header>
      <div className="processing-actions"><label><input type="checkbox" checked={all} onChange={(event) => { setAll(event.target.checked); setPage(0); }} /> All unreviewed objects</label><label><input type="checkbox" checked={rankFields} onChange={(event) => setRankFields(event.target.checked)} /> Risk-ranked fields</label><button disabled={Boolean(pending) || (!canUndo && !skipHistory.length)} onClick={async () => { setError(undefined); if (skipHistory.length) { const key = skipHistory.at(-1)!; setSkipped((old) => { const next = new Set(old); next.delete(key); return next; }); setSkipHistory((old) => old.slice(0, -1)); } else { try { await onUndo?.(); } catch (cause) { setError(cause instanceof Error ? cause.message : String(cause)); } } }}><Undo2 size={14} /> Undo decision</button>{skipped.size > 0 && <button onClick={() => { setSkipped(new Set()); setSkipHistory([]); }}>Restore {skipped.size} skipped</button>}<button aria-pressed={grid} onClick={() => setGrid((value) => !value)}>{grid ? "List view" : "Grid view"}</button></div>
      {error && <p className="export-error" role="alert">{error}</p>}
      {!queue.length ? <div className="page-empty"><ScanSearch size={27} /><h2>The queue is clear</h2><p>{all ? "All objects in the current results have been reviewed. Process an image to add new objects." : "No objects meet the low-confidence filter. Choose all unreviewed objects to inspect the complete result."}</p></div> : (
        <div className={`review-list ${grid ? "review-grid" : ""}`} role="list" aria-label="Cells awaiting review">
          {queue.slice(currentPage * 100, (currentPage + 1) * 100).map(({ image, cell }) => (
            <article role="listitem" tabIndex={0} aria-label={`Review ${cell.id} in ${image.fileName}`} className="review-row" key={`${image.id}:${cell.id}`} onKeyDown={(event) => {
              if (event.defaultPrevented || event.nativeEvent.isComposing || event.ctrlKey || event.metaKey || event.altKey || event.nativeEvent.getModifierState("AltGraph") || (event.target as HTMLElement).closest("input, textarea, select, [contenteditable]")) return;
              const action = ({ k: "accept", x: "reject", r: "resize", s: "skip" } as const)[event.key.toLowerCase() as "k" | "x" | "r" | "s"];
              if (action && !pending) { event.preventDefault(); void perform(action, image.id, cell.id); }
            }}>
              <button className="review-source" onClick={() => onOpen(image.id, cell.id)}><ReviewCrop image={image} cell={cell} /><span><strong>{image.fileName}</strong><small>{cell.id} · {cell.diameterUm.toFixed(1)} µm</small></span></button>
              <span className="review-score" title={risks.get(image.id)?.reasons.join("; ")}>Field risk {risks.get(image.id)?.score ?? 0} · {image.modelId === "classical" ? "Threshold object" : `${Math.round(cell.confidence * 100)}%`}</span>
              <div className="review-actions"><button disabled={Boolean(pending)} onClick={() => void perform("skip", image.id, cell.id)} title="Skip · S"><SkipForward size={14} /> Skip</button><button disabled={Boolean(pending)} onClick={() => void perform("accept", image.id, cell.id)} title="Accept · K"><Check size={14} /> Accept</button><button disabled={Boolean(pending)} onClick={() => void perform("resize", image.id, cell.id)} title="Resize · R"><Expand size={14} /> Resize</button><button className="reject" disabled={Boolean(pending)} onClick={() => void perform("reject", image.id, cell.id)} title="Reject · X"><Trash2 size={14} /> Reject</button></div>
            </article>
          ))}
          <div className="processing-actions"><button disabled={currentPage === 0} onClick={() => setPage(currentPage - 1)}>Previous 100</button><span>{currentPage * 100 + 1}–{Math.min(queue.length, (currentPage + 1) * 100)} of {queue.length}</span><button disabled={(currentPage + 1) * 100 >= queue.length} onClick={() => setPage(currentPage + 1)}>Next 100</button></div>
        </div>
      )}
    </main>
  );
}
