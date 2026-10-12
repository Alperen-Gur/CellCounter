import type { Coordinate, ImagePlane, LayerSource, MicroscopyWorkspace, OperationOptions, WorkspaceAxis, WorkspaceLayer } from './types';
import { fail, finite, integer, newID, product, resourceLimits, validatePlane, yieldTask } from './guards';
import { applyTransform, IDENTITY, inverseTransform, samplePlane } from './registration';

export function createWorkspace(name: string, axes: WorkspaceAxis[] = []): MicroscopyWorkspace {
  const now = new Date().toISOString(); return { schemaVersion: 1, id: newID(), name, createdAt: now, modifiedAt: now, axes: axes.map(axis => ({ ...axis })), position: Object.fromEntries(axes.map(axis => [axis.id, 0])), layers: [], lineage: { nodes: [], edges: [] }, paintDocuments: {}, workflows: [], animationPlans: [] };
}
export function createLayer(name: string, source: LayerSource, options: Partial<WorkspaceLayer> = {}): WorkspaceLayer {
  return { id: newID(), name, kind: 'image', source, axisIDs: [], visible: true, opacity: 1, blendMode: 'normal', transform: { ...IDENTITY }, display: { min: 0, max: 1, gamma: 1, color: [255, 255, 255] }, ...options };
}
export function planeRange(plane: ImagePlane): { min: number; max: number } { let min = Infinity, max = -Infinity; for (const value of plane.values) { if (!Number.isFinite(value)) continue; min = Math.min(min, value); max = Math.max(max, value); } if (!Number.isFinite(min)) return { min: 0, max: 1 }; if (min === max) return { min, max: min + Math.max(1, Math.abs(min) * 1e-6) }; return { min, max }; }
export function setPosition(workspace: MicroscopyWorkspace, axisID: string, value: number): void { const axis = workspace.axes.find(item => item.id === axisID); if (!axis) fail('unknown-axis', 'The selected axis is absent from the workspace.'); workspace.position[axisID] = integer(value, 'Axis index', 0, axis!.length - 1); workspace.modifiedAt = new Date().toISOString(); }
export function matchesPosition(objectPosition: Record<string, number>, position: Record<string, number>): boolean { return Object.entries(objectPosition).every(([axisID, value]) => position[axisID] === value); }
export interface ComposeOptions extends OperationOptions { width?: number; height?: number; origin?: Coordinate; zoom?: number; center?: Coordinate }
export interface ComposedPlane { width: number; height: number; rgba: Uint8ClampedArray }

