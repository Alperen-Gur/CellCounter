/**
 * kernel/overlay/MaskOverlay.tsx — the read-only mask renderer (§3.5).
 *
 * Ported from the RENDER half of `Views/Results/EditableOverlay.swift`
 * (`cellsLayer` + `annotationsLayer`). Read-only: it draws, it never mutates —
 * all editing lives in the framework-free `MaskEditEngine`.
 *
 * Per cell it draws, in SOURCE-PIXEL space (mapped through the enclosing
 * `ViewportTransformContext`):
 *   - a filled polygon from `contourPx` (bin-color fill at `maskOpacity`,
 *     bin-color outline; dashed stroke when `confidence < confidenceCutoff`),
 *   - else a bbox/ellipse fallback chosen by `overlayMode`,
 *   - manual markers as fixed-radius numbered pins,
 *   - ground-truth points as yellow crosshairs.
 * Selected / merge-staged / split-staged cells get an extra ring.
 *
 * Rendering uses inline SVG so it composes with the Viewport transform and
 * scrolls/zooms with the image. Colors use CSS `oklch()` — the exact
 * perceptual bin ramp ported from `Theme/Tokens.swift` (bin1…bin5).
 */

import { useContext } from "react";

import type { CellDTO, GroundTruthDTO, OverlayMode } from "../types";
import { binIndex } from "../calibration/calibration";
import { ViewportTransformContext } from "../viewport/Viewport";

export interface MaskOverlayProps {
  cells: CellDTO[];
  annotations?: GroundTruthDTO[];
  thresholds: number[]; // for bin coloring
  overlayMode: OverlayMode;
  confidenceCutoff: number; // cells below render dashed/uncertain
  showMaskFills: boolean;
  showOutlines: boolean;
  maskOpacity: number;
  selectedCellIds: ReadonlySet<string>;
  mergeStagedId?: string;
  splitStagedId?: string;
}

// ---------------------------------------------------------------------------
// Bin color ramp — ported from Tokens.swift (5 OKLCH stops, viridis-ish,
// colorblind-safe). Modern webviews render `oklch()` natively.
// ---------------------------------------------------------------------------

const BIN_OKLCH: ReadonlyArray<readonly [number, number, number]> = [
  [0.45, 0.14, 280], // bin1
  [0.58, 0.13, 230], // bin2
  [0.68, 0.11, 180], // bin3
  [0.78, 0.13, 105], // bin4
  [0.82, 0.16, 60], // bin5
];

/** Bin color for index `i`, clamped to the ramp (port of `Tokens.binColor`). */
function binColor(i: number): string {
  const idx = Math.max(0, Math.min(i, BIN_OKLCH.length - 1));
  const [l, c, h] = BIN_OKLCH[idx];
  return `oklch(${l} ${c} ${h})`;
}

/** Fixed pin radius (source-px-independent, in view units) for manual markers. */
const MANUAL_MARKER_RADIUS = 7;
/** Crosshair arm length (view units) for ground-truth annotations. */
const ANNOTATION_ARM = 6;

