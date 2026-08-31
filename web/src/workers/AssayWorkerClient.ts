import type { AssayJob, AssayKind } from "./assay.worker";

export type { AssayKind };
export type AssayRequest = Omit<AssayJob, "id" | "kind">;

export function runAssay(kind: AssayKind, request: AssayRequest, signal?: AbortSignal): Promise<unknown> {
  if (signal?.aborted) return Promise.reject(new DOMException("Assay cancelled", "AbortError"));
  const worker = new Worker(new URL("./assay.worker.ts", import.meta.url), { type: "module", name: `cellcounter-${kind}` });
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const abort = () => { worker.terminate(); reject(new DOMException("Assay cancelled", "AbortError")); };
    signal?.addEventListener("abort", abort, { once: true });
    worker.onmessage = (event: MessageEvent<{ id: string; ok: boolean; result?: unknown; error?: string }>) => {
      if (event.data.id !== id) return;
      signal?.removeEventListener("abort", abort); worker.terminate();
      if (event.data.ok) resolve(event.data.result); else reject(new Error(event.data.error ?? "Assay failed"));
    };
    worker.onerror = (event) => { signal?.removeEventListener("abort", abort); worker.terminate(); reject(new Error(event.message || "Assay worker failed")); };
    worker.postMessage({ ...request, id, kind });
  });
}