export async function composePlane(workspace: MicroscopyWorkspace, planes: ReadonlyMap<string, ImagePlane>, options: ComposeOptions = {}): Promise<ComposedPlane> {
  const limits = resourceLimits(options); const first = workspace.layers.map(layer => planes.get(layer.id)).find(Boolean);
  const width = integer(options.width ?? first?.width ?? 1024, 'Canvas width', 1); const height = integer(options.height ?? first?.height ?? 1024, 'Canvas height', 1); const n = product([width, height], 'Canvas pixels', limits.maxPixels);
  // Count unique live buffers once. Host plane caches must be bounded separately.
  const unique = new Set<ImagePlane>(planes.values()); let inputBytes = 0; for (const plane of unique) inputBytes += validatePlane(plane, options) * 4;
  if (inputBytes + n * 4 + 1024 * 1024 > limits.maxWorkingBytes) fail('resource-limit', 'Layer composition exceeds the local working memory budget.');
  const rgba = new Uint8ClampedArray(n * 4); for (let i = 3; i < rgba.length; i += 4) rgba[i] = 255;
  const origin = options.origin ?? { x: 0, y: 0 }; finite(origin.x, 'Canvas origin X'); finite(origin.y, 'Canvas origin Y');
  const zoom = finite(options.zoom ?? 1, 'Canvas zoom'); if (zoom <= 0 || zoom > 64) fail('invalid-zoom', 'Canvas zoom must be in (0, 64].');
  const center = options.center; if (center) { finite(center.x, 'Canvas center X'); finite(center.y, 'Canvas center Y'); }
  const viewPoint = (x: number, y: number): Coordinate => ({ x: (x + 0.5 - (center ? width / 2 : 0)) / zoom + (center?.x ?? origin.x), y: (y + 0.5 - (center ? height / 2 : 0)) / zoom + (center?.y ?? origin.y) });
  const toCanvas = (p: Coordinate): Coordinate => ({ x: (p.x - (center?.x ?? origin.x)) * zoom + (center ? width / 2 : 0), y: (p.y - (center?.y ?? origin.y)) * zoom + (center ? height / 2 : 0) });
  const blend = (index: number, rgb: readonly number[], opacity: number, mode: WorkspaceLayer['blendMode']): void => {
    for (let c = 0; c < 3; c++) { const base = rgba[index + c] / 255; const top = Math.max(0, Math.min(1, rgb[c] / 255)); const result = mode === 'additive' ? Math.min(1, base + top) : mode === 'multiply' ? base * top : mode === 'screen' ? 1 - (1 - base) * (1 - top) : mode === 'difference' ? Math.abs(base - top) : top; rgba[index + c] = (base * (1 - opacity) + result * opacity) * 255; }
  };
  let drawingWork = 0;
  for (const layer of workspace.layers) {
    await yieldTask(options.signal);
    if (!layer.visible) continue; const opacity = finite(layer.opacity, 'Layer opacity'); if (opacity < 0 || opacity > 1) fail('invalid-opacity', 'Layer opacity must be in 0…1.');
    const inverse = inverseTransform(layer.transform); const plane = planes.get(layer.id); const min = finite(layer.display.min, 'Display minimum'); const max = finite(layer.display.max, 'Display maximum'); const gamma = finite(layer.display.gamma, 'Display gamma'); if (max <= min || gamma <= 0 || gamma > 10) fail('invalid-display', 'Display range must be increasing and gamma must be in (0, 10].');
    if (plane && (layer.kind === 'image' || layer.kind === 'labels')) {
      const classes = workspace.paintDocuments[layer.id]?.classes ?? []; const colors = new Map(classes.map(item => [item.value, hexColor(item.colorHex)]));
      for (let y = 0; y < height; y++) {
        if (y % 16 === 0) await yieldTask(options.signal);
        for (let x = 0; x < width; x++) {
          if ((y * width + x) % 65_536 === 0) await yieldTask(options.signal);
          const point = applyTransform(inverse, viewPoint(x, y)); const value = samplePlane(plane, point.x, point.y); if (!Number.isFinite(value)) continue;
          if (layer.kind === 'labels') { if (value === 0) continue; integer(value, 'Label value', 0, 65535); const color = colors.get(value) ?? labelColor(value); blend((y * width + x) * 4, color, opacity, layer.blendMode); }
          else { const intensity = Math.pow(Math.max(0, Math.min(1, (value - min) / (max - min))), 1 / gamma); blend((y * width + x) * 4, layer.display.color.map(c => c * intensity), opacity, layer.blendMode); }
        }
      }
    }
    const color = layer.display.color;
    const canvasDot = (p: Coordinate, radius = 3): void => { finite(p.x, 'Geometry X'); finite(p.y, 'Geometry Y'); const x0 = Math.max(0, Math.floor(p.x - radius)); const x1 = Math.min(width - 1, Math.ceil(p.x + radius)); const y0 = Math.max(0, Math.floor(p.y - radius)); const y1 = Math.min(height - 1, Math.ceil(p.y + radius)); for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) { if (++drawingWork > 5_000_000) fail('resource-limit', 'Vector drawing exceeds the local work budget. Hide complex geometry layers.'); if ((x + 0.5 - p.x) ** 2 + (y + 0.5 - p.y) ** 2 <= radius ** 2) blend((y * width + x) * 4, color, opacity, layer.blendMode); } };
    const dot = (point: Coordinate, radius = 3): void => canvasDot(toCanvas(applyTransform(layer.transform, point)), radius);
    const line = (a: Coordinate, b: Coordinate): void => {
      const p = toCanvas(applyTransform(layer.transform, a)), q = toCanvas(applyTransform(layer.transform, b)); finite(p.x, 'Segment X'); finite(p.y, 'Segment Y'); finite(q.x, 'Segment X'); finite(q.y, 'Segment Y');
      const dx = q.x - p.x, dy = q.y - p.y; let low = 0, high = 1;
      // Liang–Barsky clips off-canvas geometry before raster work is counted.
      for (const [direction, distance] of [[-dx, p.x + 1], [dx, width + 1 - p.x], [-dy, p.y + 1], [dy, height + 1 - p.y]]) { if (direction === 0) { if (distance < 0) return; } else { const t = distance / direction; if (direction < 0) low = Math.max(low, t); else high = Math.min(high, t); if (low > high) return; } }
      const sx = p.x + dx * low, sy = p.y + dy * low, ex = p.x + dx * high, ey = p.y + dy * high; const steps = Math.ceil(Math.hypot(ex - sx, ey - sy));
      if (!Number.isSafeInteger(steps) || steps > 1_000_000) fail('resource-limit', 'A shape segment exceeds the local drawing budget.');
      for (let i = 0; i <= steps; i++) { const t = steps ? i / steps : 0; canvasDot({ x: sx + (ex - sx) * t, y: sy + (ey - sy) * t }, 1); }
    };
    let geometryIndex = 0;
    for (const point of layer.points ?? []) { if (geometryIndex++ % 128 === 0) await yieldTask(options.signal); if (matchesPosition(point.position, workspace.position)) dot(point.coordinate); }
    for (const shape of layer.shapes ?? []) {
      if (geometryIndex++ % 32 === 0) await yieldTask(options.signal);
      if (!matchesPosition(shape.position, workspace.position) || shape.vertices.length < 2) continue;
      const vertices = shape.vertices; const a = vertices[0]; const b = vertices[1];
      if (shape.kind === 'rectangle') { const corners = [a, { x: b.x, y: a.y }, b, { x: a.x, y: b.y }, a]; for (let i = 1; i < corners.length; i++) line(corners[i - 1], corners[i]); }
      else if (shape.kind === 'ellipse') { const cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2, rx = Math.abs(a.x - b.x) / 2, ry = Math.abs(a.y - b.y) / 2; let previous = { x: cx + rx, y: cy }; for (let i = 1; i <= 96; i++) { const next = { x: cx + Math.cos(i * Math.PI / 48) * rx, y: cy + Math.sin(i * Math.PI / 48) * ry }; line(previous, next); previous = next; } }
      else { for (let i = 1; i < vertices.length; i++) line(vertices[i - 1], vertices[i]); if (shape.kind === 'polygon') line(vertices[vertices.length - 1], vertices[0]); }
    }
    const timeAxis = workspace.axes.find(axis => axis.kind === 'time'); const frame = timeAxis ? workspace.position[timeAxis.id] ?? 0 : Infinity;
    for (const track of layer.tracks ?? []) { await yieldTask(options.signal); const vertices = track.vertices.filter(vertex => vertex.frame <= frame).sort((a, b) => a.frame - b.frame); for (let i = 1; i < vertices.length; i++) { if (i % 128 === 0) await yieldTask(options.signal); line(vertices[i - 1].coordinate, vertices[i].coordinate); } if (vertices.length) dot(vertices[vertices.length - 1].coordinate); }
    if (layer.surface) for (const triangle of layer.surface.triangles) { if (geometryIndex++ % 32 === 0) await yieldTask(options.signal); const vertices = triangle.map(i => layer.surface!.vertices[i]); if (vertices.some(v => !v)) fail('invalid-surface', 'Surface triangles reference missing vertices.'); for (let i = 0; i < 3; i++) line(vertices[i], vertices[(i + 1) % 3]); }
  }
  return { width, height, rgba };
}
export function hexColor(hex: string): [number, number, number] { if (!/^#[0-9a-f]{6}$/i.test(hex)) fail('invalid-color', 'Colors must use #RRGGBB.'); return [parseInt(hex.slice(1, 3), 16), parseInt(hex.slice(3, 5), 16), parseInt(hex.slice(5, 7), 16)]; }
export function labelColor(value: number): [number, number, number] { const hash = Math.imul(value, 0x9e3779b1) >>> 0; return [64 + (hash & 191), 64 + ((hash >>> 8) & 191), 64 + ((hash >>> 16) & 191)]; }
