import { timeLocalOperation } from "../../../shared/diagnostics/performance";
import { validateTrainingTransfer, type ReviewedTrainingSample } from "../export/bundles";
function buildReviewedTrainingArtifactImpl(samples: readonly ReviewedTrainingSample[], signal?: AbortSignal): Promise<Uint8Array> {
  if (signal?.aborted) return Promise.reject(new DOMException("Export cancelled", "AbortError"));
  try { validateTrainingTransfer(samples); } catch (error) { return Promise.reject(error); }
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL("./reviewedTraining.worker.ts", import.meta.url), { type: "module", name: "cellcounter-reviewed-training" });
    const id = crypto.randomUUID(); let settled = false;
    const finish = (bytes?: Uint8Array, error?: Error) => {
      if (settled) return; settled = true;
      signal?.removeEventListener("abort", cancel); worker.terminate();
      if (bytes) resolve(bytes); else reject(error ?? new Error("Training snapshot export failed"));
    };
    const cancel = () => finish(undefined, new DOMException("Export cancelled", "AbortError"));
    signal?.addEventListener("abort", cancel, { once: true });
    if (signal?.aborted) { cancel(); return; }
    worker.onmessage = (event: MessageEvent<{ id: string; ok: boolean; bytes?: Uint8Array; error?: string }>) => {
      if (event.data.id !== id) return;
      if (event.data.ok && event.data.bytes) finish(event.data.bytes); else finish(undefined, new Error(event.data.error ?? "Training snapshot export failed"));
    };
    worker.onerror = (event) => finish(undefined, new Error(event.message || "Training export worker failed"));
    worker.onmessageerror = () => finish(undefined, new Error("Training export result could not be transferred"));
    try { worker.postMessage({ id, samples }); } catch (error) { finish(undefined, error instanceof Error ? error : new Error(String(error))); }
  });
}

export function buildReviewedTrainingArtifact(samples: readonly ReviewedTrainingSample[], signal?: AbortSignal): Promise<Uint8Array> {
  return timeLocalOperation("export.prepare", () => buildReviewedTrainingArtifactImpl(samples, signal));
}