export function MaskOverlay({
  cells,
  annotations,
  thresholds,
  overlayMode,
  confidenceCutoff,
  showMaskFills,
  showOutlines,
  maskOpacity,
  selectedCellIds,
  mergeStagedId,
  splitStagedId,
}: MaskOverlayProps) {
  const t = useContext(ViewportTransformContext);
  const { viewScale, sourceToView } = t;

  // Manual-marker sequence number (1-based), assigned in draw order.
  let manualSeq = 0;

  const cellNodes: React.ReactNode[] = [];
  for (const c of cells) {
    const center = sourceToView({ x: c.cx, y: c.cy });
    const isManual = c.isManual === true;
    const isSelected = selectedCellIds.has(c.id);
    const isMergeStaged = mergeStagedId === c.id;
    const isSplitStaged = splitStagedId === c.id;
    const isUncertain = c.confidence < confidenceCutoff;

    if (isManual) {
      manualSeq += 1;
      cellNodes.push(
        <g key={c.id}>
          <circle
            cx={center.x}
            cy={center.y}
            r={MANUAL_MARKER_RADIUS}
            fill="var(--cc-accent, #3b82f6)"
            stroke="#ffffff"
            strokeWidth={1.5}
          />
          <text
            x={center.x}
            y={center.y}
            fill="#ffffff"
            fontSize={9}
            fontWeight={700}
            fontFamily="ui-monospace, monospace"
            textAnchor="middle"
            dominantBaseline="central"
          >
            {manualSeq}
          </text>
          {(isSelected || isMergeStaged || isSplitStaged) &&
            selectionRing(c, center, viewScale, overlayMode, isMergeStaged, isSplitStaged)}
        </g>,
      );
      continue;
    }

    const idx = binIndex(c.diameterUm, thresholds);
    const col = binColor(idx);
    const rView = (c.diameterPx * viewScale) / 2;

    if (c.contourPx && c.contourPx.length >= 3) {
      // Filled polygon from the contour, in the bin color.
      const pts = c.contourPx
        .map((p) => {
          const v = sourceToView({ x: p[0], y: p[1] });
          return `${v.x},${v.y}`;
        })
        .join(" ");
      cellNodes.push(
        <g key={c.id}>
          <polygon
            points={pts}
            fill={showMaskFills ? col : "none"}
            fillOpacity={showMaskFills ? maskOpacity : 0}
            stroke={showOutlines ? col : "none"}
            strokeWidth={1}
            strokeDasharray={isUncertain ? "3.5 3" : undefined}
          />
          {(isSelected || isMergeStaged || isSplitStaged) &&
            selectionRing(c, center, viewScale, overlayMode, isMergeStaged, isSplitStaged)}
        </g>,
      );
    } else if (overlayMode === "outline") {
      // Ellipse fallback.
      cellNodes.push(
        <g key={c.id}>
          <circle
            cx={center.x}
            cy={center.y}
            r={rView}
            fill={showMaskFills ? col : "none"}
            fillOpacity={showMaskFills ? Math.max(maskOpacity, 0.18) : 0}
            stroke={showOutlines ? col : "none"}
            strokeWidth={1.5}
            strokeDasharray={isUncertain ? "3.5 3" : undefined}
          />
          {(isSelected || isMergeStaged || isSplitStaged) &&
            selectionRing(c, center, viewScale, overlayMode, isMergeStaged, isSplitStaged)}
        </g>,
      );
    } else {
      // Bounding-box fallback.
      cellNodes.push(
        <g key={c.id}>
          <rect
            x={center.x - rView}
            y={center.y - rView}
            width={rView * 2}
            height={rView * 2}
            rx={2}
            fill={showMaskFills ? col : "none"}
            fillOpacity={showMaskFills ? Math.max(maskOpacity, 0.1) : 0}
            stroke={showOutlines ? col : "none"}
            strokeWidth={1.5}
            strokeDasharray={isUncertain ? "3.5 3" : undefined}
          />
          {(isSelected || isMergeStaged || isSplitStaged) &&
            selectionRing(c, center, viewScale, overlayMode, isMergeStaged, isSplitStaged)}
        </g>,
      );
    }
  }

  const annotationNodes: React.ReactNode[] = (annotations ?? []).map((a) => {
    const v = sourceToView({ x: a.cx, y: a.cy });
    return (
      <g key={a.id}>
        <circle cx={v.x} cy={v.y} r={ANNOTATION_ARM + 1} fill="rgba(0,0,0,0.30)" />
        <line
          x1={v.x - ANNOTATION_ARM}
          y1={v.y}
          x2={v.x + ANNOTATION_ARM}
          y2={v.y}
          stroke="var(--cc-warning, #eab308)"
          strokeWidth={1.8}
          strokeLinecap="round"
        />
        <line
          x1={v.x}
          y1={v.y - ANNOTATION_ARM}
          x2={v.x}
          y2={v.y + ANNOTATION_ARM}
          stroke="var(--cc-warning, #eab308)"
          strokeWidth={1.8}
          strokeLinecap="round"
        />
        <circle cx={v.x} cy={v.y} r={1.25} fill="#ffffff" />
      </g>
    );
  });

  return (
    <svg
      width="100%"
      height="100%"
      style={{
        position: "absolute",
        inset: 0,
        pointerEvents: "none",
        overflow: "visible",
      }}
    >
      {cellNodes}
      {annotationNodes}
    </svg>
  );
}

/** The selection / merge-staged / split-staged ring around a cell. */
function selectionRing(
  c: CellDTO,
  center: { x: number; y: number },
  viewScale: number,
  overlayMode: OverlayMode,
  isMergeStaged: boolean,
  isSplitStaged: boolean,
): React.ReactNode {
  const rView = (c.diameterPx * viewScale) / 2 + 2;
  const color = isMergeStaged
    ? "var(--cc-warning, #eab308)"
    : isSplitStaged
      ? "var(--cc-info, #06b6d4)"
      : "var(--cc-accent, #3b82f6)";
  if (overlayMode === "outline" || (c.contourPx && c.contourPx.length >= 3)) {
    return (
      <circle
        cx={center.x}
        cy={center.y}
        r={rView}
        fill="none"
        stroke={color}
        strokeWidth={2}
      />
    );
  }
  return (
    <rect
      x={center.x - rView}
      y={center.y - rView}
      width={rView * 2}
      height={rView * 2}
      rx={3}
      fill="none"
      stroke={color}
      strokeWidth={2}
    />
  );
}
