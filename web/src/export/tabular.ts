import type { ExportCell, ExportPoint } from "./types";

function normalized(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(normalized);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([key, entry]) => [key, normalized(entry)]));
  if (typeof value === "number" && !Number.isFinite(value)) throw new RangeError("JSON export does not permit non-finite numbers.");
  return value;
}
export function deterministicJson(value: unknown): string { return `${JSON.stringify(normalized(value), null, 2)}\n`; }

function csvField(value: unknown): string {
  const text = value === null || value === undefined ? "" : String(value);
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

export function exportCellsCsv(cells: readonly ExportCell[], provenance: Readonly<Record<string, unknown>> = {}): string {
  const comments = Object.entries(provenance).sort(([a], [b]) => a.localeCompare(b)).map(([key, value]) => `# ${key}: ${typeof value === "object" ? JSON.stringify(normalized(value)) : String(value)}`);
  const header = ["id", "centroid_x_px", "centroid_y_px", "diameter_px", "diameter_um", "confidence", "is_manual"];
  const rows = [...cells].sort((a, b) => a.id.localeCompare(b.id)).map((cell) => [cell.id, cell.cx, cell.cy, cell.diameterPx, cell.diameterUm, cell.confidence, Boolean(cell.isManual)].map(csvField).join(","));
  return [...comments, header.join(","), ...rows].join("\n") + "\n";
}

export interface RoiData { readonly schemaVersion: 1; readonly coordinateSpace: "source-pixels"; readonly regions: readonly { readonly id: string; readonly mode: "include" | "exclude"; readonly points: readonly ExportPoint[] }[] }
export function exportRoiData(regions: RoiData["regions"]): string {
  return deterministicJson({ schemaVersion: 1, coordinateSpace: "source-pixels", regions: [...regions].sort((a, b) => a.id.localeCompare(b.id)) });
}

export function exportProvenance(provenance: Readonly<Record<string, unknown>>): string {
  return deterministicJson({ schemaVersion: 1, provenance });
}
