import type { Calibration, Coordinate, LabelClass, PaintDocument, PaintStroke } from './types';
import { fail, finite, integer, newID, product } from './guards';
import { hexColor, matchesPosition } from './workspace';

export interface PaintOptions { maxUndoBytes?: number; maxDocumentPoints?: number; document?: PaintDocument; position?: Record<string, number> }
interface UndoEntry { before: Uint16Array; strokeID: string; position: Record<string, number>; beforeWork: number }
/** The stroke journal is durable and separately bounded. Undo eviction never
 * drops saved paint. A rejected stroke rolls back atomically to its snapshot. */
export class PaintingSession {
  readonly labels: Uint16Array;
  readonly document: PaintDocument;
  private readonly maxUndoBytes: number;
  private readonly maxDocumentPoints: number;
  private undoEntries: UndoEntry[] = [];
  private position: Record<string, number>;
  private active: { stroke: PaintStroke; before: Uint16Array; work: number } | null = null;
  private totalPoints = 0;
  private planeWork = 0;
  constructor(width: number, height: number, classes: LabelClass[], options: PaintOptions = {}) {
    const n = product([width, height], 'Paint pixels', 16_000_000);
    this.maxUndoBytes = integer(options.maxUndoBytes ?? 64 * 1024 * 1024, 'Paint undo bytes', 2, 64 * 1024 * 1024);
    if (n * 2 > this.maxUndoBytes) fail('resource-limit', 'One paint snapshot exceeds the undo budget. Select a smaller plane.');
    this.maxDocumentPoints = integer(options.maxDocumentPoints ?? 100_000, 'Paint document points', 1, 100_000);
    const classIDs = new Set<number>(); for (const item of classes) { integer(item.value, 'Paint class value', 1, 65535); if (classIDs.has(item.value)) fail('duplicate-class', 'Paint class values must be unique.'); classIDs.add(item.value); hexColor(item.colorHex); }
    if (classes.length > 1024) fail('resource-limit', 'A paint document supports at most 1024 semantic classes.');
    this.document = options.document ? structuredClone(options.document) : { width, height, classes: structuredClone(classes), strokes: [] };
    if (this.document.width !== width || this.document.height !== height) fail('invalid-paint', 'Paint document dimensions disagree with the selected source plane.');
    if (this.document.strokes.length > 10_000) fail('resource-limit', 'Paint document stroke count exceeds the local limit.');
    this.totalPoints = this.document.strokes.reduce((sum, stroke) => sum + stroke.points.length, 0);
    if (this.totalPoints > this.maxDocumentPoints) fail('resource-limit', 'Paint stroke journal exceeds the local point budget.');
    this.labels = new Uint16Array(n); this.position = { ...options.position };
    this.rebuild();
  }
  get undoCount(): number { return this.undoEntries.length; }
  get isPainting(): boolean { return Boolean(this.active); }
  selectPosition(position: Record<string, number>): void { if (this.active) fail('active-stroke', 'Finish the paint stroke before selecting another plane.'); this.position = { ...position }; this.rebuild(); }
  beginStroke(classValue: number, radius: number, position = this.position, erases = false): void {
    if (this.active) fail('active-stroke', 'Finish the current paint stroke first.');
    integer(classValue, 'Paint class', 0, 65535); finite(radius, 'Brush radius');
    if (!erases && !this.document.classes.some(item => item.value === classValue)) fail('unknown-class', 'Select a semantic class before painting.');
    if (radius < 0.5 || radius > 512) fail('invalid-brush', 'Brush radius must be between 0.5 and 512 pixels.');
    if (this.document.strokes.length >= 10_000 || this.totalPoints >= this.maxDocumentPoints) fail('resource-limit', 'The paint journal is full. Save/export this label plane before continuing in a new document.');
    this.selectPosition(position);
    // Reserve the active snapshot inside the same byte cap as committed undo entries.
    while ((this.undoEntries.length + 1) * this.labels.byteLength > this.maxUndoBytes) this.undoEntries.shift();
    this.active = { stroke: { id: newID(), classValue, radius, points: [], position: { ...position }, erases }, before: this.labels.slice(), work: 0 };
  }
  paint(point: Coordinate): void {
    if (!this.active) fail('no-stroke', 'Begin a paint stroke first.');
    finite(point.x, 'Brush X'); finite(point.y, 'Brush Y');
    if (point.x < -512 || point.y < -512 || point.x > this.document.width + 512 || point.y > this.document.height + 512) fail('invalid-brush-point', 'Brush coordinates lie outside the image.');
    const active = this.active!; const stroke = active.stroke;
    if (this.totalPoints + stroke.points.length + 1 > this.maxDocumentPoints || stroke.points.length >= 4096) { this.cancelStroke(); fail('resource-limit', 'The stroke exceeds the local point budget and was rolled back. Use shorter strokes.'); }
    const previous = stroke.points[stroke.points.length - 1]; const value = stroke.erases ? 0 : stroke.classValue;
    const work = this.segmentWork(previous ?? point, point, stroke.radius);
    if (active.work + work > 8_000_000 || this.planeWork + active.work + work > 80_000_000) { this.cancelStroke(); fail('resource-limit', 'This brush stroke or plane journal exceeds the local raster work budget and was rolled back. Use a smaller brush or shorter journal.'); }
    active.work += work; this.segment(previous ?? point, point, stroke.radius, value); stroke.points.push({ x: point.x, y: point.y });
  }
  endStroke(): PaintStroke | null {
    if (!this.active) return null; const active = this.active; this.active = null;
    if (!active.stroke.points.length) { this.labels.set(active.before); return null; }
    this.document.strokes.push(active.stroke); this.totalPoints += active.stroke.points.length;
    this.undoEntries.push({ before: active.before, strokeID: active.stroke.id, position: { ...active.stroke.position }, beforeWork: this.planeWork }); this.planeWork += active.work; return structuredClone(active.stroke);
  }
  cancelStroke(): void { if (!this.active) return; this.labels.set(this.active.before); this.active = null; }
  undo(): boolean {
    if (this.active) { this.cancelStroke(); return true; }
    const undo = this.undoEntries.pop(); if (!undo) return false;
    const last = this.document.strokes[this.document.strokes.length - 1];
    if (last?.id !== undo.strokeID) fail('invalid-undo', 'Paint history has changed outside this session. Reload the saved document.');
    this.document.strokes.pop(); this.totalPoints -= last.points.length;
    if (matchesPosition(undo.position, this.position) && matchesPosition(this.position, undo.position)) { this.labels.set(undo.before); this.planeWork = undo.beforeWork; } else this.rebuild();
    return true;
  }
  private rebuild(): void {
    this.labels.fill(0);
    let work = 0;
    for (const stroke of this.document.strokes) {
      integer(stroke.classValue, 'Paint class', 0, 65535); finite(stroke.radius, 'Brush radius');
      if (stroke.radius < 0.5 || stroke.radius > 512 || stroke.points.length > 4096) fail('invalid-paint', 'Saved stroke is outside the supported brush limits.');
      if (!matchesPosition(stroke.position, this.position)) continue;
      const value = stroke.erases ? 0 : stroke.classValue;
      for (let i = 0; i < stroke.points.length; i++) { const point = stroke.points[i]; finite(point.x, 'Saved brush X'); finite(point.y, 'Saved brush Y'); const previous = stroke.points[Math.max(0, i - 1)]; work += this.segmentWork(previous, point, stroke.radius); if (work > 80_000_000) fail('resource-limit', 'Rebuilding this paint plane exceeds the local raster work budget. Export smaller journals.'); this.segment(previous, point, stroke.radius, value); }
    }
    this.planeWork = work;
  }
  private segmentWork(a: Coordinate, b: Coordinate, radius: number): number { const minX = Math.max(0, Math.floor(Math.min(a.x, b.x) - radius)), maxX = Math.min(this.document.width - 1, Math.ceil(Math.max(a.x, b.x) + radius)); const minY = Math.max(0, Math.floor(Math.min(a.y, b.y) - radius)), maxY = Math.min(this.document.height - 1, Math.ceil(Math.max(a.y, b.y) + radius)); return Math.max(0, maxX - minX + 1) * Math.max(0, maxY - minY + 1); }
  private segment(a: Coordinate, b: Coordinate, radius: number, value: number): void {
    // Rasterize distance to a line segment once per bounded bounding-box pixel,
    // avoiding repeated disks and radius-dependent interpolation explosions.
    const minX = Math.max(0, Math.floor(Math.min(a.x, b.x) - radius)); const maxX = Math.min(this.document.width - 1, Math.ceil(Math.max(a.x, b.x) + radius));
    const minY = Math.max(0, Math.floor(Math.min(a.y, b.y) - radius)); const maxY = Math.min(this.document.height - 1, Math.ceil(Math.max(a.y, b.y) + radius));
    const dx = b.x - a.x, dy = b.y - a.y, length2 = dx * dx + dy * dy, r2 = radius * radius;
    for (let y = minY; y <= maxY; y++) for (let x = minX; x <= maxX; x++) { const px = x + 0.5 - a.x, py = y + 0.5 - a.y; const t = length2 ? Math.max(0, Math.min(1, (px * dx + py * dy) / length2)) : 0; if ((px - dx * t) ** 2 + (py - dy * t) ** 2 <= r2) this.labels[y * this.document.width + x] = value; }
  }
}
/** Baseline little-endian TIFF, one uncompressed uint16 grayscale strip.
 * Class IDs remain integers; no preview/PNG quantization is used for export. */
