/**
 * pages/results/QCBadges.tsx — per-image focus + illumination quality pills.
 *
 * Port of `Views/Results/QCBadges.swift`. Reads the flat `imageStats`
 * (`focus_score`, `illumination_residual`) the Python sidecar emits. Renders
 * nothing when stats is absent (legacy detections). Traffic-light thresholds
 * are copied verbatim from the Swift source:
 *
 *   Focus (higher = sharper):        ≥0.5 green · 0.2–0.5 amber · <0.2 red
 *   Illum residual (lower = flatter): <0.1 green · 0.1–0.2 amber · >0.2 red
 */

export interface QCBadgesProps {
  stats?: Record<string, number>;
}

function focusColor(v: number): string {
  if (v >= 0.5) return "var(--cc-success)";
  if (v >= 0.2) return "var(--cc-warning)";
  return "var(--cc-danger)";
}

function illuminationColor(v: number): string {
  if (v < 0.1) return "var(--cc-success)";
  if (v < 0.2) return "var(--cc-warning)";
  return "var(--cc-danger)";
}

function Badge({ label, value, color }: { label: string; value: number; color: string }) {
  return (
    <span className="rv-qc-badge">
      <span className="rv-qc-badge__dot" style={{ background: color }} />
      <span className="rv-qc-badge__text">
        {label}: {value.toFixed(2)}
      </span>
    </span>
  );
}

export function QCBadges({ stats }: QCBadgesProps) {
  if (!stats) return null;
  const focus = stats["focus_score"];
  if (focus === undefined) return null;
  const illum = stats["illumination_residual"];
  return (
    <div className="rv-qc">
      <Badge label="Focus" value={focus} color={focusColor(focus)} />
      {illum !== undefined && (
        <Badge label="Illum residual" value={illum} color={illuminationColor(illum)} />
      )}
    </div>
  );
}
