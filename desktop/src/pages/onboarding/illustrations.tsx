/**
 * pages/onboarding/illustrations.tsx — SVG hero illustrations for the onboarding
 * carousel (port of the Swift `Illu*` Canvas views in `CalibrationSheet.swift`).
 *
 * One illustration per onboarding step, drawn with inline SVG so they need no
 * asset pipeline and inherit the shell's design tokens (bin colors, accent,
 * text). Purely presentational — no state, no data access.
 */

import type { JSX } from "react";

/** Size-bin palette (shell tokens), cycled for bins beyond the first three. */
const BIN_COLORS = [
  "var(--cc-bin-small)",
  "var(--cc-bin-mid)",
  "var(--cc-bin-large)",
  "var(--cc-accent)",
  "var(--cc-warning)",
];

function binColor(i: number): string {
  return BIN_COLORS[i % BIN_COLORS.length];
}

// ---------------------------------------------------------------------------
// Step 0 — scattered cells colored by size bin (port of IlluCells)
// ---------------------------------------------------------------------------

function IlluCells(): JSX.Element {
  // Deterministic scatter so the illustration is stable (Swift used a seeded RNG).
  const cells: Array<[number, number, number]> = [
    [0.14, 0.32, 15],
    [0.27, 0.62, 11],
    [0.4, 0.28, 19],
    [0.52, 0.55, 13],
    [0.63, 0.34, 16],
    [0.75, 0.6, 10],
    [0.86, 0.4, 18],
    [0.34, 0.78, 12],
    [0.6, 0.78, 14],
    [0.2, 0.46, 9],
    [0.47, 0.4, 17],
    [0.7, 0.46, 12],
  ];
  return (
    <svg viewBox="0 0 400 180" width="100%" height="100%" aria-hidden="true">
      {cells.map(([x, y, d], i) => {
        const cx = x * 400;
        const cy = y * 180;
        const r = d / 2;
        const c = binColor(i % 5);
        return (
          <circle
            key={i}
            cx={cx}
            cy={cy}
            r={r}
            fill={c}
            fillOpacity={0.15}
            stroke={c}
            strokeWidth={1.5}
          />
        );
      })}
    </svg>
  );
}

// ---------------------------------------------------------------------------
// Step 1 — ruler with accent scale bar (port of IlluCalibrate)
// ---------------------------------------------------------------------------

function IlluCalibrate(): JSX.Element {
  const x0 = 50;
  const x1 = 350;
  const midY = 70;
  const tickCount = 11;
  const ticks = [];
  for (let t = 0; t < tickCount; t++) {
    const tx = x0 + (t * (x1 - x0)) / (tickCount - 1);
    const isMid = t === Math.floor(tickCount / 2);
    ticks.push(
      <line
        key={t}
        x1={tx}
        y1={midY - (isMid ? 14 : 8)}
        x2={tx}
        y2={midY}
        stroke="var(--cc-text-secondary)"
        strokeOpacity={0.7}
        strokeWidth={isMid ? 1.5 : 1}
      />,
    );
  }
  const barX1 = x0 + (x1 - x0) * 0.42;
  return (
    <svg viewBox="0 0 400 140" width="100%" height="100%" aria-hidden="true">
      <line
        x1={x0}
        y1={midY}
        x2={x1}
        y2={midY}
        stroke="var(--cc-text-secondary)"
        strokeOpacity={0.7}
        strokeWidth={1.5}
      />
      {ticks}
      <rect
        x={x0}
        y={midY + 20}
        width={barX1 - x0}
        height={6}
        rx={2}
        fill="var(--cc-accent)"
      />
      <text
        x={(x0 + barX1) / 2}
        y={midY + 44}
        textAnchor="middle"
        fontSize={11}
        fontFamily="var(--cc-font-mono)"
        fill="var(--cc-accent)"
      >
        100 µm = 520 px
      </text>
    </svg>
  );
}

// ---------------------------------------------------------------------------
// Step 2 — ascending size-bin bars (port of IlluBins)
// ---------------------------------------------------------------------------

