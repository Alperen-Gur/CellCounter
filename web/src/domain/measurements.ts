import { convexHull, polygonArea, polygonBounds, polygonCentroid, polygonPerimeter } from "./geometry";
import {
  assertCalibration,
  assertSourcePoint,
  type Calibration,
  type CellGeometry,
  type CellMeasurement,
} from "./types";

function round(value: number): number {
  return Object.is(value, -0) ? 0 : Number(value.toFixed(10));
}

export function measureCell(
  cell: CellGeometry,
  calibration: Calibration,
  imageSize: { widthPx: number; heightPx: number },
  sizeThresholdsUm: readonly number[] = [],
): CellMeasurement {
  assertCalibration(calibration);
  if (cell.contourPx.length < 3) throw new RangeError(`Cell ${cell.id} contour needs at least three points`);
  for (const point of cell.contourPx) assertSourcePoint(point);
  if (!Number.isFinite(cell.confidence) || cell.confidence < 0 || cell.confidence > 1) {
    throw new RangeError(`Cell ${cell.id} confidence must be between zero and one`);
  }

  const areaPx2 = polygonArea(cell.contourPx);
  if (areaPx2 <= 0) throw new RangeError(`Cell ${cell.id} contour must enclose an area`);
  const perimeterPx = polygonPerimeter(cell.contourPx);
  const centroidPx = polygonCentroid(cell.contourPx);
  const bboxPx = polygonBounds(cell.contourPx);
  const hullArea = polygonArea(convexHull(cell.contourPx));
  const equivalentDiameterPx = 2 * Math.sqrt(areaPx2 / Math.PI);
  const pxPerUm = calibration.pxPerUm;
  const width = Math.max(bboxPx.width, Number.EPSILON);
  const height = Math.max(bboxPx.height, Number.EPSILON);
  const major = Math.max(width, height);
  const minor = Math.min(width, height);
  const sortedThresholds = [...sizeThresholdsUm].filter(Number.isFinite).sort((a, b) => a - b);
  const equivalentDiameterUm = equivalentDiameterPx / pxPerUm;
  const binIndex = sortedThresholds.findIndex((threshold) => equivalentDiameterUm < threshold);
  const finalBin = binIndex < 0 ? sortedThresholds.length : binIndex;
  const edgeTouching =
    bboxPx.x <= 0 ||
    bboxPx.y <= 0 ||
    bboxPx.x + bboxPx.width >= imageSize.widthPx ||
    bboxPx.y + bboxPx.height >= imageSize.heightPx;

  return Object.freeze({
    ...cell,
    centroidPx: { x: round(centroidPx.x), y: round(centroidPx.y) },
    contourPx: cell.contourPx.map((point) => ({ x: round(point.x), y: round(point.y) })),
    bboxPx: {
      x: round(bboxPx.x),
      y: round(bboxPx.y),
      width: round(bboxPx.width),
      height: round(bboxPx.height),
    },
    areaPx2: round(areaPx2),
    areaUm2: round(areaPx2 / (pxPerUm * pxPerUm)),
    perimeterPx: round(perimeterPx),
    perimeterUm: round(perimeterPx / pxPerUm),
    equivalentDiameterPx: round(equivalentDiameterPx),
    equivalentDiameterUm: round(equivalentDiameterUm),
    circularity: round(Math.min(1, (4 * Math.PI * areaPx2) / (perimeterPx * perimeterPx))),
    eccentricity: round(Math.sqrt(Math.max(0, 1 - (minor * minor) / (major * major)))),
    aspectRatio: round(major / minor),
    solidity: round(hullArea > 0 ? Math.min(1, areaPx2 / hullArea) : 0),
    centroidUm: { x: round(centroidPx.x / pxPerUm), y: round(centroidPx.y / pxPerUm) },
    edgeTouching,
    sizeClass: `bin-${finalBin + 1}`,
  });
}

export function measureCells(
  cells: readonly CellGeometry[],
  calibration: Calibration,
  imageSize: { widthPx: number; heightPx: number },
  sizeThresholdsUm: readonly number[] = [],
): CellMeasurement[] {
  const seen = new Set<string>();
  return cells.map((cell) => {
    if (seen.has(cell.id)) throw new Error(`Duplicate cell id: ${cell.id}`);
    seen.add(cell.id);
    return measureCell(cell, calibration, imageSize, sizeThresholdsUm);
  });
}
