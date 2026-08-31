import type { WorkspaceArtifactKind, WorkspaceExportRequest } from "./workspace-export.worker";

export type { WorkspaceArtifactKind };

export function buildWorkspaceArtifact(kind: WorkspaceArtifactKind, request: Omit<WorkspaceExportRequest, "id" | "kind">, signal?: AbortSignal): Promise<{ bytes: Uint8Array; sidecar?: string }> {
  const worker = new Worker(new URL("./workspace-export.worker.ts", import.meta.url), { type: "module", name: `cellcounter-export-${kind}` });
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const cancel = () => { worker.terminate(); reject(new DOMException("Export cancelled", "AbortError")); };
    signal?.addEventListener("abort", cancel, { once: true });
    if (signal?.aborted) { cancel(); return; }
    worker.onmessage = (event: MessageEvent<{ id: string; ok: boolean; bytes?: Uint8Array; sidecar?: string; error?: string }>) => {
      if (event.data.id !== id) return;
      signal?.removeEventListener("abort", cancel); worker.terminate();
      if (event.data.ok && event.data.bytes) resolve({ bytes: event.data.bytes, sidecar: event.data.sidecar });
      else reject(new Error(event.data.error ?? "Export failed"));
    };
    worker.onerror = (event) => { signal?.removeEventListener("abort", cancel); worker.terminate(); reject(new Error(event.message || "Export worker failed")); };
    worker.postMessage({ ...request, id, kind });
  });
}
