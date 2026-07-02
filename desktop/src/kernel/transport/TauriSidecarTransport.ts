/**
 * kernel/transport/TauriSidecarTransport.ts — desktop `InferenceTransport`
 * (ARCHITECTURE.md §3.1).
 *
 * Talks to the Rust backend over `@tauri-apps/api`:
 *   - `invoke("run_detection", { imagePath, params, runId })` → DetectionResultDTO
 *   - `invoke("cancel_detection", { runId })`
 *   - `invoke("detection_availability", { modelId })` → { installed, reason? }
 *
 * Progress: `run_detection` streams `DetectionProgress` events on the per-run
 * Tauri event name `detection://progress/<runId>` (see `progress_event_name`
 * in `detection/ipc.rs`). We subscribe BEFORE invoking so no early stage line
 * is missed, forward each event to `onProgress`, and always unlisten on
 * settle.
 *
 * This is the ONLY transport file that may import `@tauri-apps`. The interface
 * (`InferenceTransport.ts`) stays backend-free so the browser build can supply
 * an onnxruntime-web implementation of the same seam.
 */

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

import type {
  InferenceTransport,
} from "./InferenceTransport";
import { toDetectionError, DetectionErrorException } from "./InferenceTransport";
import type {
  DetectionParams,
  DetectionProgress,
  DetectionResultDTO,
} from "../types";

/** Tauri event name a run's progress is emitted on (mirrors `progress_event_name`). */
function progressEventName(runId: string): string {
  return `detection://progress/${runId}`;
}

/** Generate a client-side run id. Used for progress routing + cancel. */
function newRunId(): string {
  // `crypto.randomUUID` is available in the Tauri webview (and modern browsers).
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  // Fallback: timestamp + random (only if randomUUID is somehow unavailable).
  return `run-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

export class TauriSidecarTransport implements InferenceTransport {
  async detect(
    imagePath: string,
    params: DetectionParams,
    onProgress?: (p: DetectionProgress) => void,
    signal?: AbortSignal,
  ): Promise<DetectionResultDTO> {
    const runId = newRunId();

    // Fast-fail if already aborted before we spawn anything.
    if (signal?.aborted) {
      throw new DetectionErrorException({ kind: "cancelled" });
    }

    // Subscribe to progress BEFORE invoking so we don't drop the first line.
    let unlisten: UnlistenFn | undefined;
    if (onProgress) {
      unlisten = await listen<DetectionProgress>(
        progressEventName(runId),
        (event) => {
          onProgress(event.payload);
        },
      );
    }

    // Wire the abort signal to a backend cancel. We keep the listener so we can
    // detach it on settle; cancelling makes the Rust command reject with a
    // `cancelled` DetectionError, which the catch below normalizes.
    const onAbort = () => {
      // Fire-and-forget: the run promise rejection carries the real outcome.
      void this.cancel(runId);
    };
    if (signal) {
      signal.addEventListener("abort", onAbort, { once: true });
    }

    try {
      const result = await invoke<DetectionResultDTO>("run_detection", {
        imagePath,
        params,
        runId,
      });
      return result;
    } catch (raw) {
      // The Rust `Err(DetectionErrorDto)` arrives as a tagged `{ kind, … }`
      // object; normalize anything else into a structured DetectionError.
      throw new DetectionErrorException(toDetectionError(raw));
    } finally {
      if (signal) signal.removeEventListener("abort", onAbort);
      if (unlisten) unlisten();
    }
  }

  async cancel(runId: string): Promise<void> {
    await invoke<void>("cancel_detection", { runId });
  }

  async availability(
    modelId: string,
  ): Promise<{ installed: boolean; reason?: string }> {
    return invoke<{ installed: boolean; reason?: string }>(
      "detection_availability",
      { modelId },
    );
  }
}
