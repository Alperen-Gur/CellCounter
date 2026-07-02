/**
 * kernel/transport/InferenceTransport.ts — the frontend↔backend inference seam
 * (ARCHITECTURE.md §3.1).
 *
 * This is the interface that lets the later browser build swap the desktop
 * `TauriSidecarTransport` for an `OnnxWebTransport` (onnxruntime-web / WebGPU)
 * WITHOUT any page, store, viewport, or engine changing — both return the same
 * domain DTOs and emit the same progress events.
 *
 * ┌──────────────────────────────────────────────────────────────────────┐
 * │  FROZEN CONTRACT (§6.1) — and DELIBERATELY implementation-free.        │
 * │  This file must NEVER import onnxruntime, @tauri-apps, or any concrete │
 * │  backend. It is types only. Concrete impls live in sibling files.     │
 * └──────────────────────────────────────────────────────────────────────┘
 *
 * The DTOs are the canonical definitions in `kernel/types.ts`; we re-export
 * them here so the transport seam and the persistence/domain layer never
 * diverge (a single source of truth for `CellDTO`, `DetectionResultDTO`, …).
 */

import type {
  DetectionParams,
  CellDTO,
  DetectionResultDTO,
  DetectionProgress,
  DetectionError,
} from "../types";

// Re-export the canonical detection DTOs so callers can import the whole
// detection vocabulary from the transport module (§3.1 lists them here).
export type {
  DetectionParams,
  CellDTO,
  DetectionResultDTO,
  DetectionProgress,
  DetectionError,
};

/**
 * The narrow inference port every screen talks to. Both the desktop sidecar
 * transport and the future WebGPU transport implement exactly this.
 */
export interface InferenceTransport {
  /**
   * Run detection on one image. Resolves with a `DetectionResultDTO`; rejects
   * with a `DetectionError` (`{ kind, … }`) on failure. `onProgress` receives
   * streamed stage / device / weights events. Passing an already-aborted or
   * later-aborted `signal` cancels the in-flight run (SIGTERM→SIGKILL on
   * desktop) and rejects with `{ kind: "cancelled" }`.
   */
  detect(
    imagePath: string,
    params: DetectionParams,
    onProgress?: (p: DetectionProgress) => void,
    signal?: AbortSignal,
  ): Promise<DetectionResultDTO>;

  /** Cancel an in-flight run by its id (SIGTERM → SIGKILL on desktop). */
  cancel(runId: string): Promise<void>;

  /** Is the active model runnable right now? (venv present + importable). */
  availability(modelId: string): Promise<{ installed: boolean; reason?: string }>;
}

/**
 * A `DetectionError` shaped as a throwable `Error` so it survives Promise
 * rejection with a `.message` while still carrying the structured `kind`.
 * Consumers can `if (isDetectionError(e))` then `switch (e.detail.kind)`.
 */
export class DetectionErrorException extends Error {
  readonly detail: DetectionError;
  constructor(detail: DetectionError) {
    super(describeDetectionError(detail));
    this.name = "DetectionError";
    this.detail = detail;
  }
}

/** Type guard for a `DetectionErrorException`. */
export function isDetectionError(e: unknown): e is DetectionErrorException {
  return e instanceof DetectionErrorException;
}

/** Human-readable one-liner for a structured `DetectionError`. */
export function describeDetectionError(err: DetectionError): string {
  switch (err.kind) {
    case "modelNotInstalled":
      return `Model "${err.modelId}" is not installed.`;
    case "sidecarFailed":
      return `Detection failed (exit ${err.exitCode}): ${err.stderr}`;
    case "imageDecodeFailed":
      return "The image could not be decoded.";
    case "cancelled":
      return "Detection was cancelled.";
  }
}

/**
 * Best-effort coercion of an unknown thrown/rejected value into a
 * `DetectionError`. The Rust `DetectionErrorDto` serializes as a tagged object
 * `{ kind, … }`; anything else (a plain string, a network error) collapses to
 * `sidecarFailed` so callers always get a structured shape.
 */
export function toDetectionError(value: unknown): DetectionError {
  if (value && typeof value === "object" && "kind" in value) {
    const kind = (value as { kind: unknown }).kind;
    if (
      kind === "modelNotInstalled" ||
      kind === "sidecarFailed" ||
      kind === "imageDecodeFailed" ||
      kind === "cancelled"
    ) {
      return value as DetectionError;
    }
  }
  const stderr =
    typeof value === "string"
      ? value
      : value instanceof Error
        ? value.message
        : JSON.stringify(value);
  return { kind: "sidecarFailed", exitCode: -1, stderr };
}
