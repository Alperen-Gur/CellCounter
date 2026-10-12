import type { AnimationFrameState, AnimationPlan, OperationOptions, WorkspaceAxis } from './types';
import type { ComposedPlane } from './workspace';
import { checkAbort, fail, finite, integer, product, resourceLimits, yieldTask } from './guards';

export function animationStates(plan: AnimationPlan, axes: WorkspaceAxis[] = []): AnimationFrameState[] {
  const fps = integer(plan.framesPerSecond, 'Animation frame rate', 1, 60);
  if (plan.keyframes.length < 2 || plan.keyframes.length > 3600) fail('invalid-animation', 'Animation requires 2…3600 keyframes.');
  if (!['linear', 'easeInOut'].includes(plan.easing)) fail('invalid-animation', 'Unknown animation easing.');
  const sorted = [...plan.keyframes].sort((a, b) => a.timeSeconds - b.timeSeconds); const times = new Set<number>();
  for (const key of sorted) {
    finite(key.timeSeconds, 'Keyframe time'); finite(key.zoom, 'Keyframe zoom'); finite(key.center.x, 'Keyframe center X'); finite(key.center.y, 'Keyframe center Y');
    if (key.timeSeconds < 0 || times.has(key.timeSeconds) || key.zoom <= 0 || key.zoom > 64) fail('invalid-animation', 'Keyframes need unique nonnegative times and zoom in (0,64].'); times.add(key.timeSeconds);
    for (const [id, value] of Object.entries(key.position)) { const axis = axes.find(item => item.id === id); integer(value, 'Keyframe axis index', 0, axis ? axis.length - 1 : Number.MAX_SAFE_INTEGER); if (axes.length && !axis) fail('unknown-axis', 'Keyframe references an unknown axis.'); }
  }
  const first = sorted[0], last = sorted[sorted.length - 1]; const intervalCount = Math.ceil((last.timeSeconds - first.timeSeconds) * fps); integer(intervalCount, 'Animation intervals', 1, 3599);
  const states: AnimationFrameState[] = []; let segment = 0;
  for (let frame = 0; frame <= intervalCount; frame++) {
    const timeSeconds = Math.min(last.timeSeconds, first.timeSeconds + frame / fps); while (segment + 1 < sorted.length - 1 && timeSeconds > sorted[segment + 1].timeSeconds) segment++;
    const a = sorted[segment], b = sorted[segment + 1]; let t = Math.max(0, Math.min(1, (timeSeconds - a.timeSeconds) / (b.timeSeconds - a.timeSeconds))); if (plan.easing === 'easeInOut') t = t * t * (3 - 2 * t);
    const position: Record<string, number> = {}; for (const id of new Set([...Object.keys(a.position), ...Object.keys(b.position)])) { const start = a.position[id] ?? 0; position[id] = Math.round(start + ((b.position[id] ?? start) - start) * t); }
    const z = a.center.z === undefined ? b.center.z : b.center.z === undefined ? a.center.z : a.center.z + (b.center.z - a.center.z) * t;
    states.push({ frameNumber: frame, timeSeconds, position, zoom: a.zoom + (b.zoom - a.zoom) * t, center: { x: a.center.x + (b.center.x - a.center.x) * t, y: a.center.y + (b.center.y - a.center.y) * t, z }, visibleLayerIDs: [...(t < 0.5 ? a.visibleLayerIDs : b.visibleLayerIDs)] });
  }
  return states;
}
/** Encodes a real GIF89a locally. Uses a deterministic 3:3:2 global palette,
 * so it is a presentation export; numeric TIFF/project rasters preserve data.
 * GIF timing is quantized to centiseconds. No canvas/network encoder required. */
