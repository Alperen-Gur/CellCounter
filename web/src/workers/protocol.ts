import type { DetectionResultDTO } from "../domain/types";
import type { InferenceProgress, WebInferenceRequest } from "../models/WebGpuInference";
import type { InferenceErrorCode } from "../models/errors";

export interface AnalyzeWorkerRequest {
  readonly type: "analyze";
  readonly requestId: string;
  readonly payload: Omit<WebInferenceRequest, "signal" | "onProgress">;
}

export interface CancelWorkerRequest {
  readonly type: "cancel";
  readonly requestId: string;
}

export type InferenceWorkerRequest = AnalyzeWorkerRequest | CancelWorkerRequest;

export type InferenceWorkerResponse =
  | { readonly type: "progress"; readonly requestId: string; readonly progress: InferenceProgress }
  | { readonly type: "result"; readonly requestId: string; readonly result: DetectionResultDTO }
  | {
      readonly type: "error";
      readonly requestId: string;
      readonly error: { readonly name: string; readonly message: string; readonly code: InferenceErrorCode };
    };
