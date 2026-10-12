import type { AffineTransform, Calibration, Coordinate, ImagePlane, RegistrationOptions, RegistrationResult, StitchOptions, StitchResult } from './types';
import { checkAbort, fail, finite, integer, product, resourceLimits, validatePlane, yieldTask } from './guards';
export const IDENTITY: Readonly<AffineTransform> = Object.freeze({ a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 });
export function validateTransform(transform: AffineTransform): void { for (const key of ['a', 'b', 'c', 'd', 'tx', 'ty'] as const) finite(transform?.[key], `Transform ${key}`); const determinant = transform.a * transform.d - transform.b * transform.c; if (!Number.isFinite(determinant) || Math.abs(determinant) < 1e-12) fail('singular-transform', 'The layer transform has no finite inverse.'); }
export function applyTransform(transform: AffineTransform, point: Coordinate): Coordinate { return { x: transform.a * point.x + transform.c * point.y + transform.tx, y: transform.b * point.x + transform.d * point.y + transform.ty, z: point.z }; }
export function inverseTransform(t: AffineTransform): AffineTransform { validateTransform(t); const determinant = t.a * t.d - t.b * t.c; const result = { a: t.d / determinant, b: -t.b / determinant, c: -t.c / determinant, d: t.a / determinant, tx: (t.c * t.ty - t.d * t.tx) / determinant, ty: (t.b * t.tx - t.a * t.ty) / determinant }; for (const value of Object.values(result)) finite(value, 'Inverse transform'); return result; }
/** Applies first, then next, using the macOS workspace column-vector convention. */
export function concatenateTransform(first: AffineTransform, next: AffineTransform): AffineTransform { const result = { a: next.a * first.a + next.c * first.b, b: next.b * first.a + next.d * first.b, c: next.a * first.c + next.c * first.d, d: next.b * first.c + next.d * first.d, tx: next.a * first.tx + next.c * first.ty + next.tx, ty: next.b * first.tx + next.d * first.ty + next.ty }; validateTransform(result); return result; }
function unitMeters(unit: string): number | undefined { return ({ m: 1, meter: 1, metre: 1, millimeter: 1e-3, millimetre: 1e-3, mm: 1e-3, micrometer: 1e-6, micrometre: 1e-6, micron: 1e-6, um: 1e-6, 'µm': 1e-6, 'μm': 1e-6, nanometer: 1e-9, nanometre: 1e-9, nm: 1e-9 })[unit.toLowerCase()]; }
export function calibrationScale(reference?: Calibration, moving?: Calibration): { x: number; y: number } {
  if (!reference && !moving) return { x: 1, y: 1 };
  if (!reference || !moving) fail('calibration-mismatch', 'Both planes need calibration, or both must use pixels. Set the missing calibration before combining them.');
  const ref = reference!; const mov = moving!; let factor = 1;
  if (ref.unit !== mov.unit) { const a = unitMeters(ref.unit); const b = unitMeters(mov.unit); if (!a || !b) fail('calibration-mismatch', 'The planes use incompatible calibration units.'); factor = b! / a!; }
  const x = mov.x * factor / ref.x; const y = mov.y * factor / ref.y;
  if (!Number.isFinite(x) || !Number.isFinite(y) || x <= 0 || y <= 0) fail('invalid-calibration', 'Calibration ratios must be finite and positive.'); return { x, y };
}
/** Nearest sampling preserves semantic labels and avoids inventing source intensities. */
export function samplePlane(plane: ImagePlane, x: number, y: number): number { const px = Math.floor(x); const py = Math.floor(y); if (px < 0 || py < 0 || px >= plane.width || py >= plane.height) return NaN; return plane.values[py * plane.width + px]; }

/** Bounded coarse-to-fine translation search using normalized cross correlation.
 * Reports its metric; it is not affine/deformable registration or proof of alignment. */