export function encodeLabelTIFF(width: number, height: number, labels: Uint16Array, calibration?: Calibration): Uint8Array {
  const n = product([width, height], 'Label TIFF pixels', 16_000_000); if (!(labels instanceof Uint16Array) || labels.length !== n) fail('invalid-label-plane', 'Label dimensions and pixel count disagree.');
  let resolution: { x: number; y: number } | undefined;
  if (calibration) {
    finite(calibration.x, 'X calibration'); finite(calibration.y, 'Y calibration'); if (calibration.x <= 0 || calibration.y <= 0) fail('invalid-calibration', 'Calibration sizes must be positive.');
    const units: Record<string, number> = { cm: 1, mm: 0.1, micrometer: 0.0001, micrometre: 0.0001, um: 0.0001, 'µm': 0.0001, 'μm': 0.0001, nm: 0.0000001, nanometer: 0.0000001, nanometre: 0.0000001, m: 100 };
    const cm = units[calibration.unit.toLowerCase()]; if (cm) { const candidate = { x: 1 / (calibration.x * cm), y: 1 / (calibration.y * cm) }; if ([candidate.x, candidate.y].every(value => { if (!Number.isFinite(value) || value <= 0 || value > 0xffffffff) return false; const denominator = Math.max(1, Math.min(1_000_000, Math.floor(0xffffffff / value))), numerator = Math.round(value * denominator); return numerator > 0 && numerator <= 0xffffffff && Math.abs(numerator / denominator - value) <= value * 1e-6; })) resolution = candidate; }
  }
  // Unknown units and scales outside the positive uint32 rational range remain
  // explicit in ImageDescription; zero or overflowed resolution is never emitted.
  const description = new TextEncoder().encode(JSON.stringify({ type: 'CellCounter semantic labels', calibration: calibration ?? null }) + '\0');
  const tags = resolution ? 14 : 11; const ifdEnd = 8 + 2 + tags * 12 + 4; const descriptionOffset = ifdEnd; const rationalOffset = descriptionOffset + description.length; const dataOffset = (rationalOffset + (resolution ? 16 : 0) + 1) & ~1;
  const output = new Uint8Array(dataOffset + n * 2); const view = new DataView(output.buffer); output[0] = 73; output[1] = 73; view.setUint16(2, 42, true); view.setUint32(4, 8, true); view.setUint16(8, tags, true); let offset = 10;
  const tag = (id: number, type: number, count: number, value: number) => { view.setUint16(offset, id, true); view.setUint16(offset + 2, type, true); view.setUint32(offset + 4, count, true); view.setUint32(offset + 8, value, true); offset += 12; };
  tag(256, 4, 1, width); tag(257, 4, 1, height); tag(258, 3, 1, 16); tag(259, 3, 1, 1); tag(262, 3, 1, 1); tag(270, 2, description.length, descriptionOffset); tag(273, 4, 1, dataOffset); tag(277, 3, 1, 1); tag(278, 4, 1, height); tag(279, 4, 1, n * 2);
  if (resolution) {
    tag(282, 5, 1, rationalOffset); tag(283, 5, 1, rationalOffset + 8); tag(296, 3, 1, 3);
    for (const [i, value] of [resolution.x, resolution.y].entries()) { if (!Number.isFinite(value) || value <= 0 || value > 0xffffffff) fail('invalid-calibration', 'TIFF resolution exceeds the rational range.'); const denominator = Math.max(1, Math.min(1_000_000, Math.floor(0xffffffff / value))); view.setUint32(rationalOffset + i * 8, Math.round(value * denominator), true); view.setUint32(rationalOffset + i * 8 + 4, denominator, true); }
  }
  tag(339, 3, 1, 1); output.set(description, descriptionOffset); for (let i = 0; i < n; i++) view.setUint16(dataOffset + i * 2, labels[i], true); return output;
}
