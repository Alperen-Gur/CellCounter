import { ListOrdered } from "lucide-react";
import { useState } from "react";
import type { AnalysisJob } from "../app/workflow";
import { estimatedRemainingMs } from "../app/workflow";
import type { WorkspaceImage } from "../app/types";

export function ProcessingPanel({ image, images, busy, modelReady, jobs, onProcess, onResume, onPause, onCancel, onReview, onAnalyze }: {
  image?: WorkspaceImage; images: readonly WorkspaceImage[]; busy: boolean; modelReady: boolean; jobs: readonly AnalysisJob[];
  onProcess(all: boolean): void; onResume(job: AnalysisJob, retry: boolean): void;
  onPause(): void; onCancel(): void; onReview(): void; onAnalyze(): void;
}) {
  const [scope, setScope] = useState("all");
  const latest = jobs.slice().sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  const [limit, setLimit] = useState(10);
  return <main className="page-view processing-view">
    <header className="page-heading"><div><span className="eyebrow">Local study</span><h1>Processing</h1><p>Results save after each image. Resume interrupted work or retry images that need attention.</p></div><button className="secondary-button" onClick={onReview}>Review results</button></header>
    <section className="queue-start" aria-label="Start processing"><div><strong>{images.length} images in this study</strong><p>{modelReady ? "Uses your current analysis setup, with calibration recorded for each image." : "The selected method is unavailable. Open setup and choose the built-in classical method."}</p></div><div className="processing-actions"><button className="secondary-button" onClick={onAnalyze}>View setup</button><select aria-label="Processing scope" value={scope} onChange={(event) => setScope(event.target.value)}><option value="all">All {images.length} images</option><option value="image">Current image</option></select><button className="run-button" disabled={!image || busy || !modelReady} onClick={() => onProcess(scope === "all")}>Start processing</button></div></section>
    {!latest.length && <div className="page-empty"><ListOrdered size={28} /><h2>No processing jobs yet</h2><p>Preview a representative image in Analyze, then process it or the whole study.</p><button className="secondary-button" onClick={onAnalyze}>Go to Analyze</button></div>}
    <section className="processing-panel" aria-label="Processing jobs">{latest.slice(0, limit).map((job) => {
      const complete = job.items.filter((item) => item.state === "complete").length;
      const failed = job.items.filter((item) => item.state === "failed");
      const eta = estimatedRemainingMs(job);
      return <details className="processing-job" key={job.id} open={job.state !== "complete"}>
        <summary><span><strong>{job.settings.model.displayName}</strong><small>{new Date(job.createdAt).toLocaleString()}</small></span><span className={`job-state ${job.state}`}>{job.state === "failed" ? "Needs attention" : job.state}</span><span>{complete} of {job.items.length} completed{failed.length ? ` · ${failed.length} need attention` : ""}</span></summary>
        <div className="job-detail"><progress aria-label="Images completed" value={complete} max={job.items.length} /><p>{eta !== null && job.state === "running" ? `About ${Math.ceil(eta / 1000)} seconds remaining. ` : ""}Original settings are retained for resume and retry.</p>
        <div className="processing-actions">{job.state === "running" && busy && <><button className="secondary-button" onClick={onPause}>Pause after current image</button><button className="secondary-button" onClick={onCancel}>Cancel current and pause</button></>}{job.state === "paused" && <button className="run-button" disabled={busy} onClick={() => onResume(job, false)}>Resume remaining</button>}{failed.length > 0 && <button className="run-button" disabled={busy} onClick={() => onResume(job, true)}>Retry {failed.length} failed</button>}</div>
        <ol className="job-items">{job.items.slice(0, 50).map((item) => <li key={item.imageId}><strong>{item.fileName}</strong><span>{item.state}{item.reusedPreview ? " · preview reused" : ""}</span>{item.error && <p className="job-error">{item.error}</p>}</li>)}</ol>{job.items.length > 50 && <p>Showing the first 50 of {job.items.length} image jobs.</p>}</div>
      </details>;
    })}{latest.length > limit && <button className="secondary-button" onClick={() => setLimit((value) => value + 10)}>Show older jobs</button>}</section>
  </main>;
}