export async function registerTranslation(reference: ImagePlane, moving: ImagePlane, options: RegistrationOptions = {}): Promise<RegistrationResult> {
  const limits = resourceLimits(options); const refCount = validatePlane(reference, options); const movCount = validatePlane(moving, options);
  if ((refCount + movCount) * 4 + 1024 * 1024 > limits.maxWorkingBytes) fail('resource-limit', 'Registration input exceeds the working memory budget.');
  const maxShift = integer(options.maxShift ?? 64, 'Maximum shift', 0, 1024); const maxSamples = integer(options.maxSamples ?? 4096, 'Registration samples', 64, 16384);
  const overlap = finite(options.minOverlap ?? 0.1, 'Minimum overlap'); if (overlap <= 0 || overlap > 1) fail('invalid-overlap', 'Registration overlap must be in (0, 1].');
  const scale = calibrationScale(reference.calibration, moving.calibration); const movingWidth = moving.width * scale.x; const movingHeight = moving.height * scale.y;
  if (!Number.isFinite(movingWidth) || !Number.isFinite(movingHeight)) fail('invalid-calibration', 'Calibrated moving dimensions overflow.');
  const minimumArea = Math.min(refCount, movingWidth * movingHeight) * overlap;
  const scoreAt = (dx: number, dy: number): { score: number; samples: number } => {
    const minX = Math.max(0, Math.ceil(dx)); const minY = Math.max(0, Math.ceil(dy)); const maxX = Math.min(reference.width, Math.floor(movingWidth + dx)); const maxY = Math.min(reference.height, Math.floor(movingHeight + dy));
    if (maxX - minX < 4 || maxY - minY < 4 || (maxX - minX) * (maxY - minY) < minimumArea) return { score: -Infinity, samples: 0 };
    const spanX = maxX - minX, spanY = maxY - minY;
    const sampleX = Math.max(1, Math.min(spanX, maxSamples, Math.floor(Math.sqrt(maxSamples * spanX / spanY))));
    const sampleY = Math.max(1, Math.min(spanY, Math.floor(maxSamples / sampleX)));
    // Axis-aware sampling stays <= maxSamples even on very wide/short planes.
    // Welford covariance avoids catastrophic cancellation on high offset intensity data.
    let count = 0, meanA = 0, meanB = 0, varA = 0, varB = 0, covariance = 0;
    for (let sy = 0; sy < sampleY; sy++) for (let sx = 0; sx < sampleX; sx++) {
      const x = minX + Math.floor((sx + 0.5) * spanX / sampleX); const y = minY + Math.floor((sy + 0.5) * spanY / sampleY);
      const a = reference.values[y * reference.width + x]; const b = samplePlane(moving, (x + 0.5 - dx) / scale.x, (y + 0.5 - dy) / scale.y);
      if (!Number.isFinite(a) || !Number.isFinite(b)) continue;
      count++; const da = a - meanA; const db = b - meanB; meanA += da / count; meanB += db / count; varA += da * (a - meanA); varB += db * (b - meanB); covariance += da * (b - meanB);
    }
    const denom = Math.sqrt(Math.max(0, varA) * Math.max(0, varB)); return { score: count >= 16 && denom > 1e-20 ? Math.max(-1, Math.min(1, covariance / denom)) : -Infinity, samples: count };
  };
  let best = { x: 0, y: 0, score: -Infinity, samples: 0 }; const seen = new Set<string>(); let completed = 0;
  let step = Math.max(1, Math.ceil(maxShift / 16));
  const search = async (centerX: number, centerY: number, radius: number, searchStep: number): Promise<void> => {
    const startX = Math.max(-maxShift, centerX - radius); const endX = Math.min(maxShift, centerX + radius); const startY = Math.max(-maxShift, centerY - radius); const endY = Math.min(maxShift, centerY + radius);
    const candidates: [number, number][] = [[centerX, centerY], [0, 0]];
    for (let y = startY; y <= endY; y += searchStep) for (let x = startX; x <= endX; x += searchStep) candidates.push([x, y]);
    for (const [x, y] of candidates) {
      if (Math.abs(x) > maxShift || Math.abs(y) > maxShift) continue; const key = `${x},${y}`; if (seen.has(key)) continue; seen.add(key);
      if (completed++ % 8 === 0) await yieldTask(options.signal); const result = scoreAt(x, y);
      if (result.score > best.score + 1e-12 || (Number.isFinite(result.score) && Math.abs(result.score - best.score) <= 1e-12 && x * x + y * y < best.x * best.x + best.y * best.y)) best = { x, y, ...result };
    }
  };
  checkAbort(options.signal); await search(0, 0, maxShift, step); options.onProgress?.(0.6);
  while (step > 1) { const previous = step; step = Math.max(1, Math.floor(step / 2)); await search(best.x, best.y, previous * 2, step); options.onProgress?.(0.9); }
  // Coarse grid zero-radius edge cases also examine the immediate integer neighbourhood.
  await search(best.x, best.y, Math.min(maxShift, 2), 1); checkAbort(options.signal);
  if (!Number.isFinite(best.score)) fail('no-registration', 'No finite, textured overlap was found. Constant or invalid-valued planes cannot be registered by correlation.');
  options.onProgress?.(1); return { transform: { a: scale.x, b: 0, c: 0, d: scale.y, tx: best.x, ty: best.y }, score: best.score, samples: best.samples, movingToReferenceScale: scale, physicalTranslation: reference.calibration ? { x: best.x * reference.calibration.x, y: best.y * reference.calibration.y, unit: reference.calibration.unit } : undefined };
}

