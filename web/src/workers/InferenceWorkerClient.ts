import type { DetectionResultDTO } from "../domain/types";
import { CancelledInferenceError } from "../models/errors";
import type { InferenceProgress, WebInferenceRequest } from "../models/WebGpuInference";
import { rehydrateWorkerError } from "./controller";
import type { InferenceWorkerRequest, InferenceWorkerResponse } from "./protocol";

export interface WorkerPort {
  postMessage(message: InferenceWorkerRequest): void;
  addEventListener(type: "message", listener: (event: MessageEvent<InferenceWorkerResponse>) => void): void;
  removeEventListener(type: "message", listener: (event: MessageEvent<InferenceWorkerResponse>) => void): void;
  terminate?(): void;
}

interface PendingRequest {
  readonly resolve: (result: DetectionResultDTO) => void;
  readonly reject: (error: unknown) => void;
  readonly onProgress?: (progress: InferenceProgress) => void;
  readonly removeAbortListener: () => void;
}

export type InferenceWorkerAnalyzeRequest = Omit<WebInferenceRequest, "signal"> & {
  /** Translated to an explicit cancel message; AbortSignal itself is never cloned. */
  readonly signal?: AbortSignal;
};

function requestId(): string {
  return crypto.randomUUID();
}

export class InferenceWorkerClient {
  private readonly pending = new Map<string, PendingRequest>();
  private disposed = false;

  private readonly onMessage = (event: MessageEvent<InferenceWorkerResponse>) => {
    const message = event.data;
    const pending = this.pending.get(message.requestId);
    if (!pending) return;
    if (message.type === "progress") {
      pending.onProgress?.(message.progress);
      return;
    }
    pending.removeAbortListener();
    this.pending.delete(message.requestId);
    if (message.type === "result") pending.resolve(message.result);
    else pending.reject(rehydrateWorkerError(message.error));
  };

  constructor(private readonly worker: WorkerPort) {
    worker.addEventListener("message", this.onMessage);
  }

  analyze(request: InferenceWorkerAnalyzeRequest): Promise<DetectionResultDTO> {
    if (this.disposed) return Promise.reject(new Error("Inference worker client has been disposed"));
    if (request.signal?.aborted) return Promise.reject(new CancelledInferenceError(request.parameters.modelId));
    const id = requestId();
    return new Promise((resolve, reject) => {
      const cancel = () => this.worker.postMessage({ type: "cancel", requestId: id });
      request.signal?.addEventListener("abort", cancel, { once: true });
      this.pending.set(id, {
        resolve,
        reject,
        onProgress: request.onProgress,
        removeAbortListener: () => request.signal?.removeEventListener("abort", cancel),
      });
      this.worker.postMessage({
        type: "analyze",
        requestId: id,
        payload: { source: request.source, calibration: request.calibration, parameters: request.parameters },
      });
    });
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.worker.removeEventListener("message", this.onMessage);
    this.worker.terminate?.();
    for (const pending of this.pending.values()) {
      pending.removeAbortListener();
      pending.reject(new CancelledInferenceError());
    }
    this.pending.clear();
  }
}
