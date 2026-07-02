/**
 * kernel/overlay/MaskEditEngine.ts — the PURE mask-editing state machine (§3.5).
 *
 * Ported from the mutating half of `Views/Results/EditableOverlay.swift`
 * (modes, `EditEvent`, 50-deep undo/redo, merge geometry, bulk-delete). NO
 * React, NO canvas, NO platform deps — so it is unit-testable and reused
 * verbatim by the future WebGPU browser build.
 *
 * All geometry is SOURCE-PIXEL. The `split` op — which the Swift app backed with
 * watershed re-detection — is elevated here to a first-class geometric edit:
 * it cuts one mask into two along a user stroke.
 *
 * FROZEN CONTRACT (§6.5): the public API + the `EditEvent` union.
 *
 * Numeric notes (kept faithful to the Swift host):
 *   - merge center = midpoint; merged diameter d = √(dₐ² + d_b²)/√2 (per §3.5,
 *     which OVERRIDES the Swift simple-average), applied to both µm and px;
 *     merged confidence = max(a, b).
 *   - manual add: fixed manualMarkerDiameterUm, isManual = true, confidence 1.
 *   - contour add: equivalent-circle diameter from the shoelace polygon area.
 *   - resize: newDiameterUm = newDiameterPx / pxPerUm (px is authoritative).
 *   - hit-test: reverse order (latest-drawn wins); point-in-polygon when a
 *     contour is present, else bounding-box containment (diameterPx/2).
 */

import type { CellDTO } from "../types";

// ---------------------------------------------------------------------------
// Geometry value types (local — the engine is framework-free)
// ---------------------------------------------------------------------------

export type Pt = { x: number; y: number };
export type Rect = { x: number; y: number; width: number; height: number };

// ---------------------------------------------------------------------------
// EditEvent union (§3.5)
// ---------------------------------------------------------------------------

export type EditEvent =
  | { kind: "added"; cell: CellDTO }
  | { kind: "removed"; cells: CellDTO[] } // supports bulk-delete-by-rect
  | { kind: "merged"; removed: CellDTO[]; added: CellDTO }
  | { kind: "split"; removed: CellDTO; added: [CellDTO, CellDTO] }
  | { kind: "resized"; cell: CellDTO; oldDiameterUm: number };

export interface EditContext {
  pxPerUm: number;
  manualMarkerDiameterUm: number;
}

// ---------------------------------------------------------------------------
// Small geometry helpers (ported from EditableOverlay private fns)
// ---------------------------------------------------------------------------

