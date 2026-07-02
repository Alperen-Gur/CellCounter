/**
 * pages/processing/ProcessingPage.tsx — the Processing screen
 * (feature task `feat-processing`, ARCHITECTURE.md §4 `/processing`).
 *
 * A determinate progress view for an in-flight detection batch. It is purely a
 * *visualiser + Cancel*: Home (`feat-home-import`) and Results
 * (`feat-results-viewer`) dispatch detection and push progress into the store's
 * `ProcessingSlice`; this screen reads that slice and offers Cancel.
 *
 * What it shows (per the task `output`):
 *   • overall batch progress     ← store.progress (0..1)
 *   • the live cellpose stderr    ← store.stageLine
 *     stage line
 *   • the resolved device         ← store.device  ("MPS" | "CPU" | "CUDA:0")
 *   • a Cancel action             → cancelActiveProcessingRun() → prior view
 *
 * Watchdog: a run has no hard timeout (§3.1) — CPU cellpose can sit on one
 * stage for a long time. We treat *active stderr* as progress: `lastStageUpdateAt`
 * is compared against a live clock, so the "live" indicator keeps pulsing while
 * stderr flows and only downgrades to "still working…" (never "dead") once the
 * stream goes quiet. Before the first numeric progress arrives, the bar shows an
 * indeterminate sweep rather than a stuck 0%.
 *
 * Boundaries: this task owns only `pages/processing/`. It never calls
 * `transport.detect` (the dispatchers do). Cancel reaches the in-flight run
 * through `processingController` (which holds the runId + optional
 * AbortController) because the FROZEN `ProcessingSlice` carries no runId.
 */

import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";

import { useAppStore } from "../../kernel/store/store";
import { navigate } from "../../components/useHashRoute";
import {
  cancelActiveProcessingRun,
  getActiveProcessingRun,
  subscribeProcessingRun,
  type ActiveProcessingRun,
} from "./processingController";
// Cross-page cancel primitive for Home-dispatched imports. Home's importFlow
// drives detection with its own AbortController and exposes abortActiveImport()
// as the documented Phase-3 cancel seam (it does NOT register with
// processingController, since the transport generates the per-image runId
// internally). Calling both here makes Cancel work for BOTH dispatch paths:
// Results-registered runs (processingController) and Home imports (importFlow).
import { abortActiveImport } from "../home/importFlow";

import "./processing.css";

/**
 * How long (ms) after the last stderr line we still call the run "live" before
 * downgrading the indicator to "still working…". Generous, because a single
 * cellpose stage (e.g. flow/dynamics on CPU) can be quiet for many seconds.
 */
const STALL_AFTER_MS = 12_000;

/** Subscribe the component to the active-run registry via useSyncExternalStore. */
function useActiveProcessingRun(): ActiveProcessingRun | null {
  return useSyncExternalStore(subscribeProcessingRun, getActiveProcessingRun);
}

/**
 * A slow ticking clock (returns `Date.now()`), so the watchdog re-evaluates
 * "seconds since last stderr" without needing the store to push an event. Only
 * ticks while `enabled`, to avoid a background timer on an idle screen.
 */
function useNowClock(enabled: boolean, intervalMs = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!enabled) return;
    setNow(Date.now());
    const id = window.setInterval(() => setNow(Date.now()), intervalMs);
    return () => window.clearInterval(id);
  }, [enabled, intervalMs]);
  return now;
}

