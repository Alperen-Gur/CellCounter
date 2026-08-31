import { circleContour, clipPolygonByLine, convexHull, polygonArea } from "./geometry";
import { measureCells } from "./measurements";
import type {
  Calibration,
  CellGeometry,
  CellMeasurement,
  CorrectionRecord,
  SourcePointPx,
  SourcePolygonPx,
} from "./types";

export type CorrectionOperation =
  | {
      readonly id: string;
      readonly appliedAt: string;
      readonly kind: "add";
      readonly centerPx: SourcePointPx;
      readonly diameterUm: number;
      readonly contourPx?: SourcePolygonPx;
    }
  | { readonly id: string; readonly appliedAt: string; readonly kind: "remove"; readonly cellIds: readonly string[] }
  | { readonly id: string; readonly appliedAt: string; readonly kind: "resize"; readonly cellId: string; readonly diameterUm: number }
  | {
      readonly id: string;
      readonly appliedAt: string;
      readonly kind: "merge";
      readonly cellIds: readonly [string, string];
    }
  | {
      readonly id: string;
      readonly appliedAt: string;
      readonly kind: "split";
      readonly cellId: string;
      readonly line: readonly [SourcePointPx, SourcePointPx];
    };

export interface CorrectionState {
  readonly cells: readonly CellMeasurement[];
  readonly log: readonly CorrectionRecord[];
}

export interface CorrectionContext {
  readonly calibration: Calibration;
  readonly imageSize: { readonly widthPx: number; readonly heightPx: number };
  readonly sizeThresholdsUm: readonly number[];
}

function geometry(cell: CellMeasurement): CellGeometry {
  return {
    id: cell.id,
    centroidPx: cell.centroidPx,
    contourPx: cell.contourPx,
    confidence: cell.confidence,
    origin: cell.origin,
  };
}

function requireUniqueOperation(state: CorrectionState, id: string): void {
  if (!id.trim()) throw new TypeError("Correction id cannot be empty");
  if (state.log.some((record) => record.id === id)) throw new Error(`Correction already applied: ${id}`);
}

function requireCell(cells: readonly CellMeasurement[], id: string): CellMeasurement {
  const cell = cells.find((candidate) => candidate.id === id);
  if (!cell) throw new Error(`Cell not found: ${id}`);
  return cell;
}

function asMeasured(cells: readonly CellGeometry[], context: CorrectionContext): CellMeasurement[] {
  return measureCells(cells, context.calibration, context.imageSize, context.sizeThresholdsUm);
}

