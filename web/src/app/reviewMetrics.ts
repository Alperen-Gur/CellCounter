import type { WorkspaceImage } from "./types";

/** Risk is a triage heuristic, never a learned model confidence or QC verdict. */
export function imageReviewRisk(image: WorkspaceImage): { score: number; reasons: string[] } {
  const reasons: string[] = [];
  let score = image.reviewConfidence === "low" ? 30 : image.reviewConfidence === "medium" ? 12 : 0;
  if (score) reasons.push(`${image.reviewConfidence} reviewer confidence`);
  const cells = image.cells;
  const uncertain = image.modelId === "classical" ? 0 : cells.filter((cell) => !cell.reviewed && cell.confidence < .65).length;
  if (uncertain) { score += 35 * uncertain / Math.max(1, cells.length); reasons.push(`${uncertain} low-confidence objects`); }
  const edge = cells.filter((cell) => cell.cx - cell.diameterPx / 2 <= 0 || cell.cy - cell.diameterPx / 2 <= 0 || cell.cx + cell.diameterPx / 2 >= image.width || cell.cy + cell.diameterPx / 2 >= image.height).length;
  if (edge) { score += 15 * edge / Math.max(1, cells.length); reasons.push(`${edge} possible edge objects`); }
  const diameters = cells.map((cell) => cell.diameterPx).sort((a, b) => a - b);
  const median = diameters[Math.floor(diameters.length / 2)] ?? 0;
  const atypical = cells.filter((cell) => median > 0 && (cell.diameterPx > median * 2 || cell.diameterPx < median * .35)).length;
  if (atypical) { score += 20 * atypical / Math.max(1, cells.length); reasons.push(`${atypical} atypical sizes`); }
  if (!image.calibrationSource || image.calibrationSource === "default") { score += 10; reasons.push("calibration unverified"); }
  if (!cells.length) reasons.push("no result objects");
  return { score: Math.min(100, Math.round(score)), reasons };
}
