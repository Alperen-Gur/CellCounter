/**
 * pages/onboarding/OnboardingPage.tsx — the Onboarding & Calibration hub
 * (feat-calibration-onboarding).
 *
 * This route is the home of the two onboarding-feature modals. It:
 *   - mounts `OnboardingRoot` with `autoLaunchOnboarding`, so the onboarding
 *     carousel auto-opens on first launch (mirrors `AppState.showOnboarding`),
 *   - shows the current calibration (px/µm + `objectiveLabel`) with a button to
 *     open the calibration sheet (scoped to the current image so its
 *     draw-on-scale-bar tab has something to draw on),
 *   - hosts the manual-diameter fallback control,
 *   - offers a "Replay onboarding" affordance.
 *
 * Any other page can trigger these modals by importing the controller's
 * `openCalibration()` / `openOnboarding()` — no sibling-page imports needed. This
 * page owns only `pages/onboarding/`; the EXIF auto-apply lives in the Rust
 * importer (kernel-persistence), not here.
 *
 * Kernel used: `objectiveLabel` (kernel-calibration), the store (kernel-store),
 * `PersistencePort` batch/image reads (kernel-persistence).
 */

import { useCallback, useEffect, useState } from "react";

import { objectiveLabel } from "../../kernel/calibration/calibration";
import { getPort } from "../../kernel/persistence";
import { useAppStore } from "../../kernel/store/store";
import type { ImageDTO } from "../../kernel/types";

import { ManualDiameterField } from "./ManualDiameterField";
import { openCalibration, openOnboarding } from "./onboardingController";

import "./onboarding.css";

/**
 * Resolve the source path of the currently-open image, if any, so the
 * calibration sheet's "Draw on scale bar" tab can render it. Reads the current
 * batch's images through the frozen port (same resolution `useResultsData`
 * uses); returns undefined when nothing is open.
 */
function useCurrentImagePath(): string | undefined {
  const currentBatchId = useAppStore((s) => s.currentBatchId);
  const currentImageIdx = useAppStore((s) => s.currentImageIdx);
  const [images, setImages] = useState<ImageDTO[]>([]);

  useEffect(() => {
    let alive = true;
    if (!currentBatchId) {
      setImages([]);
      return () => {
        alive = false;
      };
    }
    void (async () => {
      try {
        const port = getPort();
        const batch = await port.batch(currentBatchId);
        if (!batch) {
          if (alive) setImages([]);
          return;
        }
        const all = await port.allImages();
        const byId = new Map(all.map((im) => [im.id, im]));
        const ordered = batch.imageIds
          .map((id) => byId.get(id))
          .filter((im): im is ImageDTO => im !== undefined);
        if (alive) setImages(ordered);
      } catch {
        if (alive) setImages([]);
      }
    })();
    return () => {
      alive = false;
    };
  }, [currentBatchId]);

  if (images.length === 0) return undefined;
  const idx = Math.min(Math.max(0, currentImageIdx), images.length - 1);
  return images[idx]?.storedPath || undefined;
}

export default function OnboardingPage() {
  const pxPerUm = useAppStore((s) => s.pxPerUm);
  const calibrationNote = useAppStore((s) => s.lastCalibrationNote);
  const imagePath = useCurrentImagePath();

  const onCalibrate = useCallback(() => {
    openCalibration(imagePath ? { imagePath } : {});
  }, [imagePath]);

  return (
    <div className="cc-ob-page">
      <header className="cc-ob-page__head">
        <h1 className="cc-ob-page__title">Calibration &amp; onboarding</h1>
        <p className="cc-ob-page__sub">
          Set your scale so cell sizes are correct, tune the manual diameter
          used when an image has no metadata, and revisit the intro tour any
          time.
        </p>
      </header>

      <section className="cc-ob-card" aria-label="Scale calibration">
        <div className="cc-ob-card__row">
          <div className="cc-ob-card__text">
            <div className="cc-ob-card__label">Current scale</div>
            <div className="cc-ob-card__value">
              <span className="cc-ob-card__num">{pxPerUm.toFixed(2)}</span>
              <span className="cc-ob-card__unit">px / µm</span>
              <span className="cc-ob-card__obj">{objectiveLabel(pxPerUm)}</span>
            </div>
            {calibrationNote && (
              <div className="cc-ob-card__note">{calibrationNote}</div>
            )}
          </div>
          <button
            type="button"
            className="cc-cal-btn cc-cal-btn--primary"
            onClick={onCalibrate}
          >
            Calibrate scale…
          </button>
        </div>
        {!imagePath && (
          <p className="cc-ob-card__foot">
            Tip: open an image first to use the “Draw on scale bar” tab against
            your real image.
          </p>
        )}
      </section>

      <section className="cc-ob-card" aria-label="Manual cell diameter">
        <ManualDiameterField />
      </section>

      <section className="cc-ob-card cc-ob-card--tour" aria-label="Product tour">
        <div className="cc-ob-card__text">
          <div className="cc-ob-card__label">Product tour</div>
          <div className="cc-ob-card__note">
            A quick five-step walkthrough of detecting, calibrating, correcting,
            and exporting.
          </div>
        </div>
        <button type="button" className="cc-cal-btn" onClick={openOnboarding}>
          Replay onboarding
        </button>
      </section>

      {/* No OnboardingRoot here: the app shell (App.tsx) mounts a single global
          OnboardingRoot (with autoLaunchOnboarding) that serves every route,
          including this one. Mounting a second host would render the modals
          twice while on /onboarding. This page just triggers the modals via the
          controller (openCalibration/openOnboarding). */}
    </div>
  );
}
