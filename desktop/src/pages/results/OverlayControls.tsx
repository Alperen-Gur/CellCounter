/**
 * pages/results/OverlayControls.tsx — the floating overlay/zoom controls that
 * sit over the Viewport (top-left cluster in the Swift `ViewerControlsLeft` +
 * the zoom cluster from `ViewerControlsRight`).
 *
 * Drives the store's SessionSlice: overlayMode (outline/bbox), showMaskFills (X),
 * showOutlines (Z), maskOpacity, and zoom. The keyboard equivalents (Space/X/Z,
 * ⌘±/⌘0) are bound by feat-directory-nav-keyboard against the frozen keymap; this
 * cluster is the on-screen affordance for the same store actions.
 */

import { useAppStore } from "../../kernel/store/store";
import { Icon } from "../../components/Icon";

const MIN_ZOOM = 0.4;
const MAX_ZOOM = 4.0;

export interface OverlayControlsProps {
  onFit(): void;
}

export function OverlayControls({ onFit }: OverlayControlsProps) {
  const overlayMode = useAppStore((s) => s.overlayMode);
  const setOverlayMode = useAppStore((s) => s.setOverlayMode);
  const showMaskFills = useAppStore((s) => s.showMaskFills);
  const setShowMaskFills = useAppStore((s) => s.setShowMaskFills);
  const showOutlines = useAppStore((s) => s.showOutlines);
  const setShowOutlines = useAppStore((s) => s.setShowOutlines);
  const maskOpacity = useAppStore((s) => s.maskOpacity);
  const setMaskOpacity = useAppStore((s) => s.setMaskOpacity);
  const zoom = useAppStore((s) => s.zoom);
  const setZoom = useAppStore((s) => s.setZoom);

  const overlayVisible = showMaskFills || showOutlines;
  const toggleOverlay = () => {
    const next = !overlayVisible;
    setShowMaskFills(next);
    setShowOutlines(next);
  };

  const clampZoom = (z: number) => Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, z));

  return (
    <>
      {/* top-left: overlay mode + master eye */}
      <div className="rv-controls rv-controls--tl">
        <div className="rv-seg">
          <button
            type="button"
            className={`rv-seg__btn${overlayMode === "bbox" ? " rv-seg__btn--on" : ""}`}
            onClick={() => setOverlayMode("bbox")}
          >
            Box
          </button>
          <button
            type="button"
            className={`rv-seg__btn${overlayMode === "outline" ? " rv-seg__btn--on" : ""}`}
            onClick={() => setOverlayMode("outline")}
          >
            Outline
          </button>
        </div>
        <button
          type="button"
          className={`rv-ctl-btn rv-ctl-btn--icon${overlayVisible ? " rv-ctl-btn--on" : ""}`}
          title={overlayVisible ? "Hide overlay (Space)" : "Show overlay (Space)"}
          aria-label={overlayVisible ? "Hide overlay" : "Show overlay"}
          aria-pressed={overlayVisible}
          onClick={toggleOverlay}
        >
          <Icon name={overlayVisible ? "eye" : "eyeOff"} size={16} />
        </button>
        <button
          type="button"
          className={`rv-ctl-btn${showMaskFills ? " rv-ctl-btn--on" : ""}`}
          title="Toggle mask fills (X)"
          aria-pressed={showMaskFills}
          onClick={() => setShowMaskFills(!showMaskFills)}
        >
          Fill
        </button>
        <button
          type="button"
          className={`rv-ctl-btn${showOutlines ? " rv-ctl-btn--on" : ""}`}
          title="Toggle outlines (Z)"
          aria-pressed={showOutlines}
          onClick={() => setShowOutlines(!showOutlines)}
        >
          Line
        </button>
        <label className="rv-opacity" title="Mask opacity">
          <span className="rv-opacity__glyph" aria-hidden="true">
            <Icon name="layers" size={14} />
          </span>
          <input
            type="range"
            min={0}
            max={1}
            step={0.05}
            value={maskOpacity}
            onChange={(e) => setMaskOpacity(Number(e.target.value))}
            aria-label="Mask opacity"
          />
        </label>
      </div>

      {/* top-right: zoom cluster */}
      <div className="rv-controls rv-controls--tr">
        <button
          type="button"
          className="rv-ctl-btn rv-ctl-btn--icon"
          title="Zoom out (⌘−)"
          aria-label="Zoom out"
          onClick={() => setZoom(clampZoom(zoom - 0.15))}
        >
          <Icon name="zoomOut" size={16} />
        </button>
        <span className="rv-zoom-pct">{Math.round(zoom * 100)}%</span>
        <button
          type="button"
          className="rv-ctl-btn rv-ctl-btn--icon"
          title="Zoom in (⌘+)"
          aria-label="Zoom in"
          onClick={() => setZoom(clampZoom(zoom + 0.15))}
        >
          <Icon name="zoomIn" size={16} />
        </button>
        <button type="button" className="rv-ctl-btn" title="Fit to view (⌘0)" onClick={onFit}>
          Fit
        </button>
      </div>
    </>
  );
}
