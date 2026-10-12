import type { IdentifiedPoint } from "./types";

export interface GroundTruthMatch {
  readonly truthId: string;
  readonly detectionId: string;
  readonly distancePx: number;
}
export interface GroundTruthMetrics {
  readonly truePositive: number;
  readonly falsePositive: number;
  readonly falseNegative: number;
  readonly precision: number;
  readonly recall: number;
  readonly f1: number;
  readonly matches: readonly GroundTruthMatch[];
  readonly unmatchedTruthIds: readonly string[];
  readonly unmatchedDetectionIds: readonly string[];
}

/** Maximum-cardinality one-to-one matching, preferring shorter eligible edges deterministically. */
export function matchGroundTruth(truth: readonly IdentifiedPoint[], detections: readonly IdentifiedPoint[], tolerancePx: number): GroundTruthMetrics {
  if (!(tolerancePx >= 0) || !Number.isFinite(tolerancePx)) throw new RangeError("Ground-truth tolerance must be finite and non-negative.");
  if (truth.length + detections.length > 100_000 || truth.length * detections.length > 1_000_000) throw new RangeError("Ground-truth matching exceeds one million point pairs. Evaluate a smaller region or fewer reference objects.");
  for (const points of [truth, detections]) for (const point of points) if (typeof point.id !== "string" || point.id.length > 512 || !Number.isFinite(point.x) || !Number.isFinite(point.y) || Math.abs(point.x) > 1e9 || Math.abs(point.y) > 1e9) throw new RangeError("Ground-truth points require bounded ids and finite source coordinates.");
  if (new Set(truth.map(({ id }) => id)).size !== truth.length || new Set(detections.map(({ id }) => id)).size !== detections.length) throw new RangeError("Ground-truth and detection ids must be unique within each set.");
  const adjacency = truth.map((point) => detections.map((detection, index) => ({ index, distance: Math.hypot(point.x - detection.x, point.y - detection.y) }))
    .filter(({ distance }) => distance <= tolerancePx).sort((a, b) => a.distance - b.distance || detections[a.index].id.localeCompare(detections[b.index].id)));
  const detectionToTruth = new Int32Array(detections.length); detectionToTruth.fill(-1);
  // Iterative augmenting paths preserve maximum cardinality without recursion
  // proportional to the number of objects. An epoch array avoids per-root fills.
  const seen = new Uint32Array(detections.length);
  let work = 0;
  for (let truthIndex = 0; truthIndex < truth.length; truthIndex += 1) {
    const epoch = truthIndex + 1, stack = [truthIndex], offsets = [0], path: number[] = [];
    while (stack.length) {
      const depth = stack.length - 1, candidates = adjacency[stack[depth]];
      if (offsets[depth] >= candidates.length) { stack.pop(); offsets.pop(); path.pop(); continue; }
      if (++work > 5_000_000) throw new RangeError("Dense ground-truth matching exceeds five million edge visits. Evaluate a smaller region or tighter tolerance.");
      const { index } = candidates[offsets[depth]++];
      if (seen[index] === epoch) continue;
      seen[index] = epoch;
      const owner = detectionToTruth[index];
      if (owner < 0) {
        detectionToTruth[index] = stack[depth];
        for (let at = depth - 1; at >= 0; at--) detectionToTruth[path[at]] = stack[at];
        break;
      }
      path.push(index); stack.push(owner); offsets.push(0);
    }
  }
  const matches = Array.from(detectionToTruth.entries()).flatMap(([detectionIndex, truthIndex]) => truthIndex < 0 ? [] : [{
    truthId: truth[truthIndex].id,
    detectionId: detections[detectionIndex].id,
    distancePx: Math.hypot(truth[truthIndex].x - detections[detectionIndex].x, truth[truthIndex].y - detections[detectionIndex].y),
  }]).sort((a, b) => a.truthId.localeCompare(b.truthId));
  const matchedTruth = new Set(matches.map(({ truthId }) => truthId));
  const matchedDetections = new Set(matches.map(({ detectionId }) => detectionId));
  const truePositive = matches.length; const falsePositive = detections.length - truePositive; const falseNegative = truth.length - truePositive;
  const precision = truePositive + falsePositive ? truePositive / (truePositive + falsePositive) : 0;
  const recall = truePositive + falseNegative ? truePositive / (truePositive + falseNegative) : 0;
  return {
    truePositive, falsePositive, falseNegative, precision, recall, f1: precision + recall ? 2 * precision * recall / (precision + recall) : 0,
    matches,
    unmatchedTruthIds: truth.filter(({ id }) => !matchedTruth.has(id)).map(({ id }) => id),
    unmatchedDetectionIds: detections.filter(({ id }) => !matchedDetections.has(id)).map(({ id }) => id),
  };
}
