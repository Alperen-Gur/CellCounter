export function mean(values: ArrayLike<number>): number | null {
  if (!values.length) return null;
  let sum = 0;
  for (let index = 0; index < values.length; index += 1) sum += values[index];
  return sum / values.length;
}

export function sampleStandardDeviation(values: ArrayLike<number>): number | null {
  if (values.length < 2) return values.length === 1 ? 0 : null;
  const average = mean(values)!;
  let squareSum = 0;
  for (let index = 0; index < values.length; index += 1) squareSum += (values[index] - average) ** 2;
  return Math.sqrt(squareSum / (values.length - 1));
}

export function median(values: ArrayLike<number>): number | null {
  if (!values.length) return null;
  const sorted = Array.from(values).sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

export function percentile(values: ArrayLike<number>, p: number): number | null {
  if (!values.length) return null;
  const sorted = Array.from(values).sort((a, b) => a - b);
  const position = Math.max(0, Math.min(1, p / 100)) * (sorted.length - 1);
  const lower = Math.floor(position);
  const fraction = position - lower;
  return sorted[lower] + fraction * ((sorted[lower + 1] ?? sorted[lower]) - sorted[lower]);
}

/** Otsu split with midpoint refinement, matching the macOS/Python assay engine. */
export function otsuThreshold(input: ArrayLike<number>, bins = 256): number | null {
  let finiteCount = 0;
  let minimum = Infinity;
  let maximum = -Infinity;
  for (let inputIndex = 0; inputIndex < input.length; inputIndex += 1) {
    const value = input[inputIndex];
    if (!Number.isFinite(value)) continue;
    finiteCount += 1;
    if (value < minimum) minimum = value;
    if (value > maximum) maximum = value;
  }
  if (finiteCount < 2) return null;
  if (!(maximum > minimum)) return null;
  const count = Math.max(2, Math.trunc(bins));
  const width = (maximum - minimum) / count;
  const histogram = new Float64Array(count);
  for (let inputIndex = 0; inputIndex < input.length; inputIndex += 1) {
    const value = input[inputIndex];
    if (!Number.isFinite(value)) continue;
    const index = Math.max(0, Math.min(count - 1, Math.floor((value - minimum) / width)));
    histogram[index] += 1;
  }
  let totalSum = 0;
  for (let index = 0; index < count; index += 1) {
    totalSum += histogram[index] * (minimum + (index + 0.5) * width);
  }
  let lowWeight = 0;
  let lowSum = 0;
  let bestVariance = -1;
  let bestIndex = -1;
  for (let index = 0; index < count - 1; index += 1) {
    const center = minimum + (index + 0.5) * width;
    lowWeight += histogram[index];
    lowSum += histogram[index] * center;
    const highWeight = finiteCount - lowWeight;
    if (lowWeight <= 0 || highWeight <= 0) continue;
    const lowMean = lowSum / lowWeight;
    const highMean = (totalSum - lowSum) / highWeight;
    const variance = lowWeight * highWeight * (lowMean - highMean) ** 2;
    if (variance > bestVariance) {
      bestVariance = variance;
      bestIndex = index;
    }
  }
  if (bestIndex < 0 || bestVariance <= 0) return null;
  const boundary = minimum + (bestIndex + 1) * width;
  let lowMaximum = -Infinity;
  let highMinimum = Infinity;
  for (let inputIndex = 0; inputIndex < input.length; inputIndex += 1) {
    const value = input[inputIndex];
    if (!Number.isFinite(value)) continue;
    if (value <= boundary && value > lowMaximum) lowMaximum = value;
    if (value > boundary && value < highMinimum) highMinimum = value;
  }
  return Number.isFinite(lowMaximum) && Number.isFinite(highMinimum)
    ? (lowMaximum + highMinimum) / 2
    : minimum + (bestIndex + 0.5) * width;
}

export function pearson(a: ArrayLike<number>, b: ArrayLike<number>): number | null {
  if (a.length !== b.length || a.length < 2) return null;
  const aMean = mean(a)!;
  const bMean = mean(b)!;
  let numerator = 0;
  let aa = 0;
  let bb = 0;
  for (let index = 0; index < a.length; index += 1) {
    const da = a[index] - aMean;
    const db = b[index] - bMean;
    numerator += da * db;
    aa += da * da;
    bb += db * db;
  }
  const denominator = Math.sqrt(aa * bb);
  return denominator > 0 ? numerator / denominator : null;
}

export interface Component {
  readonly label: number;
  readonly pixels: Uint32Array;
  readonly minX: number;
  readonly minY: number;
  readonly maxX: number;
  readonly maxY: number;
}

export function connectedComponents(mask: ArrayLike<number>, width: number, height: number, diagonal = true, signal?: AbortSignal): Component[] {
  if (mask.length !== width * height || width <= 0 || height <= 0) throw new RangeError("Invalid binary-mask dimensions.");
  const seen = new Uint8Array(mask.length);
  const components: Component[] = [];
  // Reuse one fixed-capacity queue across components; do not allocate a full
  // image queue for each connected region.
  const queue = new Uint32Array(mask.length);
  const neighbors = diagonal
    ? [[-1, -1], [0, -1], [1, -1], [-1, 0], [1, 0], [-1, 1], [0, 1], [1, 1]]
    : [[0, -1], [-1, 0], [1, 0], [0, 1]];
  for (let start = 0; start < mask.length; start += 1) {
    if ((start & 0xffff) === 0) signal?.throwIfAborted();
    if (!mask[start] || seen[start]) continue;
    // A typed queue avoids retaining a second boxed-number array for every
    // foreground pixel while the component's result pixels are accumulated.
    let queueLength = 1;
    queue[0] = start;
    seen[start] = 1;
    let minX = width;
    let minY = height;
    let maxX = 0;
    let maxY = 0;
    for (let cursor = 0; cursor < queueLength; cursor += 1) {
      if ((cursor & 0xffff) === 0) signal?.throwIfAborted();
      const index = queue[cursor];
      const x = index % width;
      const y = Math.floor(index / width);
      minX = Math.min(minX, x); maxX = Math.max(maxX, x);
      minY = Math.min(minY, y); maxY = Math.max(maxY, y);
      for (const [dx, dy] of neighbors) {
        const nx = x + dx;
        const ny = y + dy;
        if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
        const next = ny * width + nx;
        if (mask[next] && !seen[next]) { seen[next] = 1; queue[queueLength] = next; queueLength += 1; }
      }
    }
    components.push({ label: components.length + 1, pixels: queue.slice(0, queueLength), minX, minY, maxX, maxY });
  }
  return components;
}

export function gaussianKernel(sigma: number): Float64Array {
  if (!(sigma > 0)) return new Float64Array([1]);
  const radius = Math.max(1, Math.ceil(sigma * 3));
  const kernel = new Float64Array(radius * 2 + 1);
  let sum = 0;
  for (let offset = -radius; offset <= radius; offset += 1) {
    const value = Math.exp(-(offset * offset) / (2 * sigma * sigma));
    kernel[offset + radius] = value;
    sum += value;
  }
  for (let index = 0; index < kernel.length; index += 1) kernel[index] /= sum;
  return kernel;
}

export function gaussianBlur(input: ArrayLike<number>, width: number, height: number, sigma: number): Float64Array {
  if (input.length !== width * height) throw new RangeError("Invalid plane dimensions.");
  const kernel = gaussianKernel(sigma);
  const radius = Math.floor(kernel.length / 2);
  const horizontal = new Float64Array(input.length);
  const output = new Float64Array(input.length);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      let value = 0;
      for (let k = -radius; k <= radius; k += 1) {
        const sampleX = Math.max(0, Math.min(width - 1, x + k));
        value += Number(input[y * width + sampleX]) * kernel[k + radius];
      }
      horizontal[y * width + x] = value;
    }
  }
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      let value = 0;
      for (let k = -radius; k <= radius; k += 1) {
        const sampleY = Math.max(0, Math.min(height - 1, y + k));
        value += horizontal[sampleY * width + x] * kernel[k + radius];
      }
      output[y * width + x] = value;
    }
  }
  return output;
}
