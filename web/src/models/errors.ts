import type { ModelId } from "../domain/types";

export type InferenceErrorCode =
  | "no-webgpu"
  | "model-artifact-unavailable"
  | "model-artifact-hash-mismatch"
  | "unsupported-operator"
  | "image-decode-failed"
  | "invalid-model-output"
  | "cancelled"
  | "inference-failed";

export class InferenceError extends Error {
  constructor(
    readonly code: InferenceErrorCode,
    message: string,
    readonly modelId: ModelId | null = null,
    options?: ErrorOptions,
  ) {
    super(message, options);
    this.name = "InferenceError";
  }
}

export class NoWebGpuError extends InferenceError {
  constructor() {
    super("no-webgpu", "WebGPU is unavailable. CellCounter Web does not fall back to CPU or upload images.");
    this.name = "NoWebGpuError";
  }
}

export class ModelArtifactUnavailableError extends InferenceError {
  constructor(modelId: ModelId, detail = "The release artifact has not been published") {
    super("model-artifact-unavailable", `${modelId}: ${detail}`, modelId);
    this.name = "ModelArtifactUnavailableError";
  }
}

export class ArtifactHashMismatchError extends InferenceError {
  constructor(modelId: ModelId, expected: string, actual: string) {
    super(
      "model-artifact-hash-mismatch",
      `${modelId}: model SHA-256 mismatch (expected ${expected}, received ${actual})`,
      modelId,
    );
    this.name = "ArtifactHashMismatchError";
  }
}

export class UnsupportedOperatorError extends InferenceError {
  constructor(modelId: ModelId, detail: string, options?: ErrorOptions) {
    super("unsupported-operator", `${modelId}: WebGPU cannot execute the exported model: ${detail}`, modelId, options);
    this.name = "UnsupportedOperatorError";
  }
}

export class CancelledInferenceError extends InferenceError {
  constructor(modelId: ModelId | null = null) {
    super("cancelled", "Analysis cancelled", modelId);
    this.name = "CancelledInferenceError";
  }
}

export function normalizeInferenceError(error: unknown, modelId: ModelId): InferenceError {
  if (error instanceof InferenceError) return error;
  if (error instanceof DOMException && error.name === "AbortError") return new CancelledInferenceError(modelId);
  const detail = error instanceof Error ? error.message : String(error);
  if (/not implemented|unsupported (?:op|operator)|kernel.*not found|no available backend/i.test(detail)) {
    return new UnsupportedOperatorError(modelId, detail, { cause: error });
  }
  return new InferenceError("inference-failed", `${modelId}: ${detail}`, modelId, { cause: error });
}
