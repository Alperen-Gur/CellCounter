/** Portable, local preprocessing. Original source samples are never modified. */
export type PreprocessingPreset = "none" | "clahe" | "anisotropicDiffusion" | "claheAndDiffusion";

const MAX_PIXELS = 4_000_000;
const BINS = 256;

function checkAbort(signal?: AbortSignal): void {
  if (signal?.aborted) throw new DOMException("Preprocessing cancelled", "AbortError");
}

async function yieldTask(signal?: AbortSignal): Promise<void> {
  checkAbort(signal);
  await new Promise<void>((resolve) => setTimeout(resolve, 0));
  checkAbort(signal);
}

/**
 * Perona–Malik diffusion on normalized samples, using the same ten iterations,
 * conductance and time step as the native CPU path. Edges use zero flux.
 */
async function diffuse(input: Float32Array, width: number, height: number, signal?: AbortSignal): Promise<Float32Array> {
  let current = input;
  let next = new Float32Array(input.length);
  const flux = (difference: number) => difference * Math.exp(-((difference / 0.1) ** 2));
  for (let iteration = 0; iteration < 10; iteration++) {
    for (let y = 0; y < height; y++) {
      const offset = y * width;
      for (let x = 0; x < width; x++) {
        const i = offset + x;
        if (i % 16_384 === 0) await yieldTask(signal);
        const center = current[i];
        const update = (y ? flux(current[i - width] - center) : 0)
          + (y + 1 < height ? flux(current[i + width] - center) : 0)
          + (x ? flux(current[i - 1] - center) : 0)
          + (x + 1 < width ? flux(current[i + 1] - center) : 0);
        next[i] = Math.max(0, Math.min(1, center + 0.16 * update));
      }
    }
    [current, next] = [next, current];
  }
  return current;
}

interface AxisBlend { low: Uint8Array; high: Uint8Array; weight: Float32Array; }

async function axisBlend(length: number, tileSize: number, tiles: number, signal?: AbortSignal): Promise<AxisBlend> {
  const centers = Array.from({ length: tiles }, (_, i) => (i * tileSize + Math.min(length, (i + 1) * tileSize) - 1) / 2);
  const low = new Uint8Array(length);
  const high = new Uint8Array(length);
  const weight = new Float32Array(length);
  let upper = 0;
  for (let p = 0; p < length; p++) {
    if (p % 65_536 === 0) await yieldTask(signal);
    while (upper + 1 < tiles && centers[upper] < p) upper++;
    const lower = p <= centers[0] ? 0 : Math.max(0, upper - 1);
    low[p] = lower;
    high[p] = upper;
    weight[p] = lower === upper ? 0 : Math.max(0, Math.min(1, (p - centers[lower]) / (centers[upper] - centers[lower])));
  }
  return { low, high, weight };
}

/**
 * Contrast-limited adaptive histogram equalization: up to 8×8 tiles, 256 bins,
 * 2% clip limit and bilinear tile interpolation. This portable implementation
 * is an explicit adaptation, not a bit-for-bit reproduction of scikit-image.
 */
