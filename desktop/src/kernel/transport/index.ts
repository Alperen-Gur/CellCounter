/**
 * kernel/transport/index.ts — the transport singleton / provider.
 *
 * The one place the app resolves "which InferenceTransport am I using". Pages
 * call `getTransport()` and never construct a concrete transport themselves —
 * so the browser build swaps the factory here (desktop → `TauriSidecarTransport`,
 * browser → `OnnxWebTransport`) and nothing downstream changes.
 *
 * This module re-exports the interface + DTOs so a page can import everything
 * transport-related from `kernel/transport`.
 */

import type { InferenceTransport } from "./InferenceTransport";
import { TauriSidecarTransport } from "./TauriSidecarTransport";

export * from "./InferenceTransport";
export { TauriSidecarTransport } from "./TauriSidecarTransport";

/** Lazily-constructed process-wide transport instance. */
let instance: InferenceTransport | null = null;

/**
 * Factory for the active build's transport. Desktop returns the Tauri sidecar
 * transport; the future browser build overrides this (or calls
 * `setTransport`) to return an onnxruntime-web transport. Kept as a function
 * so tests can stub it before first use.
 */
function createDefaultTransport(): InferenceTransport {
  return new TauriSidecarTransport();
}

/** The active `InferenceTransport` (constructed on first use). */
export function getTransport(): InferenceTransport {
  if (instance === null) {
    instance = createDefaultTransport();
  }
  return instance;
}

/**
 * Override the active transport. Intended for the browser build's bootstrap and
 * for tests (inject a fake). Passing `null` resets to the default factory on the
 * next `getTransport()` call.
 */
export function setTransport(transport: InferenceTransport | null): void {
  instance = transport;
}