export async function encodeGIF(frames: ComposedPlane[], framesPerSecond = 12, options: OperationOptions = {}): Promise<Uint8Array> {
  const limits = resourceLimits(options); integer(framesPerSecond, 'GIF frame rate', 1, 60); integer(frames.length, 'GIF frame count', 2, 3600);
  const width = integer(frames[0].width, 'GIF width', 1, 65535), height = integer(frames[0].height, 'GIF height', 1, 65535); const n = product([width, height], 'GIF frame pixels', limits.maxPixels);
  for (const frame of frames) if (frame.width !== width || frame.height !== height || !(frame.rgba instanceof Uint8ClampedArray) || frame.rgba.length !== n * 4) fail('invalid-animation', 'GIF frames must have matching dimensions and RGBA buffers.');
  const codes = n + Math.ceil(n / 200) + 1; const compressedBytes = Math.ceil(codes * 9 / 8); const frameBytes = 19 + 1 + compressedBytes + Math.ceil(compressedBytes / 255) + 1;
  const maximumOutputBytes = 13 + 768 + 19 + frames.length * frameBytes + 1; const memory = frames.length * n * 4 + maximumOutputBytes * 2 + compressedBytes + 1024 * 1024;
  if (!Number.isSafeInteger(memory) || memory > limits.maxWorkingBytes) fail('resource-limit', 'Animation frames exceed the local memory budget. Reduce dimensions, duration or frame rate.');
  const output = new Uint8Array(maximumOutputBytes); let offset = 0; const byte = (v: number) => { if (offset >= output.length) fail('invalid-animation', 'GIF size estimate exceeded.'); output[offset++] = v; }; const word = (v: number) => { byte(v & 255); byte(v >>> 8); }; const ascii = (s: string) => { for (const char of s) byte(char.charCodeAt(0)); };
  ascii('GIF89a'); word(width); word(height); byte(0xf7); byte(0); byte(0);
  for (let i = 0; i < 256; i++) { byte(Math.round(((i >>> 5) & 7) * 255 / 7)); byte(Math.round(((i >>> 2) & 7) * 255 / 7)); byte(Math.round((i & 3) * 255 / 3)); }
  byte(0x21); byte(0xff); byte(11); ascii('NETSCAPE2.0'); byte(3); byte(1); word(0); byte(0);
  for (const [frameIndex, frame] of frames.entries()) {
    checkAbort(options.signal); const delay = Math.max(1, Math.round((frameIndex + 1) * 100 / framesPerSecond) - Math.round(frameIndex * 100 / framesPerSecond));
    byte(0x21); byte(0xf9); byte(4); byte(4); word(delay); byte(0); byte(0); byte(0x2c); word(0); word(0); word(width); word(height); byte(0); byte(8);
    const compressed = new Uint8Array(compressedBytes); let compressedOffset = 0, accumulator = 0, bits = 0;
    const code = (value: number) => { accumulator |= value << bits; bits += 9; while (bits >= 8) { compressed[compressedOffset++] = accumulator & 255; accumulator >>>= 8; bits -= 8; } };
    // Reset before the decoder's dictionary reaches 512 entries; codes always
    // remain exactly nine bits. This favors bounded, portable decoding over size.
    for (let i = 0; i < n; i++) {
      if (i % 65_536 === 0) await yieldTask(options.signal); if (i % 200 === 0) code(256);
      const p = i * 4, alpha = frame.rgba[p + 3] / 255; const r = Math.round(frame.rgba[p] * alpha * 7 / 255), g = Math.round(frame.rgba[p + 1] * alpha * 7 / 255), b = Math.round(frame.rgba[p + 2] * alpha * 3 / 255); code((r << 5) | (g << 2) | b);
    }
    code(257); if (bits) compressed[compressedOffset++] = accumulator & 255;
    for (let i = 0; i < compressedOffset; i += 255) { const length = Math.min(255, compressedOffset - i); byte(length); for (let j = 0; j < length; j++) byte(compressed[i + j]); } byte(0);
    options.onProgress?.((frameIndex + 1) / frames.length);
  }
  byte(0x3b); checkAbort(options.signal); return output.slice(0, offset);
}
