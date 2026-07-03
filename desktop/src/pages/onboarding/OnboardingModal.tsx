/**
 * pages/onboarding/OnboardingModal.tsx — the first-run onboarding carousel.
 *
 * Port of `OnboardingSheet` in `CalibrationSheet.swift`. Five steps, each with a
 * hero illustration + title + description, Back/Next navigation, pagination
 * dots, and a "Get started" finish on the last step. Enter advances / finishes;
 * Escape closes (the Swift sheet used `.cancelAction`). Finishing calls
 * `markOnboarded()` so it never auto-launches again.
 *
 * Presentational + local step state only — no data access, no store writes. The
 * text is copied verbatim from the Swift `OnboardingStep.all` ladder, with
 * "Mac" softened to "computer" for the cross-platform build.
 */

import { useCallback, useEffect, useState } from "react";

import { Icon, type IconName } from "../../components/Icon";
import { markOnboarded } from "./onboardingController";

interface Step {
  title: string;
  desc: string;
  icon: IconName;
}

/** Port of `OnboardingStep.all` (Swift). Step 4 de-Mac'd for cross-platform. */
const STEPS: Step[] = [
  {
    icon: "scope",
    title: "Drop an image, get a count",
    desc: "Drag any microscope image onto CellCounter and Cellpose detects your cells in seconds — colored by size bin, counted in the sidebar, broken down in the histogram.",
  },
  {
    icon: "calibrate",
    title: "Calibrate per objective",
    desc: "Tell CellCounter how many pixels equal a micrometer. Draw on a scale bar, pick a saved preset, or let it read the value straight from your image's EXIF metadata.",
  },
  {
    icon: "edit",
    title: "Correct detections, improve your model",
    desc: "Add, remove, or merge cells directly on the image. Build a ground-truth set and get live Precision/Recall/F1 scores against it. Fine-tuning a custom model on your own samples is coming soon.",
  },
  {
    icon: "histogram",
    title: "Bin by size, export for publication",
    desc: "Set your own µm thresholds and cells are colored, counted, and charted by bin. Export a cells CSV, a batch summary CSV, ImageJ ROIs, a provenance record, or a full PDF lab-journal report with a reproducibility stamp.",
  },
  {
    icon: "checkCircle",
    title: "Stays on your computer",
    desc: "No cloud, no accounts, no telemetry. Every image, every measurement, every annotation, and every fine-tuned model lives entirely on this machine.",
  },
];

export interface OnboardingModalProps {
  /** Called when the carousel is dismissed (finish OR close). */
  onClose(): void;
}

export function OnboardingModal({ onClose }: OnboardingModalProps) {
  const [step, setStep] = useState(0);
  const isLast = step === STEPS.length - 1;

  const finish = useCallback(() => {
    markOnboarded();
    onClose();
  }, [onClose]);

  const next = useCallback(() => {
    if (isLast) {
      finish();
    } else {
      setStep((s) => Math.min(STEPS.length - 1, s + 1));
    }
  }, [isLast, finish]);

  const back = useCallback(() => {
    setStep((s) => Math.max(0, s - 1));
  }, []);

  // Enter → Next/Finish, Escape → close (Swift keyboardShortcut parity).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Enter") {
        e.preventDefault();
        next();
      } else if (e.key === "Escape") {
        e.preventDefault();
        // Escaping onboarding still marks it done — matches the Swift close
        // button, which routes through `completeOnboarding()`.
        finish();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [next, finish]);

  const active = STEPS[step];

  return (
    // Backdrop tap does NOT dismiss onboarding (Swift parity).
    <div className="cc-ob-backdrop" role="dialog" aria-modal="true" aria-label="Welcome to CellCounter">
      <div className="cc-ob-sheet">
        <button
          type="button"
          className="cc-ob-close cc-ob-sheet__close"
          onClick={finish}
          aria-label="Close onboarding"
          title="Skip onboarding"
        >
          <Icon name="close" size={16} />
        </button>

        <div className="cc-ob-head">
          <span className="cc-ob-badge" aria-hidden="true">
            <Icon name={active.icon} size={28} strokeWidth={1.6} />
          </span>
        </div>

        <div className="cc-ob-body">
          <h2 className="cc-ob-body__title">{active.title}</h2>
          <p className="cc-ob-body__desc">{active.desc}</p>
        </div>

        <div className="cc-ob-foot">
          <div className="cc-ob-dots" aria-hidden="true">
            {STEPS.map((_, j) => (
              <span
                key={j}
                className={"cc-ob-dot" + (j === step ? " cc-ob-dot--on" : "")}
              />
            ))}
          </div>

          {step > 0 && (
            <button type="button" className="cc-ob-btn" onClick={back}>
              <Icon name="chevronLeft" size={16} />
              Back
            </button>
          )}
          <button
            type="button"
            className="cc-ob-btn cc-ob-btn--primary"
            onClick={next}
          >
            {isLast ? (
              "Get started"
            ) : (
              <>
                Next
                <Icon name="chevronRight" size={16} />
              </>
            )}
          </button>
        </div>
      </div>
    </div>
  );
}
