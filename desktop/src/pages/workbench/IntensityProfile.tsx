import { useState } from "react";
import type { AnnotationProfile } from "../../../../shared/workbench/annotationProtocol";

export default function IntensityProfile({ profile, units }: { profile: AnnotationProfile; units: string }) {
  const [selected, setSelected] = useState(0);
  const values = profile.values.filter((value): value is number => value != null);
  if (!profile.values.length) return null;
  const calibrated = profile.positionsUm.length === profile.values.length && profile.positionsUm.every((value) => value != null);
  const positions = calibrated ? profile.positionsUm as number[] : profile.positionsPx;
  const unit = calibrated ? "µm" : "px";
  const low = values.length ? Math.min(...values) : 0;
  const high = values.length ? Math.max(...values) : 1;
  const padding = high === low ? Math.max(1, Math.abs(low)) * .05 : (high - low) * .05;
  const minimum = low - padding, maximum = high + padding;
  const extent = positions.at(-1) || 1;
  const x = (position: number) => 60 + position / extent * 620;
  const y = (value: number) => 190 - (value - minimum) / (maximum - minimum) * 160;
  const index = Math.min(selected, profile.values.length - 1);
  const path = profile.values.map((value, i) => value == null ? "" :
    `${i === 0 || profile.values[i - 1] == null ? "M" : "L"}${x(positions[i])},${y(value)}`).join(" ");
  const format = (value: number | null) => value == null ? "Missing" : value.toLocaleString(undefined, { maximumFractionDigits: 4 });
  return <figure className="workbench-profile">
    <figcaption>Intensity along the annotation · {units.replaceAll("-", " ")}</figcaption>
    <svg viewBox="0 0 720 230" role="img" aria-label="Intensity profile; gaps represent unavailable samples">
      <line x1={60} y1={190} x2={680} y2={190} stroke="currentColor" />
      <line x1={60} y1={30} x2={60} y2={190} stroke="currentColor" />
      <path d={path} fill="none" stroke="#60e2c1" strokeWidth={2} />
      <line x1={x(positions[index])} y1={30} x2={x(positions[index])} y2={190} stroke="#ffcd38" strokeDasharray="4 4" />
      {profile.values[index] != null ? <circle cx={x(positions[index])} cy={y(profile.values[index]!)} r={4} fill="#ffcd38" /> : null}
      <text x={55} y={35} textAnchor="end">{format(maximum)}</text>
      <text x={55} y={190} textAnchor="end">{format(minimum)}</text>
      <text x={60} y={212}>0 {unit}</text>
      <text x={680} y={212} textAnchor="end">{format(positions.at(-1) ?? 0)} {unit}</text>
    </svg>
    <label>Inspect profile sample<input type="range" min={0} max={profile.values.length - 1} step={1} value={index}
      onChange={(event) => setSelected(Number(event.target.value))} /></label>
    <p>Sample {index + 1} of {profile.values.length} · distance {format(positions[index])} {unit}
      {" · "}intensity {format(profile.values[index])} · coordinates ({profile.coordinates[index].map(format).join(", ")})</p>
    <p>Missing samples remain gaps. Values use bilinear interpolation; they are not additional acquired pixels.</p>
  </figure>;
}
