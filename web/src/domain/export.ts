import type { AnalysisProvenance, CellMeasurement, ImageAnalysis } from "./types";

function sortedValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortedValue);
  if (value && typeof value === "object" && !(value instanceof Blob)) {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
        .map(([key, nested]) => [key, sortedValue(nested)]),
    );
  }
  if (typeof value === "number" && !Number.isFinite(value)) return null;
  return value;
}

export function deterministicJson(value: unknown, space = 2): string {
  return `${JSON.stringify(sortedValue(value), null, space)}\n`;
}

function csvField(value: string | number | boolean): string {
  const text = typeof value === "number" ? (Number.isFinite(value) ? `${value}` : "") : `${value}`;
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

const CELL_COLUMNS: readonly (keyof CellMeasurement | "centroid_x_px" | "centroid_y_px")[] = [
  "id",
  "origin",
  "confidence",
  "centroid_x_px",
  "centroid_y_px",
  "areaPx2",
  "areaUm2",
  "perimeterPx",
  "perimeterUm",
  "equivalentDiameterPx",
  "equivalentDiameterUm",
  "circularity",
  "eccentricity",
  "aspectRatio",
  "solidity",
  "edgeTouching",
  "sizeClass",
];

function provenanceHeader(provenance: AnalysisProvenance): string[] {
  return [
    `# schema: cellcounter.cells.v1`,
    `# app_version: ${provenance.appVersion}`,
    `# app_build: ${provenance.appBuild}`,
    ...(provenance.buildSha ? [`# build_sha: ${provenance.buildSha}`] : []),
    `# exported_at: ${provenance.exportedAt}`,
    `# image_sha256: ${provenance.imageSha256}`,
    `# model_id: ${provenance.model.id}`,
    `# model_manifest_version: ${provenance.model.manifestVersion}`,
    `# model_artifact_sha256: ${provenance.model.artifactSha256}`,
    `# runtime: ${provenance.model.runtime}@${provenance.model.runtimeVersion}`,
    `# px_per_um: ${provenance.calibration.pxPerUm}`,
    `# calibration_source: ${provenance.calibration.source}`,
    `# parameters_json: ${JSON.stringify(sortedValue(provenance.parameters))}`,
  ];
}

export function exportCellsCsv(analysis: ImageAnalysis, provenance: AnalysisProvenance): string {
  const rows = [...analysis.cells]
    .sort((left, right) => (left.id < right.id ? -1 : left.id > right.id ? 1 : 0))
    .map((cell) => {
      const values: Record<string, string | number | boolean> = {
        ...cell,
        centroid_x_px: cell.centroidPx.x,
        centroid_y_px: cell.centroidPx.y,
      } as unknown as Record<string, string | number | boolean>;
      return CELL_COLUMNS.map((column) => csvField(values[column])).join(",");
    });
  return [...provenanceHeader(provenance), CELL_COLUMNS.join(","), ...rows].join("\n") + "\n";
}

export function exportAnalysisJson(analysis: ImageAnalysis, provenance: AnalysisProvenance): string {
  const { displayPlane: _displayPlane, ...record } = analysis;
  return deterministicJson({ analysis: record, provenance });
}

export function createExportBlob(contents: string, mediaType: string): Blob {
  return new Blob([contents], { type: `${mediaType};charset=utf-8` });
}
