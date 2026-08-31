import type { DetectionResultDTO } from "../../../src/domain/types";
import type { InferenceEngine, WebInferenceRequest } from "../../../src/models/WebGpuInference";
import { CancelledInferenceError } from "../../../src/models/errors";
import { emptyDetection } from "./sample";

/** Deliberately test-owned; production code has no fixture-selection branch. */
export class TestOnlyInferenceEngine implements InferenceEngine {
  constructor(private readonly waitForAbort = false) {}

  async analyze(request: WebInferenceRequest): Promise<DetectionResultDTO> {
    request.onProgress?.({ stage: "inference", completed: 0, total: 1 });
    if (!this.waitForAbort) {
      request.onProgress?.({ stage: "inference", completed: 1, total: 1 });
      return emptyDetection;
    }
    return new Promise((_resolve, reject) => {
      const rejectCancelled = () => reject(new CancelledInferenceError(request.parameters.modelId));
      if (request.signal?.aborted) rejectCancelled();
      else request.signal?.addEventListener("abort", rejectCancelled, { once: true });
    });
  }
}
