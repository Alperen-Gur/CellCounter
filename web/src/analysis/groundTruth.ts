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
  if (new Set(truth.map(({ id }) => id)).size !== truth.length || new Set(detections.map(({ id }) => id)).size !== detections.length) throw new RangeError("Ground-truth and detection ids must be unique within each set.");
  const adjacency = truth.map((point) => detections.map((detection, index) => ({ index, distance: Math.hypot(point.x - detection.x, point.y - detection.y) }))
    .filter(({ distance }) => distance <= tolerancePx).sort((a, b) => a.distance - b.distance || detections[a.index].id.localeCompare(detections[b.index].id)));
  const detectionToTruth = new Int32Array(detections.length); detectionToTruth.fill(-1);
  const visit = (truthIndex: number, seen: Uint8Array): boolean => {
    for (const { index } of adjacency[truthIndex]) {
      if (seen[index]) continue;
      seen[index] = 1;
      if (detectionToTruth[index] < 0 || visit(detectionToTruth[index], seen)) { detectionToTruth[index] = truthIndex; return true; }
    }
    return false;
  };
  for (let truthIndex = 0; truthIndex < truth.length; truthIndex += 1) visit(truthIndex, new Uint8Array(detections.length));
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