export async function stitchGrid(planes: ImagePlane[], options: StitchOptions): Promise<StitchResult> {
  if (!planes.length || planes.length > 256) fail('invalid-tiles', 'Choose between 1 and 256 tiles.');
  const limits = resourceLimits(options); const inputPixels = planes.reduce((sum, plane) => sum + validatePlane(plane, options), 0);
  const columns = integer(options.columns, 'Grid columns', 1, planes.length); const overlap = finite(options.overlap ?? 0.1, 'Tile overlap');
  if (overlap < 0 || overlap > 0.95) fail('invalid-overlap', 'Tile overlap must be between 0 and 0.95.');
  if (options.blend !== undefined && options.blend !== 'average' && options.blend !== 'maximum') fail('invalid-blend', 'Unknown stitch blend.');
  const scales = planes.map(plane => calibrationScale(planes[0].calibration, plane.calibration));
  const columnWidths = Array<number>(columns).fill(0); const rowHeights = Array<number>(Math.ceil(planes.length / columns)).fill(0);
  planes.forEach((plane, i) => { columnWidths[i % columns] = Math.max(columnWidths[i % columns], plane.width * scales[i].x); rowHeights[Math.floor(i / columns)] = Math.max(rowHeights[Math.floor(i / columns)], plane.height * scales[i].y); });
  const transforms = options.transforms ?? planes.map((_, i) => ({ a: scales[i].x, b: 0, c: 0, d: scales[i].y, tx: columnWidths.slice(0, i % columns).reduce((sum, n) => sum + n * (1 - overlap), 0), ty: rowHeights.slice(0, Math.floor(i / columns)).reduce((sum, n) => sum + n * (1 - overlap), 0) }));
  if (transforms.length !== planes.length) fail('invalid-geometry', 'Every tile needs a transform.');
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  transforms.forEach((transform, i) => { validateTransform(transform); const plane = planes[i]; for (const point of [{ x: 0, y: 0 }, { x: plane.width, y: 0 }, { x: 0, y: plane.height }, { x: plane.width, y: plane.height }]) { const p = applyTransform(transform, point); finite(p.x, 'Stitched X bound'); finite(p.y, 'Stitched Y bound'); minX = Math.min(minX, p.x); minY = Math.min(minY, p.y); maxX = Math.max(maxX, p.x); maxY = Math.max(maxY, p.y); } });
  const origin = { x: Math.floor(minX), y: Math.floor(minY) }; const width = Math.ceil(maxX) - origin.x; const height = Math.ceil(maxY) - origin.y;
  integer(origin.x, 'Stitched origin X', -Number.MAX_SAFE_INTEGER); integer(origin.y, 'Stitched origin Y', -Number.MAX_SAFE_INTEGER);
  const n = product([width, height], 'Stitched pixels', limits.maxPixels); const memory = inputPixels * 4 + n * 10 + 1024 * 1024;
  if (!Number.isSafeInteger(memory) || memory > limits.maxWorkingBytes) fail('resource-limit', 'Stitching exceeds the working memory budget. Reduce tiles or select coarser planes.');
  // A memory-bounded output alone does not bound resampling: many small tiles
  // can each be expanded to cover the entire output by their transforms.
  let work = 0;
  const bounds = transforms.map((transform, i) => {
    const plane = planes[i]; const corners = [{ x: 0, y: 0 }, { x: plane.width, y: 0 }, { x: 0, y: plane.height }, { x: plane.width, y: plane.height }].map(p => applyTransform(transform, p));
    const minX = Math.max(0, Math.floor(Math.min(...corners.map(p => p.x)) - origin.x)), maxX = Math.min(width, Math.ceil(Math.max(...corners.map(p => p.x)) - origin.x));
    const minY = Math.max(0, Math.floor(Math.min(...corners.map(p => p.y)) - origin.y)), maxY = Math.min(height, Math.ceil(Math.max(...corners.map(p => p.y)) - origin.y));
    work += Math.max(0, maxX - minX) * Math.max(0, maxY - minY);
    if (!Number.isSafeInteger(work) || work > 100_000_000) fail('resource-limit', 'Transformed tiles exceed the 100-million-pixel stitching work budget. Reduce tiles, scaling or overlap.');
    return { minX, maxX, minY, maxY };
  });
  const values = new Float32Array(n); const coverage = new Uint16Array(n); let completed = 0; const totalRows = Math.max(1, bounds.reduce((sum, bound) => sum + bound.maxY - bound.minY, 0));
  let processedPixels = 0;
  for (let i = 0; i < planes.length; i++) {
    const inverse = inverseTransform(transforms[i]); const plane = planes[i];
    const { minX: tileMinX, maxX: tileMaxX, minY: tileMinY, maxY: tileMaxY } = bounds[i];
    for (let y = tileMinY; y < tileMaxY; y++) {
      if (y % 8 === 0) { await yieldTask(options.signal); options.onProgress?.(completed / totalRows); }
      for (let x = tileMinX; x < tileMaxX; x++) {
        if (processedPixels++ % 65_536 === 0) await yieldTask(options.signal);
        const point = applyTransform(inverse, { x: x + origin.x + 0.5, y: y + origin.y + 0.5 }); const value = samplePlane(plane, point.x, point.y); if (!Number.isFinite(value)) continue;
        const index = y * width + x; const count = coverage[index]; values[index] = options.blend === 'maximum' ? (count ? Math.max(values[index], value) : value) : count ? values[index] + (value - values[index]) / (count + 1) : value; coverage[index] = count + 1;
      }
      completed++;
    }
  }
  // Uncovered mosaic pixels remain zero; valid negative maximum values are preserved.
  checkAbort(options.signal); options.onProgress?.(1); return { plane: { width, height, values, calibration: planes[0].calibration ? { ...planes[0].calibration } : undefined }, origin, transforms: transforms.map(t => ({ ...t })) };
}
