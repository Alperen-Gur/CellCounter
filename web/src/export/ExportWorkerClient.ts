import type { ExportCell, RgbaImage } from "./types";
import type { ExportWorkerRequest, ExportWorkerResponse } from "./workerProtocol";

function randomId(): string { return crypto.randomUUID(); }

function run(request: ExportWorkerRequest, transfer: Transferable[], signal?: AbortSignal): Promise<Uint8Array> {
  const worker = new Worker(new URL("./export.worker.ts", import.meta.url), { type: "module", name: "cellcounter-export" });
  return new Promise((resolve, reject) => {
    const close = () => { signal?.removeEventListener("abort", cancel); worker.terminate(); };
    const cancel = () => { close(); reject(new DOMException("Export cancelled.", "AbortError")); };
    signal?.addEventListener("abort", cancel, { once: true });
    if (signal?.aborted) { cancel(); return; }
    worker.onerror = (event) => { close(); reject(new Error(event.message || "Export Worker failed.")); };
    worker.onmessage = (event: MessageEvent<ExportWorkerResponse>) => {
      if (event.data.id !== request.id) return;
      close();
      if (event.data.ok) resolve(event.data.bytes); else reject(new Error(event.data.error));
    };
    worker.postMessage(request, transfer);
  });
}

/** Copies source bytes once, then compresses/composites entirely off the UI thread. */
export function exportAnnotatedPngInWorker(source: RgbaImage, cells: readonly ExportCell[], options: { readonly color?: readonly [number, number, number, number]; readonly lineWidthPx?: number; readonly minimumConfidence?: number } = {}, signal?: AbortSignal): Promise<Uint8Array> {
  const copied = new Uint8ClampedArray(source.data);
  const request: ExportWorkerRequest = { id: randomId(), kind: "annotated-png", source: { data: copied, width: source.width, height: source.height }, cells, options };
  return run(request, [copied.buffer], signal);
}

export function exportSegmentationMaskPngInWorker(labels: Uint32Array, width: number, height: number, signal?: AbortSignal): Promise<Uint8Array> {
  const copied = new Uint32Array(labels);
  return run({ id: randomId(), kind: "segmentation-png", labels: copied, width, height }, [copied.buffer], signal);
}
