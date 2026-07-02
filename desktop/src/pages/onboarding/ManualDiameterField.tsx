/**
 * pages/onboarding/ManualDiameterField.tsx — the manual-diameter fallback.
 *
 * Port of the Swift `manualMarkerDiameter` control. When an image carries no EXIF
 * calibration, Cellpose still needs a diameter *prior* (µm) to size cells; this
 * control sets `store.manualMarkerDiameterUm`, which the detection params carry
 * as the fixed-diameter prior and which manually-placed markers inherit.
 *
 * Given the current calibration (px/µm), we also show the equivalent pixel
 * diameter so the user can sanity-check against what they see on the image.
 *
 * Kernel used: `store.manualMarkerDiameterUm` / `setManualMarkerDiameterUm`,
 * `store.pxPerUm` (kernel-store). No data access.
 */

import { useEffect, useRef, useState } from "react";

import { useAppStore } from "../../kernel/store/store";

/** Sensible clamp for a cell diameter prior in µm. */
const MIN_UM = 1;
const MAX_UM = 500;

export interface ManualDiameterFieldProps {
  /** Compact single-row layout (used inside the calibration hub). */
  compact?: boolean;
}

export function ManualDiameterField({ compact = false }: ManualDiameterFieldProps) {
  const diameterUm = useAppStore((s) => s.manualMarkerDiameterUm);
  const setDiameterUm = useAppStore((s) => s.setManualMarkerDiameterUm);
  const pxPerUm = useAppStore((s) => s.pxPerUm);

  const [text, setText] = useState<string>(() => String(diameterUm));
  const focusedRef = useRef(false);

  useEffect(() => {
    if (!focusedRef.current) setText(String(diameterUm));
  }, [diameterUm]);

  const diameterPx = pxPerUm > 0 ? diameterUm * pxPerUm : 0;

  const commit = (raw: string) => {
    const parsed = Number(raw);
    if (raw.trim() === "" || !Number.isFinite(parsed)) return;
    const clamped = Math.min(MAX_UM, Math.max(MIN_UM, parsed));
    setDiameterUm(clamped);
  };

  return (
    <div className={"cc-md" + (compact ? " cc-md--compact" : "")}>
      <div className="cc-md__label">
        <span className="cc-md__title">Manual cell diameter</span>
        <span className="cc-md__hint">
          Used as the detection size prior when an image has no scale metadata.
        </span>
      </div>
      <div className="cc-md__control">
        <div className="cc-cal-numbox">
          <input
            className="cc-cal-numbox__input"
            type="text"
            inputMode="decimal"
            aria-label="Manual cell diameter in micrometers"
            value={text}
            onFocus={() => {
              focusedRef.current = true;
            }}
            onBlur={() => {
              focusedRef.current = false;
              commit(text);
              setText(String(useAppStore.getState().manualMarkerDiameterUm));
            }}
            onChange={(e) => {
              setText(e.target.value);
              commit(e.target.value);
            }}
          />
          <span className="cc-cal-numbox__unit">µm</span>
        </div>
        <span className="cc-md__px">
          ≈ {diameterPx > 0 ? Math.round(diameterPx) : "—"} px
        </span>
      </div>
    </div>
  );
}