async function clahe(input: Float32Array, width: number, height: number, signal?: AbortSignal): Promise<Float32Array> {
  const tileWidth = Math.ceil(width / 8);
  const tileHeight = Math.ceil(height / 8);
  const tilesX = Math.ceil(width / tileWidth);
  const tilesY = Math.ceil(height / tileHeight);
  const lookup = new Float32Array(tilesX * tilesY * BINS);
  const histogram = new Uint32Array(BINS);
  for (let ty = 0; ty < tilesY; ty++) {
    for (let tx = 0; tx < tilesX; tx++) {
      await yieldTask(signal);
      histogram.fill(0);
      const x0 = tx * tileWidth, x1 = Math.min(width, x0 + tileWidth);
      const y0 = ty * tileHeight, y1 = Math.min(height, y0 + tileHeight);
      const count = (x1 - x0) * (y1 - y0);
      for (let y = y0; y < y1; y++) {
        for (let x = x0; x < x1; x++) histogram[Math.min(BINS - 1, Math.floor(input[y * width + x] * (BINS - 1)))]++;
      }
      const limit = Math.max(1, Math.ceil(count * 0.02));
      let excess = 0;
      for (let bin = 0; bin < BINS; bin++) {
        excess += Math.max(0, histogram[bin] - limit);
        histogram[bin] = Math.min(histogram[bin], limit);
      }
      // Redistribute all clipped counts without exceeding the clip limit.
      // Capacity is sufficient because the 2% limit exceeds 1 / 256.
      while (excess > 0) {
        const share = Math.max(1, Math.floor(excess / BINS));
        for (let bin = 0; bin < BINS && excess > 0; bin++) {
          const added = Math.min(limit - histogram[bin], share, excess);
          histogram[bin] += added;
          excess -= added;
        }
      }
      let cumulative = 0;
      const offset = (ty * tilesX + tx) * BINS;
      for (let bin = 0; bin < BINS; bin++) {
        cumulative += histogram[bin];
        lookup[offset + bin] = cumulative / count;
      }
    }
  }
  const horizontal = await axisBlend(width, tileWidth, tilesX, signal);
  const vertical = await axisBlend(height, tileHeight, tilesY, signal);
  const output = new Float32Array(input.length);
  for (let y = 0; y < height; y++) {
    const top = vertical.low[y] * tilesX;
    const bottom = vertical.high[y] * tilesX;
    const fy = vertical.weight[y];
    for (let x = 0; x < width; x++) {
      const i = y * width + x;
      if (i % 65_536 === 0) await yieldTask(signal);
      const bin = Math.min(BINS - 1, Math.floor(input[i] * (BINS - 1)));
      const left = horizontal.low[x], right = horizontal.high[x], fx = horizontal.weight[x];
      const upper = lookup[(top + left) * BINS + bin] * (1 - fx) + lookup[(top + right) * BINS + bin] * fx;
      const lower = lookup[(bottom + left) * BINS + bin] * (1 - fx) + lookup[(bottom + right) * BINS + bin] * fx;
      output[i] = upper * (1 - fy) + lower * fy;
    }
  }
  return output;
}

/** Process one source plane within a fixed memory budget and retain its range. */
export async function applyPreprocessing(
  values: Float32Array, width: number, height: number,
  preset: PreprocessingPreset, signal?: AbortSignal,
): Promise<Float32Array> {
  checkAbort(signal);
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width < 1 || height < 1
    || width > MAX_PIXELS / height || values.length !== width * height) {
    throw new RangeError("Preprocessing requires a matching source plane of at most four million pixels.");
  }
  if (!["none", "clahe", "anisotropicDiffusion", "claheAndDiffusion"].includes(preset)) {
    throw new RangeError("Unknown preprocessing preset.");
  }
  let low = Infinity, high = -Infinity;
  for (let i = 0; i < values.length; i++) {
    if (i % 65_536 === 0) await yieldTask(signal);
    const sample = values[i];
    if (!Number.isFinite(sample)) throw new RangeError("Preprocessing cannot use non-finite source intensities.");
    low = Math.min(low, sample); high = Math.max(high, sample);
  }
  if (preset === "none" || high === low) return values.slice();
  // JavaScript double arithmetic prevents overflow of extreme finite Float32 ranges.
  const range = high - low;
  let output = new Float32Array(values.length);
  for (let i = 0; i < output.length; i++) {
    if (i % 65_536 === 0) await yieldTask(signal);
    output[i] = (values[i] - low) / range;
  }
  if (preset === "anisotropicDiffusion" || preset === "claheAndDiffusion") output = await diffuse(output, width, height, signal);
  if (preset === "clahe" || preset === "claheAndDiffusion") output = await clahe(output, width, height, signal);
  for (let i = 0; i < output.length; i++) {
    if (i % 65_536 === 0) await yieldTask(signal);
    output[i] = Math.max(low, Math.min(high, output[i] * range + low));
  }
  checkAbort(signal);
  return output;
}
