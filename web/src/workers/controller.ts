import type { InferenceEngine } from "../models/WebGpuInference";
import { InferenceError, normalizeInferenceError } from "../models/errors";
import type { ModelId } from "../domain/types";
import type { InferenceWorkerRequest, InferenceWorkerResponse } from "./protocol";

export interface WorkerController {
  handle(message: InferenceWorkerRequest): void;
  cancelAll(): void;
}

export function createInferenceWorkerController(
  engine: InferenceEngine | Promise<InferenceEngine>,
  post: (response: InferenceWorkerResponse) => void,
): WorkerController {
  const active = new Map<string, AbortController>();

  const handleAnalyze = async (message: Extract<InferenceWorkerRequest, { type: "analyze" }>) => {
    if (active.has(message.requestId)) {
      post({
        type: "error",
        requestId: message.requestId,
        error: { name: "InferenceError", code: "inference-failed", message: "Duplicate request id" },
      });
      return;
    }
    const abortController = new AbortController();
    active.set(message.requestId, abortController);
    try {
      const resolvedEngine = await engine;
      if (abortController.signal.aborted) throw new DOMException("Analysis cancelled", "AbortError");
      const result = await resolvedEngine.analyze({
        ...message.payload,
        signal: abortController.signal,
        onProgress: (progress) => {
          if (!abortController.signal.aborted) post({ type: "progress", requestId: message.requestId, progress });
        },
      });
      if (!abortController.signal.aborted) post({ type: "result", requestId: message.requestId, result });
    } catch (caught) {
      const modelId = message.payload.parameters.modelId as ModelId;
      const error = normalizeInferenceError(caught, modelId);
      post({
        type: "error",
        requestId: message.requestId,
        error: { name: error.name, code: error.code, message: error.message },
      });
    } finally {
      active.delete(message.requestId);
    }
  };

  return {
    handle(message) {
      if (message.type === "cancel") {
        active.get(message.requestId)?.abort();
        return;
      }
      void handleAnalyze(message);
    },
    cancelAll() {
      for (const controller of active.values()) controller.abort();
      active.clear();
    },
  };
}

export function rehydrateWorkerError(error: {
  readonly name: string;
  readonly message: string;
  readonly code: InferenceError["code"];
}): InferenceError {
  const result = new InferenceError(error.code, error.message);
  result.name = error.name;
  return result;
}