/** UUID for a newly-created cell. Uses crypto when available. */
function newCellId(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  return `cell-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

/** Ray-casting point-in-polygon (source-px). Port of `pointInPolygon`. */
export function pointInPolygon(p: Pt, polygon: Array<[number, number]>): boolean {
  if (polygon.length < 3) return false;
  let inside = false;
  let j = polygon.length - 1;
  for (let i = 0; i < polygon.length; i++) {
    const [pix, piy] = polygon[i];
    const [pjx, pjy] = polygon[j];
    if (piy > p.y !== pjy > p.y) {
      const denom = pjy - piy;
      if (denom !== 0) {
        const xIntersect = ((pjx - pix) * (p.y - piy)) / denom + pix;
        if (p.x < xIntersect) inside = !inside;
      }
    }
    j = i;
  }
  return inside;
}

/** Shoelace polygon area (signed). Port of `polygonAreaShoelace`. */
function polygonAreaShoelace(pts: Array<[number, number]>): number {
  if (pts.length < 3) return 0;
  let sum = 0;
  for (let i = 0; i < pts.length; i++) {
    const j = (i + 1) % pts.length;
    sum += pts[i][0] * pts[j][1] - pts[j][0] * pts[i][1];
  }
  return sum / 2.0;
}

/** Bounding box of a cell in source-px (centered on cx,cy, side = diameterPx). */
function bboxOf(c: CellDTO): Rect {
  const r = c.diameterPx / 2;
  return { x: c.cx - r, y: c.cy - r, width: c.diameterPx, height: c.diameterPx };
}

function rectContainsPoint(r: Rect, p: Pt): boolean {
  return (
    p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height
  );
}

/** Normalize a rect so width/height are non-negative. */
function normalizeRect(r: Rect): Rect {
  const x = r.width < 0 ? r.x + r.width : r.x;
  const y = r.height < 0 ? r.y + r.height : r.y;
  return { x, y, width: Math.abs(r.width), height: Math.abs(r.height) };
}

// ---------------------------------------------------------------------------
// MaskEditEngine
// ---------------------------------------------------------------------------

/** Max depth of the undo / redo stacks (Bug #6: capped at 50). */
const UNDO_LIMIT = 50;

export class MaskEditEngine {
  private _cells: CellDTO[];
  private ctx: EditContext;
  private undoStack: EditEvent[] = [];
  private redoStack: EditEvent[] = [];
  private listeners = new Set<(e: EditEvent, cells: CellDTO[]) => void>();

  constructor(initial: CellDTO[], ctx: EditContext) {
    // Defensive copy — callers must not mutate our array out from under us.
    this._cells = initial.map((c) => ({ ...c }));
    this.ctx = ctx;
  }

  /** Current cells (a fresh shallow copy so callers can't mutate internal state). */
  get cells(): CellDTO[] {
    return this._cells.map((c) => ({ ...c }));
  }

  get canUndo(): boolean {
    return this.undoStack.length > 0;
  }
  get canRedo(): boolean {
    return this.redoStack.length > 0;
  }

  /** Update the edit context (e.g. after the calibration / marker size changes). */
  setContext(ctx: EditContext): void {
    this.ctx = ctx;
  }

  // ── queries ────────────────────────────────────────────────────────────

  /**
   * Hit-test a source-px point. Iterates in REVERSE (latest-drawn wins on
   * overlap). Uses point-in-polygon when a contour is present, else
   * bounding-box containment. Returns a copy of the hit cell, or undefined.
   */
  hitTest(pt: Pt): CellDTO | undefined {
    for (let i = this._cells.length - 1; i >= 0; i--) {
      const c = this._cells[i];
      if (c.contourPx && c.contourPx.length >= 3) {
        if (pointInPolygon(pt, c.contourPx)) return { ...c };
      } else {
        if (rectContainsPoint(bboxOf(c), pt)) return { ...c };
      }
    }
    return undefined;
  }

  /** Cells whose centroid lies inside `rect` (bulk-delete / lasso semantics). */
  cellsInRect(rect: Rect): CellDTO[] {
    const r = normalizeRect(rect);
    return this._cells
      .filter((c) => rectContainsPoint(r, { x: c.cx, y: c.cy }))
      .map((c) => ({ ...c }));
  }

  /** Cells whose centroid lies inside the closed freeform `path`. */
  cellsInPath(path: Pt[]): CellDTO[] {
    if (path.length < 3) return [];
    const poly: Array<[number, number]> = path.map((p) => [p.x, p.y]);
    return this._cells
      .filter((c) => pointInPolygon({ x: c.cx, y: c.cy }, poly))
      .map((c) => ({ ...c }));
  }

  // ── mutations (each returns the committed EditEvent) ────────────────────

  /**
   * Add a manual marker at a source-px point. Fixed `manualMarkerDiameterUm`,
   * `isManual = true`, confidence 1.0 (port of `.manualCount` add).
   */
  addAt(pt: Pt): EditEvent {
    const diamUm = this.ctx.manualMarkerDiameterUm;
    const diamPx = diamUm * Math.max(this.ctx.pxPerUm, 0.001);
    const cell: CellDTO = {
      id: newCellId(),
      cx: pt.x,
      cy: pt.y,
      diameterUm: diamUm,
      diameterPx: diamPx,
      confidence: 1.0,
      isManual: true,
    };
    this._cells.push(cell);
    const event: EditEvent = { kind: "added", cell };
    this.commit(event);
    return event;
  }

  /**
   * Add a freeform-drawn mask from a source-px path (right-drag). Computes the
   * equivalent-circle diameter from the polygon's shoelace area and stores the
   * closed polygon as `contourPx` (port of `endFreeform`).
   */
  addFromContour(path: Pt[]): EditEvent {
    // Close the polygon if the endpoint isn't the start.
    const poly: Array<[number, number]> = path.map((p) => [p.x, p.y]);
    if (poly.length >= 1) {
      const first = poly[0];
      const last = poly[poly.length - 1];
      if (first[0] !== last[0] || first[1] !== last[1]) {
        poly.push([first[0], first[1]]);
      }
    }

    // Bounding box + centroid from the bbox (matches the Swift host).
    let minX = poly[0][0];
    let maxX = poly[0][0];
    let minY = poly[0][1];
    let maxY = poly[0][1];
    for (const [x, y] of poly) {
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    const w = maxX - minX;
    const h = maxY - minY;
    const cx = (minX + maxX) / 2;
    const cy = (minY + maxY) / 2;

    // Equivalent-circle diameter from area, else the bbox longest side.
    const area = Math.abs(polygonAreaShoelace(poly));
    const equivDiameterPx = area > 1 ? 2.0 * Math.sqrt(area / Math.PI) : Math.max(w, h);
    const diameterUm =
      this.ctx.pxPerUm > 0 ? equivDiameterPx / this.ctx.pxPerUm : equivDiameterPx;

    const cell: CellDTO = {
      id: newCellId(),
      cx,
      cy,
      diameterUm,
      diameterPx: equivDiameterPx,
      confidence: 1.0,
      contourPx: poly,
    };
    this._cells.push(cell);
    const event: EditEvent = { kind: "added", cell };
    this.commit(event);
    return event;
  }

  /**
   * Remove one or many cells by id (single or bulk). Emits ONE `removed` event
   * carrying every removed cell (bulk-delete-by-rect maps to a single event so
   * undo restores the whole set in one step).
   */
  remove(ids: string[]): EditEvent {
    const idSet = new Set(ids);
    const removed: CellDTO[] = [];
    this._cells = this._cells.filter((c) => {
      if (idSet.has(c.id)) {
        removed.push({ ...c });
        return false;
      }
      return true;
    });
    const event: EditEvent = { kind: "removed", cells: removed };
    this.commit(event);
    return event;
  }

  /**
   * Merge two cells into one. Center = midpoint; merged diameter
   * d = √(dₐ² + d_b²)/√2 for both µm and px (§3.5 override of the Swift
   * simple-average); confidence = max. Order in the array: originals removed,
   * merged appended.
   */
  merge(aId: string, bId: string): EditEvent {
    const a = this._cells.find((c) => c.id === aId);
    const b = this._cells.find((c) => c.id === bId);
    if (!a || !b || aId === bId) {
      // Nothing to merge — emit an empty removed event so callers still get a
      // (no-op) commit rather than a thrown error. Keeps the API total.
      const noop: EditEvent = { kind: "removed", cells: [] };
      this.commit(noop);
      return noop;
    }
    const cx = (a.cx + b.cx) / 2;
    const cy = (a.cy + b.cy) / 2;
    const diamUm = combinedDiameter(a.diameterUm, b.diameterUm);
    const diamPx = combinedDiameter(a.diameterPx, b.diameterPx);
    const merged: CellDTO = {
      id: newCellId(),
      cx,
      cy,
      diameterUm: diamUm,
      diameterPx: diamPx,
      confidence: Math.max(a.confidence, b.confidence),
    };
    const removed = [{ ...a }, { ...b }];
    this._cells = this._cells.filter((c) => c.id !== aId && c.id !== bId);
    this._cells.push(merged);
    const event: EditEvent = { kind: "merged", removed, added: merged };
    this.commit(event);
    return event;
  }

  /**
   * Split one mask into two along a source-px `stroke`. The stroke defines a
   * cut line (first → last point); each contour vertex (or, for a
   * contour-less cell, the four bbox corners) is assigned to the side of the
   * line it falls on, and the two point-groups become two new cells with
   * equivalent-circle diameters. Degenerate splits (a side with < 3 points)
   * fall back to two half-diameter cells offset perpendicular to the stroke.
   */
  split(id: string, stroke: Pt[]): EditEvent {
    const original = this._cells.find((c) => c.id === id);
    if (!original || stroke.length < 2) {
      const noop: EditEvent = { kind: "removed", cells: [] };
      this.commit(noop);
      return noop;
    }

    const a = stroke[0];
    const b = stroke[stroke.length - 1];

    // Source vertices to partition: the contour if present, else the bbox corners.
    const verts: Array<[number, number]> = original.contourPx
      ? original.contourPx
      : bboxCorners(original);

    // Signed side of the cut line for each vertex.
    const left: Array<[number, number]> = [];
    const right: Array<[number, number]> = [];
    for (const v of verts) {
      const side = crossSign(a, b, { x: v[0], y: v[1] });
      if (side >= 0) left.push(v);
      else right.push(v);
    }

    let first: CellDTO;
    let second: CellDTO;
    if (left.length >= 3 && right.length >= 3) {
      first = cellFromPolygon(left, original, this.ctx.pxPerUm);
      second = cellFromPolygon(right, original, this.ctx.pxPerUm);
    } else {
      // Fallback: two half-diameter cells offset perpendicular to the stroke.
      [first, second] = splitByOffset(original, a, b, this.ctx.pxPerUm);
    }

    const removed = { ...original };
    this._cells = this._cells.filter((c) => c.id !== id);
    this._cells.push(first, second);
    const event: EditEvent = { kind: "split", removed, added: [first, second] };
    this.commit(event);
    return event;
  }

  /**
   * Resize a cell to a new pixel diameter (min 8px → radius 4, matching the
   * Swift resize clamp). `newDiameterUm = newDiameterPx / pxPerUm` (px wins).
   */
  resize(id: string, newDiameterPx: number): EditEvent {
    const i = this._cells.findIndex((c) => c.id === id);
    if (i < 0) {
      const noop: EditEvent = { kind: "removed", cells: [] };
      this.commit(noop);
      return noop;
    }
    const cell = this._cells[i];
    const oldDiameterUm = cell.diameterUm;
    const clampedPx = Math.max(8, newDiameterPx); // radius >= 4 (Swift `max(4, …)`).
    const newDiameterUm =
      this.ctx.pxPerUm > 0 ? clampedPx / this.ctx.pxPerUm : cell.diameterUm;
    this._cells[i] = {
      ...cell,
      diameterPx: clampedPx,
      diameterUm: newDiameterUm,
    };
    const event: EditEvent = {
      kind: "resized",
      cell: { ...this._cells[i] },
      oldDiameterUm,
    };
    this.commit(event);
    return event;
  }

  // ── undo / redo ─────────────────────────────────────────────────────────

  /**
   * Undo the most recent committed edit. Returns the INVERSE-applied event
   * (what actually changed), or undefined when the stack is empty. Does NOT
   * fire `onCommit` (undo/redo are not new user edits — see the Swift host,
   * which re-emits to `onEdit` for persistence; here we notify listeners with
   * the applied event so the persistence layer can mirror the change, but we
   * never push onto the undo stack from within undo/redo).
   */
  undo(): EditEvent | undefined {
    const last = this.undoStack.pop();
    if (!last) return undefined;
    const applied = this.invert(last);
    this.redoStack.push(last);
    if (this.redoStack.length > UNDO_LIMIT) this.redoStack.shift();
    this.notify(applied);
    return applied;
  }

  /** Redo the most recently undone edit. Returns the re-applied event. */
  redo(): EditEvent | undefined {
    const last = this.redoStack.pop();
    if (!last) return undefined;
    this.reapply(last);
    this.undoStack.push(last);
    if (this.undoStack.length > UNDO_LIMIT) this.undoStack.shift();
    this.notify(last);
    return last;
  }

  // ── subscription ──────────────────────────────────────────────────────

  /** Subscribe to committed edits (and undo/redo re-applications). */
  onCommit(cb: (e: EditEvent, cells: CellDTO[]) => void): () => void {
    this.listeners.add(cb);
    return () => {
      this.listeners.delete(cb);
    };
  }

  // ── internals ─────────────────────────────────────────────────────────

  /** Push onto the undo stack (cap 50), clear redo, notify listeners. */
  private commit(event: EditEvent): void {
    this.undoStack.push(event);
    if (this.undoStack.length > UNDO_LIMIT) this.undoStack.shift();
    this.redoStack = []; // any new action clears redo history (Bug #6).
    this.notify(event);
  }

  private notify(event: EditEvent): void {
    const snapshot = this.cells;
    for (const cb of this.listeners) cb(event, snapshot);
  }

  /**
   * Apply the inverse of `event` to `_cells` and return the event describing
   * what changed (so listeners/persistence can mirror it). Mirrors the
   * per-case logic of `performUndo`.
   */
  private invert(event: EditEvent): EditEvent {
    switch (event.kind) {
      case "added": {
        // Undo an add ⇒ remove the added cell.
        this._cells = this._cells.filter((c) => c.id !== event.cell.id);
        return { kind: "removed", cells: [event.cell] };
      }
      case "removed": {
        // Undo a removal ⇒ re-insert all removed cells.
        for (const c of event.cells) this._cells.push({ ...c });
        // Describe as adds so a persistence mirror re-creates them.
        return { kind: "removed", cells: event.cells }; // symmetric restore
      }
      case "merged": {
        // Undo a merge ⇒ remove the merged result, restore originals.
        this._cells = this._cells.filter((c) => c.id !== event.added.id);
        for (const c of event.removed) this._cells.push({ ...c });
        return { kind: "merged", removed: event.removed, added: event.added };
      }
      case "split": {
        // Undo a split ⇒ remove the two, restore the original.
        const addedIds = new Set(event.added.map((c) => c.id));
        this._cells = this._cells.filter((c) => !addedIds.has(c.id));
        this._cells.push({ ...event.removed });
        return { kind: "split", removed: event.removed, added: event.added };
      }
      case "resized": {
        // Undo a resize ⇒ restore the old µm diameter (recompute px).
        const i = this._cells.findIndex((c) => c.id === event.cell.id);
        if (i >= 0) {
          const oldPx =
            this.ctx.pxPerUm > 0
              ? event.oldDiameterUm * this.ctx.pxPerUm
              : event.oldDiameterUm;
          this._cells[i] = {
            ...this._cells[i],
            diameterUm: event.oldDiameterUm,
            diameterPx: oldPx,
          };
        }
        return event;
      }
    }
  }

  /** Re-apply `event` to `_cells` (mirrors `performRedo`). */
  private reapply(event: EditEvent): void {
    switch (event.kind) {
      case "added":
        this._cells.push({ ...event.cell });
        break;
      case "removed": {
        const ids = new Set(event.cells.map((c) => c.id));
        this._cells = this._cells.filter((c) => !ids.has(c.id));
        break;
      }
      case "merged": {
        const ids = new Set(event.removed.map((c) => c.id));
        this._cells = this._cells.filter((c) => !ids.has(c.id));
        this._cells.push({ ...event.added });
        break;
      }
      case "split": {
        this._cells = this._cells.filter((c) => c.id !== event.removed.id);
        this._cells.push({ ...event.added[0] }, { ...event.added[1] });
        break;
      }
      case "resized": {
        const i = this._cells.findIndex((c) => c.id === event.cell.id);
        if (i >= 0) this._cells[i] = { ...event.cell };
        break;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// free helpers used by split / merge
// ---------------------------------------------------------------------------

/** Merged diameter per §3.5: √(dₐ² + d_b²)/√2. */
function combinedDiameter(da: number, db: number): number {
  return Math.sqrt(da * da + db * db) / Math.SQRT2;
}

/** The four bbox corners of a contour-less cell, as source-px pairs. */
function bboxCorners(c: CellDTO): Array<[number, number]> {
  const r = c.diameterPx / 2;
  return [
    [c.cx - r, c.cy - r],
    [c.cx + r, c.cy - r],
    [c.cx + r, c.cy + r],
    [c.cx - r, c.cy + r],
  ];
}

/** Sign of the cross product (b−a)×(p−a): >0 left, <0 right, 0 on-line. */
function crossSign(a: Pt, b: Pt, p: Pt): number {
  return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
}

/** Centroid of a set of points. */
function centroidOf(pts: Array<[number, number]>): Pt {
  let sx = 0;
  let sy = 0;
  for (const [x, y] of pts) {
    sx += x;
    sy += y;
  }
  return { x: sx / pts.length, y: sy / pts.length };
}

/** Build a child cell from a sub-polygon of a split (equiv-circle diameter). */
function cellFromPolygon(
  poly: Array<[number, number]>,
  parent: CellDTO,
  pxPerUm: number,
): CellDTO {
  const centroid = centroidOf(poly);
  const area = Math.abs(polygonAreaShoelace(poly));
  // Fall back to half the parent's diameter when the sub-polygon is degenerate.
  const equivPx =
    area > 1 ? 2.0 * Math.sqrt(area / Math.PI) : parent.diameterPx / 2;
  const diameterUm = pxPerUm > 0 ? equivPx / pxPerUm : equivPx;
  return {
    id: newCellId(),
    cx: centroid.x,
    cy: centroid.y,
    diameterUm,
    diameterPx: equivPx,
    confidence: parent.confidence,
    contourPx: closePoly(poly),
    isManual: parent.isManual,
  };
}

/** Ensure a polygon is closed (first == last). */
function closePoly(
  poly: Array<[number, number]>,
): Array<[number, number]> {
  if (poly.length < 3) return poly;
  const first = poly[0];
  const last = poly[poly.length - 1];
  if (first[0] === last[0] && first[1] === last[1]) return poly;
  return [...poly, [first[0], first[1]]];
}

/**
 * Fallback split: two half-diameter cells offset ± perpendicular to the stroke
 * from the parent center. Used when a clean polygon partition isn't possible.
 */
function splitByOffset(
  parent: CellDTO,
  a: Pt,
  b: Pt,
  pxPerUm: number,
): [CellDTO, CellDTO] {
  // Unit vector along the stroke; perpendicular is (-dy, dx).
  let dx = b.x - a.x;
  let dy = b.y - a.y;
  const len = Math.hypot(dx, dy) || 1;
  dx /= len;
  dy /= len;
  const px = -dy;
  const py = dx;

  const offset = parent.diameterPx / 4; // quarter-diameter each side.
  const childPx = parent.diameterPx / 2;
  const childUm = pxPerUm > 0 ? childPx / pxPerUm : parent.diameterUm / 2;

  const mk = (sign: number): CellDTO => ({
    id: newCellId(),
    cx: parent.cx + px * offset * sign,
    cy: parent.cy + py * offset * sign,
    diameterUm: childUm,
    diameterPx: childPx,
    confidence: parent.confidence,
    isManual: parent.isManual,
  });

  return [mk(1), mk(-1)];
}
