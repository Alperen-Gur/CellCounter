import { gaussianBlur, mean, sampleStandardDeviation } from "./math";
import { assertAligned, type LabelMap, type Raster } from "./types";

export interface Punctum {
  readonly id: string;
  readonly xPx: number;
  readonly yPx: number;
  readonly response: number;
  readonly meanIntensity: number;
  readonly integratedIntensity: number;
  readonly areaPx: number;
  readonly assignedCellLabel: number | null;
}

export interface PunctaResult {
  readonly spots: readonly Punctum[];
  readonly perCell: readonly { readonly cellLabel: number; readonly spotCount: number; readonly meanSpotIntensity: number | null }[];
  readonly threshold: number;
  readonly method: "difference-of-gaussians";
}

/** Deterministic DoG local-maximum detector with label-map assignment. */
export function detectPuncta(
  image: Raster,
  labels: LabelMap,
  options: {
    readonly channel?: number;
    readonly sigmaSmallPx?: number;
    readonly sigmaLargePx?: number;
    readonly threshold?: number;
    readonly thresholdStandardDeviations?: number;
    readonly integrationRadiusPx?: number;
    readonly minimumDistancePx?: number;
  } = {},
): PunctaResult {
  assertAligned(labels, image);
  const channel = options.channel ?? 0;
  if (channel < 0 || channel >= image.channels) throw new RangeError("Puncta channel is outside the raster.");
  const small = options.sigmaSmallPx ?? 1;
  const large = options.sigmaLargePx ?? 2;
  if (!(small > 0) || !(large > small)) throw new RangeError("DoG requires 0 < sigmaSmall < sigmaLarge.");
  const plane = new Float64Array(labels.data.length);
  for (let pixel = 0; pixel < plane.length; pixel += 1) plane[pixel] = Number(image.data[pixel * image.channels + channel]);
  const lowBlur = gaussianBlur(plane, image.width, image.height, small);
  const highBlur = gaussianBlur(plane, image.width, image.height, large);
  // Reuse the first blur buffer as the response to avoid another full-frame allocation.
  const response = lowBlur;
  for (let index = 0; index < response.length; index += 1) response[index] -= highBlur[index];
  const threshold = options.threshold ?? ((mean(response) ?? 0) + (options.thresholdStandardDeviations ?? 3) * (sampleStandardDeviation(response) ?? 0));
  if (!Number.isFinite(threshold)) throw new RangeError("Puncta threshold must be finite.");
  const candidates: { x: number; y: number; value: number }[] = [];
  for (let y = 1; y < image.height - 1; y += 1) {
    for (let x = 1; x < image.width - 1; x += 1) {
      const index = y * image.width + x;
      const value = response[index];
      if (!(value > threshold)) continue;
      let maximum = true;
      for (let dy = -1; dy <= 1 && maximum; dy += 1) for (let dx = -1; dx <= 1; dx += 1) {
        if ((dx || dy) && response[(y + dy) * image.width + x + dx] > value) { maximum = false; break; }
      }
      if (maximum) candidates.push({ x, y, value });
    }
  }
  candidates.sort((a, b) => b.value - a.value || a.y - b.y || a.x - b.x);
  const accepted: typeof candidates = [];
  const minimumDistanceSquared = (options.minimumDistancePx ?? Math.max(1, small)) ** 2;
  for (const candidate of candidates) {
    if (accepted.every((spot) => (spot.x - candidate.x) ** 2 + (spot.y - candidate.y) ** 2 >= minimumDistanceSquared)) accepted.push(candidate);
  }
  accepted.sort((a, b) => a.y - b.y || a.x - b.x);
  const radius = Math.max(0, Math.ceil(options.integrationRadiusPx ?? small));
  const spots = accepted.map((spot, spotIndex): Punctum => {
    let sum = 0; let count = 0;
    for (let dy = -radius; dy <= radius; dy += 1) for (let dx = -radius; dx <= radius; dx += 1) {
      const x = spot.x + dx; const y = spot.y + dy;
      if (x < 0 || x >= image.width || y < 0 || y >= image.height || dx * dx + dy * dy > radius * radius) continue;
      sum += plane[y * image.width + x]; count += 1;
    }
    const label = labels.data[spot.y * labels.width + spot.x];
    return { id: `punctum-${spotIndex + 1}`, xPx: spot.x, yPx: spot.y, response: spot.value, meanIntensity: count ? sum / count : 0, integratedIntensity: sum, areaPx: count, assignedCellLabel: label || null };
  });
  const cellLabelSet = new Set<number>();
  for (let index = 0; index < labels.data.length; index += 1) if (labels.data[index]) cellLabelSet.add(labels.data[index]);
  const cellLabels = [...cellLabelSet].sort((a, b) => a - b);
  const perCell = cellLabels.map((cellLabel) => {
    const owned = spots.filter(({ assignedCellLabel }) => assignedCellLabel === cellLabel);
    return { cellLabel, spotCount: owned.length, meanSpotIntensity: mean(owned.map(({ meanIntensity }) => meanIntensity)) };
  });
  return { spots, perCell, threshold, method: "difference-of-gaussians" };
}
