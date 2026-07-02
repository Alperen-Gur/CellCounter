/**
 * pages/onboarding/onboardingController.ts — the modal controller + first-run gate
 * for the Onboarding + Calibration feature (feat-calibration-onboarding).
 *
 * The onboarding carousel and the calibration sheet are *modals* the whole app
 * reaches for: Home/Results open the calibration sheet from a toolbar affordance,
 * and the shell auto-launches onboarding on first launch. But this feature owns
 * only `pages/onboarding/` and must not have sibling pages import its internals.
 *
 * So instead of a prop-drilled parent, we expose a tiny event-bus controller:
 *   - `openCalibration()` / `openOnboarding()` fire a request,
 *   - the `OnboardingRoot` mounted by `OnboardingPage` (and, once wired, the
 *     shell) subscribes and renders the matching modal,
 *   - `useOnboardingController()` is the React hook that drives that root.
 *
 * The first-run gate mirrors `AppState.showOnboarding` /
 * `AppState.completeOnboarding` — persisted under the `cc-onboarded`
 * localStorage key (the Swift app used UserDefaults `cc-onboarded`).
 *
 * No sibling-page imports, no kernel-slice mutations here — this module is
 * self-contained routing/glue for the two modals. Persistence + store writes
 * happen inside the modals themselves, through the frozen ports/store.
 */

import { useEffect, useState } from "react";

// ---------------------------------------------------------------------------
// First-run gate (mirror AppState.showOnboarding / completeOnboarding)
// ---------------------------------------------------------------------------

/** localStorage key marking that onboarding has been completed (Swift parity). */
export const ONBOARDED_KEY = "cc-onboarded";

/** True when the user has never completed onboarding (⇒ auto-launch on start). */
export function shouldShowOnboarding(): boolean {
  try {
    return window.localStorage.getItem(ONBOARDED_KEY) !== "true";
  } catch {
    // No localStorage (SSR / locked-down webview) — never block the app on it.
    return false;
  }
}

/** Persist that onboarding is done so it never auto-launches again. */
export function markOnboarded(): void {
  try {
    window.localStorage.setItem(ONBOARDED_KEY, "true");
  } catch {
    /* best-effort — a failed write just means onboarding may show again */
  }
}

/** Clear the completion flag (Settings "show onboarding again" / tests). */
export function resetOnboarded(): void {
  try {
    window.localStorage.removeItem(ONBOARDED_KEY);
  } catch {
    /* ignore */
  }
}

// ---------------------------------------------------------------------------
// Modal request bus
// ---------------------------------------------------------------------------

/** Which onboarding-feature modal (if any) should currently be presented. */
export type ActiveModal = "none" | "onboarding" | "calibration";

/** A calibration-open request, optionally scoped to a specific image. */
export interface CalibrationRequest {
  /** Absolute source path of the currently-open image, for the draw-on-scale-bar
   *  tab. Omitted when opened without an active image (tab degrades gracefully). */
  imagePath?: string;
}

type Listener = (modal: ActiveModal, calib: CalibrationRequest | null) => void;

const listeners = new Set<Listener>();
let current: ActiveModal = "none";
let currentCalib: CalibrationRequest | null = null;

function emit(): void {
  for (const l of listeners) l(current, currentCalib);
}

/** Subscribe to modal-state changes. Returns an unsubscribe fn. */
export function subscribeModal(l: Listener): () => void {
  listeners.add(l);
  // Push the current state immediately so late subscribers are in sync.
  l(current, currentCalib);
  return () => {
    listeners.delete(l);
  };
}

/** Request the onboarding carousel be shown. */
export function openOnboarding(): void {
  current = "onboarding";
  currentCalib = null;
  emit();
}

/** Request the calibration sheet be shown (optionally for a given image). */
export function openCalibration(req: CalibrationRequest = {}): void {
  current = "calibration";
  currentCalib = req;
  emit();
}

/** Dismiss whichever modal is open. */
export function closeModal(): void {
  current = "none";
  currentCalib = null;
  emit();
}

// ---------------------------------------------------------------------------
// React hook driving the root that renders the modals
// ---------------------------------------------------------------------------

export interface OnboardingControllerState {
  modal: ActiveModal;
  calibration: CalibrationRequest | null;
  close(): void;
}

/**
 * Subscribe a component to the modal bus. The mounting root uses this to decide
 * which modal to render. Also seeds the first-run onboarding launch exactly once
 * per session when `autoLaunchOnboarding` is set and the gate says so.
 */
export function useOnboardingController(
  autoLaunchOnboarding = false,
): OnboardingControllerState {
  const [modal, setModal] = useState<ActiveModal>(current);
  const [calibration, setCalibration] = useState<CalibrationRequest | null>(
    currentCalib,
  );

  useEffect(() => {
    return subscribeModal((m, c) => {
      setModal(m);
      setCalibration(c);
    });
  }, []);

  useEffect(() => {
    if (autoLaunchOnboarding && shouldShowOnboarding() && current === "none") {
      openOnboarding();
    }
    // Run once on mount; the gate itself is idempotent.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [autoLaunchOnboarding]);

  return { modal, calibration, close: closeModal };
}
