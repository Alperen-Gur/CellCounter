import { timeLocalOperation } from "../../../shared/diagnostics/performance";
import type { WorkspaceArtifactKind, WorkspaceExportRequest } from "./workspace-export.worker";
import { validateMetadataGraph } from "../export/bundles";

export type { WorkspaceArtifactKind };

function buildWorkspaceArtifactImpl(kind: WorkspaceArtifactKind, request: Omit<WorkspaceExportRequest, "id" | "kind">, signal?: AbortSignal): Promise<{ bytes: Uint8Array; sidecar?: string }> {
  validateMetadataGraph(request);
  if (request.cells.length > 100000 || request.cells.reduce((sum, cell) => sum + (cell.contourPx?.length ?? 32), 0) > 500000) throw new Error("Export geometry exceeds 100,000 cells or 500,000 vertices.");
  if ((request.groundTruth?.length ?? 0) > 100000) throw new Error("Export exceeds 100,000 ground-truth marks.");
  const worker = new Worker(new URL("./workspace-export.worker.ts", import.meta.url), { type: "module", name: `cellcounter-export-${kind}` });
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const cancel = () => { signal?.removeEventListener("abort", cancel); worker.terminate(); reject(new DOMException("Export cancelled", "AbortError")); };
    signal?.addEventListener("abort", cancel, { once: true });
    if (signal?.aborted) { cancel(); return; }
    worker.onmessage = (event: MessageEvent<{ id: string; ok: boolean; bytes?: Uint8Array; sidecar?: string; error?: string }>) => {
      if (event.data.id !== id) return;
      signal?.removeEventListener("abort", cancel); worker.terminate();
      if (event.data.ok && event.data.bytes) resolve({ bytes: event.data.bytes, sidecar: event.data.sidecar });
      else reject(new Error(event.data.error ?? "Export failed"));
    };
    worker.onerror = (event) => { signal?.removeEventListener("abort", cancel); worker.terminate(); reject(new Error(event.message || "Export worker failed")); };
    worker.onmessageerror = () => { signal?.removeEventListener("abort", cancel); worker.terminate(); reject(new Error("Export worker returned an unreadable payload")); };
    try { worker.postMessage({ ...request, id, kind }); } catch (cause) { signal?.removeEventListener("abort", cancel); worker.terminate(); reject(cause); }
  });
}

export function buildWorkspaceArtifact(kind: WorkspaceArtifactKind, request: Omit<WorkspaceExportRequest, "id" | "kind">, signal?: AbortSignal): Promise<{ bytes: Uint8Array; sidecar?: string }> {
  return timeLocalOperation("export.prepare", () => buildWorkspaceArtifactImpl(kind, request, signal));
}
