import type { AdvancedJob } from "./advanced.worker";
export function runAdvanced<T>(request: Omit<AdvancedJob, "id">, signal?: AbortSignal): Promise<T> {
  if (signal?.aborted) return Promise.reject(new DOMException("Operation cancelled", "AbortError"));
  const worker = new Worker(new URL("./advanced.worker.ts", import.meta.url), { type: "module", name: "cellcounter-advanced" });
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const cleanup = () => { signal?.removeEventListener("abort", cancel); worker.terminate(); };
    const cancel = () => { cleanup(); reject(new DOMException("Operation cancelled", "AbortError")); };
    signal?.addEventListener("abort", cancel, { once: true });
    worker.onmessage = (event: MessageEvent<{ id: string; ok: boolean; result?: T; error?: string }>) => { if (event.data.id !== id) return; cleanup(); if (event.data.ok) resolve(event.data.result as T); else reject(new Error(event.data.error ?? "Advanced operation failed")); };
    worker.onerror = (event) => { cleanup(); reject(new Error(event.message || "Advanced worker failed")); };
    try { worker.postMessage({ ...request, id }); } catch (cause) { cleanup(); reject(cause); }
  });
}
