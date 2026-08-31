import { zlibSync } from "fflate";
import { contourPoints, type ExportCell, type RgbaImage } from "./types";

function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type: string, data: Uint8Array): Uint8Array {
  const typeBytes = new TextEncoder().encode(type);
  const output = new Uint8Array(12 + data.length);
  const view = new DataView(output.buffer);
  view.setUint32(0, data.length, false); output.set(typeBytes, 4); output.set(data, 8);
  const checksumSource = new Uint8Array(typeBytes.length + data.length); checksumSource.set(typeBytes); checksumSource.set(data, typeBytes.length);
  view.setUint32(8 + data.length, crc32(checksumSource), false);
  return output;
}

function concat(parts: readonly Uint8Array[]): Uint8Array {
  const output = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0; for (const part of parts) { output.set(part, offset); offset += part.length; }
  return output;
}

export function encodeRgbaPng(image: RgbaImage): Uint8Array {
  if (image.width <= 0 || image.height <= 0 || image.data.length !== image.width * image.height * 4) throw new RangeError("RGBA dimensions do not match its data.");
  const ihdr = new Uint8Array(13); const header = new DataView(ihdr.buffer);
  header.setUint32(0, image.width, false); header.setUint32(4, image.height, false); ihdr.set([8, 6, 0, 0, 0], 8);
  const scanlines = new Uint8Array((image.width * 4 + 1) * image.height);
  for (let y = 0; y < image.height; y += 1) scanlines.set(image.data.subarray(y * image.width * 4, (y + 1) * image.width * 4), y * (image.width * 4 + 1) + 1);
  return concat([new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", zlibSync(scanlines, { level: 6 })), chunk("IEND", new Uint8Array())]);
}

function blendPixel(data: Uint8ClampedArray, width: number, height: number, x: number, y: number, color: readonly [number, number, number, number]): void {
  const ix = Math.round(x); const iy = Math.round(y);
  if (ix < 0 || ix >= width || iy < 0 || iy >= height) return;
  const offset = (iy * width + ix) * 4; const alpha = color[3] / 255;
  for (let channel = 0; channel < 3; channel += 1) data[offset + channel] = Math.round(data[offset + channel] * (1 - alpha) + color[channel] * alpha);
  data[offset + 3] = 255;
}

function line(data: Uint8ClampedArray, width: number, height: number, a: { x: number; y: number }, b: { x: number; y: number }, color: readonly [number, number, number, number], lineWidth: number): void {
  const steps = Math.max(1, Math.ceil(Math.hypot(b.x - a.x, b.y - a.y) * 2)); const radius = Math.max(0, Math.floor(lineWidth / 2));
  for (let step = 0; step <= steps; step += 1) {
    const t = step / steps; const x = a.x + (b.x - a.x) * t; const y = a.y + (b.y - a.y) * t;
    for (let dy = -radius; dy <= radius; dy += 1) for (let dx = -radius; dx <= radius; dx += 1) blendPixel(data, width, height, x + dx, y + dy, color);
  }
}

/** Pure source-resolution overlay compositor; returns a standards-valid PNG byte stream. */
export function exportAnnotatedPng(
  source: RgbaImage,
  cells: readonly ExportCell[],
  options: { readonly color?: readonly [number, number, number, number]; readonly lineWidthPx?: number; readonly minimumConfidence?: number } = {},
): Uint8Array {
  if (source.data.length !== source.width * source.height * 4) throw new RangeError("RGBA dimensions do not match its data.");
  const data = new Uint8ClampedArray(source.data);
  const color = options.color ?? [32, 211, 147, 230];
  for (const cell of [...cells].sort((a, b) => a.id.localeCompare(b.id))) {
    if ((cell.confidence ?? 1) < (options.minimumConfidence ?? 0)) continue;
    const points = contourPoints(cell);
    for (let index = 0; index < points.length; index += 1) line(data, source.width, source.height, points[index], points[(index + 1) % points.length], color, options.lineWidthPx ?? 2);
  }
  return encodeRgbaPng({ data, width: source.width, height: source.height });
}

/** Deterministic visualization of a uint32 segmentation map; label 0 stays transparent black. */
export function exportSegmentationMaskPng(labels: Uint32Array, width: number, height: number): Uint8Array {
  if (labels.length !== width * height) throw new RangeError("Label-map dimensions do not match its data.");
  const rgba = new Uint8ClampedArray(labels.length * 4);
  for (let index = 0; index < labels.length; index += 1) {
    const label = labels[index]; if (!label) continue;
    let hash = Math.imul(label, 0x45d9f3b); hash ^= hash >>> 16;
    rgba[index * 4] = 48 + (hash & 0xcf); rgba[index * 4 + 1] = 48 + ((hash >>> 8) & 0xcf); rgba[index * 4 + 2] = 48 + ((hash >>> 16) & 0xcf); rgba[index * 4 + 3] = 255;
  }
  return encodeRgbaPng({ data: rgba, width, height });
}