export default function ProcessingPage() {
  // ---- reactive reads of the FROZEN ProcessingSlice ----
  const progress = useAppStore((s) => s.progress);
  const stageLine = useAppStore((s) => s.stageLine);
  const device = useAppStore((s) => s.device);
  const lastStageUpdateAt = useAppStore((s) => s.lastStageUpdateAt);

  // ---- the run this screen is showing / can cancel ----
  const activeRun = useActiveProcessingRun();
  const hasActiveRun = activeRun !== null;

  // A run is "in flight" from this screen's POV if either the controller has a
  // run registered, or the store still reports sub-100% progress with a stage
  // line (covers the brief window before a dispatcher registers, or a preview
  // where the controller isn't wired but the store is being driven).
  const inFlight = hasActiveRun || (progress < 1 && stageLine.length > 0);

  // Live clock only while something is in flight.
  const now = useNowClock(inFlight);

  // ---- watchdog: is stderr actively flowing? ----
  // The run counts as "live" when stderr flowed recently (§3.1: active stderr IS
  // progress). A freshly-registered run that hasn't emitted a line yet is also
  // treated as live during a warmup grace window — the model is loading, not
  // stalled — so we don't flash "Still working…" at t=0.
  const msSinceStage = lastStageUpdateAt > 0 ? now - lastStageUpdateAt : Infinity;
  const runAgeMs = activeRun ? now - activeRun.startedAt : Infinity;
  const inWarmup = msSinceStage === Infinity && runAgeMs < STALL_AFTER_MS;
  const stderrActive = inFlight && (msSinceStage < STALL_AFTER_MS || inWarmup);
  const stalled = inFlight && !stderrActive;

  // ---- progress math ----
  const pct = clampPct(progress);
  // Show an indeterminate sweep while a run is live but no numeric progress has
  // arrived yet (model download / first-image warmup). Determinate otherwise.
  const indeterminate = inFlight && progress <= 0;

  // ---- where to go on cancel / finish ----
  const returnToPriorView = useReturnToPriorView();

  // ---- cancel handling ----
  const [cancelling, setCancelling] = useState(false);

  const handleCancel = async () => {
    if (cancelling) return;
    setCancelling(true);
    try {
      // Abort a Home-dispatched import first (its detect() loop stops enqueuing
      // and each in-flight detect rejects with {kind:"cancelled"}), then cancel
      // any run registered on the processing controller (Results path). Both are
      // idempotent no-ops when their respective dispatcher isn't the source.
      abortActiveImport();
      await cancelActiveProcessingRun();
    } finally {
      // Clear any lingering processing state so the next visit starts clean.
      useAppStore.getState().resetProcessing();
      returnToPriorView();
    }
  };

  // If we arrive with nothing in flight (e.g. deep-linked to #/processing while
  // idle), don't strand the user on an empty screen — offer a way back.
  const idle = !inFlight;

  const deviceLabel = device.trim();

  return (
    <div className="cc-processing">
      <div className="cc-processing__card" role="status" aria-live="polite">
        <div className="cc-processing__head">
          <span className="cc-processing__title">
            {idle ? "Nothing processing" : "Detecting cells…"}
          </span>
          {activeRun?.label ? (
            <span className="cc-processing__label" title={activeRun.label}>
              {activeRun.label}
            </span>
          ) : null}
        </div>

        {idle ? (
          <IdleBody onBack={returnToPriorView} />
        ) : (
          <>
            {/* ---- progress bar ---- */}
            <div className="cc-processing__progress">
              <div
                className={
                  "cc-processing__bar" +
                  (indeterminate ? " cc-processing__bar--indeterminate" : "")
                }
                role="progressbar"
                aria-valuemin={0}
                aria-valuemax={100}
                aria-valuenow={indeterminate ? undefined : pct}
                aria-label="Batch detection progress"
              >
                <div
                  className="cc-processing__bar-fill"
                  style={indeterminate ? undefined : { width: `${pct}%` }}
                />
              </div>

              <div className="cc-processing__meta">
                <span className="cc-processing__percent">
                  {indeterminate ? "Starting…" : `${pct}%`}
                </span>
                <span className="cc-processing__meta-spacer" />
                {deviceLabel ? (
                  <span
                    className="cc-processing__device"
                    title={`Compute device: ${deviceLabel}`}
                  >
                    <span
                      className="cc-processing__device-dot"
                      aria-hidden="true"
                    />
                    {deviceLabel}
                  </span>
                ) : null}
              </div>
            </div>

            {/* ---- live stderr stage line ---- */}
            <div className="cc-processing__stage">
              <div className="cc-processing__stage-label">
                {stderrActive ? (
                  <span className="cc-processing__live">
                    <span
                      className="cc-processing__live-dot"
                      aria-hidden="true"
                    />
                    Live
                  </span>
                ) : stalled ? (
                  <span className="cc-processing__live cc-processing__live--stalled">
                    <span
                      className="cc-processing__live-dot"
                      aria-hidden="true"
                    />
                    Still working…
                  </span>
                ) : (
                  "Stage"
                )}
              </div>
              <div
                className={
                  "cc-processing__stage-line" +
                  (stageLine ? "" : " cc-processing__stage-line--idle")
                }
              >
                {stageLine || "Waiting for the model…"}
              </div>
            </div>

            {/* ---- actions ---- */}
            <div className="cc-processing__actions">
              <span className="cc-processing__actions-spacer" />
              <button
                type="button"
                className="cc-processing__cancel"
                onClick={handleCancel}
                disabled={cancelling}
              >
                {cancelling ? "Cancelling…" : "Cancel"}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Clamp a 0..1 fraction to an integer 0..100 for display + the bar width. */
function clampPct(fraction: number): number {
  if (!Number.isFinite(fraction)) return 0;
  const p = Math.round(fraction * 100);
  if (p < 0) return 0;
  if (p > 100) return 100;
  return p;
}

/** The idle state body: no run in flight, just a way back. */
function IdleBody({ onBack }: { onBack: () => void }) {
  return (
    <div className="cc-processing__actions">
      <span className="cc-processing__idle-note">
        No detection is currently running.
      </span>
      <span className="cc-processing__actions-spacer" />
      <button type="button" className="cc-btn" onClick={onBack}>
        Back
      </button>
    </div>
  );
}

/**
 * Returns a stable callback that navigates back to the view the user came from.
 *
 * The shell uses a hash router (`useHashRoute`) with no history abstraction of
 * its own, but `history.back()` works with hash navigation. We remember the
 * referring hash captured at mount; if it looks like an in-app route we go back,
 * otherwise we fall back to Home. Cancelling from Processing should feel like
 * "return to the prior view", per the task `output`.
 */
function useReturnToPriorView(): () => void {
  // Capture the hash that was current *before* the user landed on #/processing.
  // `document.referrer` is unreliable for SPA hash nav, so we snapshot the
  // history length + a hint at mount and prefer history.back().
  const cameFromInApp = useRef(false);

  useEffect(() => {
    // If there is prior in-app history, history.back() will return to it.
    // `history.length > 1` is a good-enough signal inside the Tauri webview.
    cameFromInApp.current = window.history.length > 1;
  }, []);

  return useMemo(
    () => () => {
      if (cameFromInApp.current) {
        // Return to whatever route dispatched detection (Home or Results).
        window.history.back();
      } else {
        navigate("home");
      }
    },
    [],
  );
}
