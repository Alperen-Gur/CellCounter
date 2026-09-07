import type { CellDTO, DetectionDTO } from "../../kernel/types";
import type { SavedRun } from "../../kernel/workflow/workflowDocuments";

export const MAX_MASK_VERSIONS = 8;
export const MAX_VARIANT_BYTES = 16 * 1024 * 1024;
export interface MaskVersion {
  id: string;
  label: string;
  savedAt: string;
  detectorId: string;
  cells: CellDTO[];
  imageStats?: Record<string, number>;
  run: SavedRun | null;
  reviewPxPerUm: number;
}
export interface MaskVersionDocument { version: 1; imageId: string; versions: MaskVersion[] }

export function knownSavedRun(value: SavedRun | null, detection: DetectionDTO | null): SavedRun | null {
  return value?.version === 1 && !!detection && value.detectionId === detection.id
    && typeof value.runToken === "string" && value.runToken.length > 0 && typeof value.params?.modelId === "string"
    && Array.isArray(value.params.channels) && value.params.channels.length === 2
    && value.params.channels.every(Number.isFinite)
    && [value.params.confidenceThreshold, value.params.expectedDiameterUm, value.params.smallThresholdUm,
      value.params.largeThresholdUm, value.params.rollingBallRadius, value.params.watershedMinDistanceUm].every(Number.isFinite)
    && [value.params.backgroundSubtract, value.params.watershedSplit, value.params.useGpu].every(flag => typeof flag === "boolean")
    && typeof value.calibrationSource === "string" && ["countCells", "nuclei", "markerPositive", "woundClosure"].includes(value.task)
    && typeof value.ranAt === "string" && Number.isFinite(Date.parse(value.ranAt))
    && Number.isFinite(value.params.pxPerUm) && value.params.pxPerUm > 0 ? value : null;
}
export function readMaskVersions(value: MaskVersionDocument | null, imageId: string): MaskVersionDocument {
  if (!value) return { version: 1, imageId, versions: [] };
  if (value.version !== 1 || value.imageId !== imageId || !Array.isArray(value.versions)
    || value.versions.length > MAX_MASK_VERSIONS || !value.versions.every(validVersion)) {
    throw new Error("The saved mask versions could not be read. They have been left unchanged.");
  }
  return { ...value, versions: value.versions.map(version => ({ ...version,
    run: version.run ? knownSavedRun(version.run, { id: version.run.detectionId } as DetectionDTO) : null,
  })) };
}
function validVersion(version: MaskVersion): boolean {
  return !!version && typeof version.id === "string" && typeof version.label === "string"
    && typeof version.savedAt === "string" && Number.isFinite(Date.parse(version.savedAt))
    && typeof version.detectorId === "string" && Number.isFinite(version.reviewPxPerUm) && version.reviewPxPerUm > 0
    && Array.isArray(version.cells) && version.cells.every(cell => !!cell && typeof cell.id === "string"
      && [cell.cx, cell.cy, cell.diameterPx, cell.diameterUm, cell.confidence].every(Number.isFinite)
      && (cell.contourPx === undefined || Array.isArray(cell.contourPx) && cell.contourPx.every(point =>
        Array.isArray(point) && point.length === 2 && point.every(Number.isFinite))));
}
export function appendMaskVersion(document: MaskVersionDocument, version: MaskVersion): MaskVersionDocument {
  if (document.versions.length >= MAX_MASK_VERSIONS) throw new Error("This image has eight saved versions. Remove a saved version you no longer need before saving or restoring another.");
  const next = { ...document, versions: [...document.versions, version] };
  if (new TextEncoder().encode(JSON.stringify(next)).byteLength > MAX_VARIANT_BYTES) {
    throw new Error("These masks exceed the 16 MiB version-storage limit. Remove an existing saved version before adding another; large masks may need an external export.");
  }
  return next;
}

/** Replace masks without ever leaving the previous run's provenance attached.
 * Refresh even after a partial metadata failure so the editor cannot overwrite
 * a successful mask replacement with its old in-memory cells. */
export async function replaceMasksWithProvenance(
  version: Pick<MaskVersion, "cells" | "detectorId" | "imageStats" | "run">,
  ports: {
    assertWritable(): void;
    deleteRun(): Promise<void>;
    saveDetection(detectorId: string, cells: CellDTO[], stats?: Record<string, number>): Promise<DetectionDTO>;
    saveRun(run: SavedRun): Promise<void>;
    refresh(): Promise<void>;
    newToken(): string;
  },
): Promise<void> {
  ports.assertWritable();
  await ports.deleteRun();
  try {
    ports.assertWritable();
    const saved = await ports.saveDetection(version.detectorId, version.cells, version.imageStats);
    if (version.run) await ports.saveRun({ ...version.run, detectionId: saved.id, runToken: ports.newToken() });
  } finally { await ports.refresh(); }
}