function IlluBins(): JSX.Element {
  const barCount = 5;
  const barW = 36;
  const spacing = 60;
  const baseY = 130;
  const totalW = (barCount - 1) * spacing + barW;
  const startX = (400 - totalW) / 2;
  const bars = [];
  for (let i = 0; i < barCount; i++) {
    const barH = 18 + i * 18;
    const x = startX + i * spacing;
    bars.push(
      <rect
        key={i}
        x={x}
        y={baseY - barH}
        width={barW}
        height={barH}
        rx={3}
        fill={binColor(i)}
      />,
    );
  }
  return (
    <svg viewBox="0 0 400 170" width="100%" height="100%" aria-hidden="true">
      {bars}
      <line
        x1={startX - 4}
        y1={baseY}
        x2={startX + totalW + 8}
        y2={baseY}
        stroke="var(--cc-text-secondary)"
        strokeOpacity={0.6}
        strokeWidth={1}
      />
      <text
        x={200}
        y={baseY + 22}
        textAnchor="middle"
        fontSize={10.5}
        fontFamily="var(--cc-font-mono)"
        fill="var(--cc-text-tertiary)"
      >
        cell diameter →
      </text>
    </svg>
  );
}

// ---------------------------------------------------------------------------
// Step 3 — training loss curves (port of IlluTrain)
// ---------------------------------------------------------------------------

function IlluTrain(): JSX.Element {
  const x0 = 40;
  const y0 = 24;
  const x1 = 360;
  const y1 = 130;
  return (
    <svg viewBox="0 0 400 160" width="100%" height="100%" aria-hidden="true">
      <polyline
        points={`${x0},${y0} ${x0},${y1} ${x1},${y1}`}
        fill="none"
        stroke="var(--cc-text-secondary)"
        strokeOpacity={0.5}
        strokeWidth={0.8}
      />
      <path
        d={`M ${x0} ${y0 + 6} C ${x0 + (x1 - x0) * 0.35} ${y0 + 30}, ${
          x0 + (x1 - x0) * 0.65
        } ${y1 - 24}, ${x1} ${y1 - 8}`}
        fill="none"
        stroke="var(--cc-accent)"
        strokeWidth={2}
        strokeLinecap="round"
      />
      <path
        d={`M ${x0} ${y0 + 14} C ${x0 + (x1 - x0) * 0.35} ${y0 + 44}, ${
          x0 + (x1 - x0) * 0.65
        } ${y1 - 18}, ${x1} ${y1 - 4}`}
        fill="none"
        stroke="var(--cc-bin-large)"
        strokeWidth={2}
        strokeLinecap="round"
        strokeDasharray="4 4"
      />
      <text
        x={x0 - 6}
        y={y0}
        textAnchor="end"
        fontSize={10}
        fontFamily="var(--cc-font-mono)"
        fill="var(--cc-text-tertiary)"
      >
        loss
      </text>
    </svg>
  );
}

// ---------------------------------------------------------------------------
// Step 4 — window outline + bars + check (port of IlluLocal)
// ---------------------------------------------------------------------------

function IlluLocal(): JSX.Element {
  const winX = 80;
  const winY = 16;
  const winW = 240;
  const winH = 108;
  const barOffsets = [0.28, 0.42, 0.56];
  const barWidths = [0.72, 0.54, 0.63];
  const cx = 200;
  const cy = winY + winH + 20;
  const cr = 14;
  return (
    <svg viewBox="0 0 400 170" width="100%" height="100%" aria-hidden="true">
      <rect
        x={winX}
        y={winY}
        width={winW}
        height={winH}
        rx={10}
        fill="none"
        stroke="var(--cc-text-secondary)"
        strokeOpacity={0.6}
        strokeWidth={1.5}
      />
      {barOffsets.map((offY, j) => (
        <rect
          key={j}
          x={winX + winW * 0.1}
          y={winY + winH * offY}
          width={winW * barWidths[j]}
          height={6}
          rx={3}
          fill="var(--cc-accent)"
          fillOpacity={0.4}
        />
      ))}
      <circle cx={cx} cy={cy} r={cr} fill="var(--cc-accent-soft)" />
      <polyline
        points={`${cx - 5.5},${cy} ${cx - 1.5},${cy + 4} ${cx + 6},${cy - 5}`}
        fill="none"
        stroke="var(--cc-accent)"
        strokeWidth={2}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/** Render the illustration for a given onboarding step index. */
export function StepIllustration({ step }: { step: number }): JSX.Element {
  switch (step) {
    case 0:
      return <IlluCells />;
    case 1:
      return <IlluCalibrate />;
    case 2:
      return <IlluBins />;
    case 3:
      return <IlluTrain />;
    case 4:
      return <IlluLocal />;
    default:
      return <IlluCells />;
  }
}
