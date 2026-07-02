/**
 * pages/processing/processingController.ts — the active-run registry for the
 * Processing screen (feature task `feat-processing`).
 *
 * WHY THIS EXISTS
 * ---------------
 * The Processing screen only *visualises* a detection run and offers a Cancel
 * action; the run itself is dispatched by Home (`feat-home-import`) or Results
 * (`feat-results-viewer`). Per ARCHITECTURE.md §3.1, cancelling means calling
 * `InferenceTransport.cancel(runId)` — so the Processing screen needs the
 * *runId* of the in-flight run.
 *
 * That runId cannot live on the store: the `ProcessingSlice` shape is FROZEN
 * (§6.4) and holds only `{progress, stageLine, device, lastStageUpdateAt}` — no
 * runId, no AbortController. So this module provides a tiny, dependency-free
 * registry that the dispatcher registers its run against and the Processing
 * screen reads. It lives inside the `pages/processing/` directory this task
 * owns, so a dispatcher imports it without any other page's files changing.
 *
 * CONTRACT for dispatchers (Home / Results), for when they are implemented:
 *
 *   import { beginProcessingRun } from "../processing/processingController";
 *   const controller = new AbortController();
 *   const handle = beginProcessingRun({
 *     runId,                       // the id passed to transport.detect(...)
 *     total: images.length,        // batch size, for overall progress
 *     controller,                  // optional: abort() is called on cancel
 *     label: batch.displayName,    // optional: shown on the Processing screen
 *   });
 *   // …drive store.setProgress / setStageLine / setDevice while running…
 *   handle.setActiveRunId(nextRunId); // when advancing to the next image
 *   handle.finish();                  // in a finally{} when the batch settles
 *
 * The Processing screen calls `cancelActiveProcessingRun()` on Cancel; it aborts
 * the registered controller AND calls `transport.cancel(runId)` (belt and
 * braces — the AbortSignal path also triggers a backend cancel, but a
 * dispatcher may register a runId without a controller).
 *
 * Everything here is headless and pure-TS: no React, no Tauri, no store import.
 * The Processing screen owns the store reads; this file owns only run identity +
 * cancel plumbing so it stays trivially testable.
 */

import { getTransport } from "../../kernel/transport";

/** A run currently registered as "the thing the Processing screen is showing". */
export interface ActiveProcessingRun {
  /** The most recent per-image runId handed to `transport.detect(...)`. */
  runId: string;
  /** Total units of work (images in the batch); used for overall progress. */
  total: number;
  /** Optional AbortController the dispatcher wired into `detect(…, signal)`. */
  controller?: AbortController;
  /** Optional human label (e.g. the batch display name). */
  label?: string;
  /** Epoch ms this run was registered — lets the screen ignore stale runs. */
  startedAt: number;
}

/** Handle returned to the dispatcher to update / retire its registration. */
export interface ProcessingRunHandle {
  /** Swap in the runId of the image now being processed (mid-batch advance). */
  setActiveRunId(runId: string): void;
  /** Update the label shown for this run. */
  setLabel(label: string): void;
  /** Retire this run (call from a `finally` when the batch settles/cancels). */
  finish(): void;
}

type Listener = (run: ActiveProcessingRun | null) => void;

let active: ActiveProcessingRun | null = null;
const listeners = new Set<Listener>();

function emit(): void {
  for (const l of listeners) l(active);
}

/**
 * Register the run the Processing screen should display + be able to cancel.
 * Replaces any previously-registered run. Returns a handle the dispatcher uses
 * to update the active runId as it walks the batch and to retire the run when
 * done.
 */
export function beginProcessingRun(init: {
  runId: string;
  total: number;
  controller?: AbortController;
  label?: string;
}): ProcessingRunHandle {
  active = {
    runId: init.runId,
    total: Math.max(1, init.total),
    controller: init.controller,
    label: init.label,
    startedAt: Date.now(),
  };
  emit();

  // Capture identity so a stale handle can't retire a newer run.
  const startedAt = active.startedAt;

  const isStillCurrent = () => active !== null && active.startedAt === startedAt;

  return {
    setActiveRunId(runId: string) {
      if (isStillCurrent()) {
        active = { ...(active as ActiveProcessingRun), runId };
        emit();
      }
    },
    setLabel(label: string) {
      if (isStillCurrent()) {
        active = { ...(active as ActiveProcessingRun), label };
        emit();
      }
    },
    finish() {
      if (isStillCurrent()) {
        active = null;
        emit();
      }
    },
  };
}

/** The currently-registered run, or null if nothing is in flight. */
export function getActiveProcessingRun(): ActiveProcessingRun | null {
  return active;
}

/** Subscribe to registration changes; returns an unsubscribe fn. */
export function subscribeProcessingRun(listener: Listener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/**
 * Cancel the active run. Aborts the dispatcher's AbortController (which makes
 * `transport.detect` reject with `{kind:"cancelled"}`) AND calls
 * `transport.cancel(runId)` directly so cancellation works even when only a
 * runId was registered (no controller). Idempotent; safe when nothing is
 * registered. Returns the runId that was cancelled, or null.
 */
export async function cancelActiveProcessingRun(): Promise<string | null> {
  const run = active;
  if (!run) return null;

  // Retire immediately so a second Cancel click / re-entrancy is a no-op.
  active = null;
  emit();

  // Abort the dispatcher's signal first (its detect() loop stops enqueuing).
  try {
    run.controller?.abort();
  } catch {
    /* aborting an already-aborted controller is harmless */
  }

  // Belt-and-braces: tell the backend to SIGTERM→SIGKILL this run's process.
  try {
    await getTransport().cancel(run.runId);
  } catch {
    // A cancel failure (run already settled, IPC unavailable in preview) is
    // non-fatal — the UI has already left the Processing screen.
  }

  return run.runId;
}
