/**
 * pages/onboarding/OnboardingRoot.tsx — the modal host.
 *
 * Subscribes to the `onboardingController` bus and renders whichever modal is
 * currently requested (onboarding carousel or calibration sheet). Mounting this
 * once — the `OnboardingPage` route mounts it, and the shell can too — is enough
 * for any page to pop these modals via `openCalibration()` / `openOnboarding()`
 * without importing this feature's internals.
 *
 * `autoLaunchOnboarding` seeds the first-run onboarding launch (mirrors
 * `AppState.showOnboarding` at init). Pass it `true` from exactly one mount so
 * onboarding doesn't double-open.
 */

import { CalibrationModal } from "./CalibrationModal";
import { OnboardingModal } from "./OnboardingModal";
import { useOnboardingController } from "./onboardingController";

export interface OnboardingRootProps {
  /** When true, auto-open onboarding once if it has never been completed. */
  autoLaunchOnboarding?: boolean;
}

export function OnboardingRoot({
  autoLaunchOnboarding = false,
}: OnboardingRootProps) {
  const { modal, calibration, close } = useOnboardingController(
    autoLaunchOnboarding,
  );

  if (modal === "onboarding") {
    return <OnboardingModal onClose={close} />;
  }
  if (modal === "calibration") {
    return (
      <CalibrationModal imagePath={calibration?.imagePath} onClose={close} />
    );
  }
  return null;
}