export function applyCorrection(
  state: CorrectionState,
  operation: CorrectionOperation,
  context: CorrectionContext,
): CorrectionState {
  requireUniqueOperation(state, operation.id);
  let cells = state.cells.map(geometry);
  let removedCellIds: string[] = [];
  let addedCellIds: string[] = [];

  switch (operation.kind) {
    case "add": {
      if (!Number.isFinite(operation.diameterUm) || operation.diameterUm <= 0) {
        throw new RangeError("Manual cell diameter must be positive");
      }
      const id = `${operation.id}:cell`;
      const contourPx = operation.contourPx
        ? operation.contourPx.map((point) => ({ ...point }))
        : circleContour(operation.centerPx, operation.diameterUm * context.calibration.pxPerUm);
      cells.push({ id, centroidPx: operation.centerPx, contourPx, confidence: 1, origin: "manual" });
      addedCellIds = [id];
      break;
    }
    case "remove": {
      const uniqueIds = [...new Set(operation.cellIds)];
      if (uniqueIds.length === 0) throw new RangeError("Remove correction needs at least one cell id");
      for (const id of uniqueIds) requireCell(state.cells, id);
      const idSet = new Set(uniqueIds);
      cells = cells.filter((cell) => !idSet.has(cell.id));
      removedCellIds = uniqueIds;
      break;
    }
    case "resize": {
      if (!Number.isFinite(operation.diameterUm) || operation.diameterUm <= 0) throw new RangeError("Resized cell diameter must be positive");
      const original = requireCell(state.cells, operation.cellId);
      const targetPx = operation.diameterUm * context.calibration.pxPerUm;
      const scale = targetPx / Math.max(Number.EPSILON, original.equivalentDiameterPx);
      cells = cells.map((cell) => cell.id === operation.cellId ? {
        ...cell,
        contourPx: cell.contourPx.map((point) => ({
          x: original.centroidPx.x + (point.x - original.centroidPx.x) * scale,
          y: original.centroidPx.y + (point.y - original.centroidPx.y) * scale,
        })),
      } : cell);
      removedCellIds = [operation.cellId];
      addedCellIds = [operation.cellId];
      break;
    }
    case "merge": {
      const [firstId, secondId] = operation.cellIds;
      if (firstId === secondId) throw new RangeError("Merge correction needs two different cells");
      const first = requireCell(state.cells, firstId);
      const second = requireCell(state.cells, secondId);
      const mergedContour = convexHull([...first.contourPx, ...second.contourPx]);
      if (mergedContour.length < 3 || polygonArea(mergedContour) <= 0) {
        throw new Error("Merged cell contour is degenerate");
      }
      const id = `${operation.id}:cell`;
      const remove = new Set(operation.cellIds);
      cells = cells.filter((cell) => !remove.has(cell.id));
      cells.push({
        id,
        centroidPx: first.centroidPx,
        contourPx: mergedContour,
        confidence: Math.max(first.confidence, second.confidence),
        origin: first.origin === "manual" && second.origin === "manual" ? "manual" : "model",
      });
      removedCellIds = [firstId, secondId];
      addedCellIds = [id];
      break;
    }
    case "split": {
      const original = requireCell(state.cells, operation.cellId);
      const positive = clipPolygonByLine(original.contourPx, operation.line[0], operation.line[1], true);
      const negative = clipPolygonByLine(original.contourPx, operation.line[0], operation.line[1], false);
      if (positive.length < 3 || negative.length < 3 || polygonArea(positive) <= 0 || polygonArea(negative) <= 0) {
        throw new Error("Split line must cross the cell into two non-empty contours");
      }
      const firstId = `${operation.id}:cell-1`;
      const secondId = `${operation.id}:cell-2`;
      cells = cells.filter((cell) => cell.id !== original.id);
      cells.push(
        {
          id: firstId,
          centroidPx: original.centroidPx,
          contourPx: positive,
          confidence: original.confidence,
          origin: original.origin,
        },
        {
          id: secondId,
          centroidPx: original.centroidPx,
          contourPx: negative,
          confidence: original.confidence,
          origin: original.origin,
        },
      );
      removedCellIds = [original.id];
      addedCellIds = [firstId, secondId];
      break;
    }
  }

  const record: CorrectionRecord = Object.freeze({
    id: operation.id,
    appliedAt: operation.appliedAt,
    kind: operation.kind,
    removedCellIds,
    addedCellIds,
  });
  return Object.freeze({ cells: asMeasured(cells, context), log: [...state.log, record] });
}

/** Immutable correction history with bounded undo/redo snapshots. */
export class CorrectionHistory {
  private current: CorrectionState;
  private readonly undoStack: CorrectionState[] = [];
  private readonly redoStack: CorrectionState[] = [];

  constructor(initial: CorrectionState, private readonly limit = 50) {
    this.current = initial;
  }

  get state(): CorrectionState {
    return this.current;
  }

  apply(operation: CorrectionOperation, context: CorrectionContext): CorrectionState {
    this.undoStack.push(this.current);
    if (this.undoStack.length > this.limit) this.undoStack.shift();
    this.redoStack.length = 0;
    this.current = applyCorrection(this.current, operation, context);
    return this.current;
  }

  undo(): CorrectionState {
    const previous = this.undoStack.pop();
    if (!previous) return this.current;
    this.redoStack.push(this.current);
    this.current = previous;
    return this.current;
  }

  redo(): CorrectionState {
    const next = this.redoStack.pop();
    if (!next) return this.current;
    this.undoStack.push(this.current);
    this.current = next;
    return this.current;
  }
}
