/// <reference lib="webworker" />
import { buildBareSegmentationNpyPayload, buildPdfReport, exportAnnotatedPng, exportCellsGeoJson, exportImageJRoiZip, exportSegmentationMaskPng, type ExportCell } from "../export";

export type WorkspaceArtifactKind = "annotated-png" | "mask-png" | "bare-npy" | "imagej-roi" | "geojson" | "pdf";
export interface WorkspaceExportRequest {
  readonly id: string;
  readonly kind: WorkspaceArtifactKind;
  readonly source?: Blob;
  readonly cells: readonly ExportCell[];
  readonly width: number;
  readonly height: number;
  readonly title: string;
  readonly provenance: Readonly<Record<string, unknown>>;
}

export function workspaceExportNeedsLabelMap(kind: WorkspaceArtifactKind): boolean {
  return kind === "mask-png" || kind === "bare-npy";
}

function pointInPolygon(x: number, y: number, points: readonly { x: number; y: number }[]): boolean {
  let inside = false;
  for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
    const a = points[i]; const b = points[j];
    if ((a.y > y) !== (b.y > y) && x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x) inside = !inside;
  }
  return inside;
}

function contours(cell: ExportCell): { x: number; y: number }[] {
  if (cell.contourPx?.length) return cell.contourPx.map((point) => Array.isArray(point) ? { x: point[0], y: point[1] } : point as { x: number; y: number });
  const radius = cell.diameterPx / 2;
  return Array.from({ length: 32 }, (_, index) => ({ x: cell.cx + Math.cos(index / 32 * Math.PI * 2) * radius, y: cell.cy + Math.sin(index / 32 * Math.PI * 2) * radius }));
}

function labelMap(cells: readonly ExportCell[], width: number, height: number): Uint32Array {
  const estimated = width * height * 12;
  if (!Number.isSafeInteger(width * height) || width <= 0 || height <= 0 || estimated > 384 * 1024 * 1024) throw new Error("Mask export exceeds the 384 MB browser working-set budget. Crop the image or export table/ROI geometry instead.");
  const labels = new Uint32Array(width * height);
  cells.forEach((cell, cellIndex) => {
    const polygon = contours(cell); let minX = Infinity; let maxX = -Infinity; let minY = Infinity; let maxY = -Infinity;
    for (const point of polygon) { minX = Math.min(minX, point.x); maxX = Math.max(maxX, point.x); minY = Math.min(minY, point.y); maxY = Math.max(maxY, point.y); }
    for (let y = Math.max(0, Math.floor(minY)); y <= Math.min(height - 1, Math.ceil(maxY)); y += 1) for (let x = Math.max(0, Math.floor(minX)); x <= Math.min(width - 1, Math.ceil(maxX)); x += 1) if (pointInPolygon(x + .5, y + .5, polygon)) labels[y * width + x] = cellIndex + 1;
  });
  return labels;
}

async function artifact(request: WorkspaceExportRequest): Promise<{ bytes: Uint8Array; sidecar?: string }> {
  if (request.kind === "imagej-roi") return { bytes: exportImageJRoiZip(request.cells) };
  if (request.kind === "geojson") return { bytes: new TextEncoder().encode(exportCellsGeoJson(request.cells, request.provenance)) };
  if (request.kind === "pdf") return { bytes: buildPdfReport({ title: request.title, subtitle: "Private browser-local CellCounter report", sections: [
    { heading: "Summary", lines: [`Objects: ${request.cells.length}`, `Dimensions: ${request.width} x ${request.height} source pixels`] },
    { heading: "Reproducibility", lines: Object.entries(request.provenance).sort(([a], [b]) => a.localeCompare(b)).map(([key, value]) => `${key}: ${typeof value === "object" ? JSON.stringify(value) : String(value)}`) },
  ] }) };
  if (request.kind === "annotated-png") {
    if (!request.source) throw new Error("Annotated PNG export needs the locally loaded analysis raster");
    const bitmap = await createImageBitmap(request.source);
    if (bitmap.width !== request.width || bitmap.height !== request.height) { bitmap.close(); throw new Error("Analysis raster dimensions do not match source-coordinate cells"); }
    if (bitmap.width * bitmap.height * 16 + request.source.size > 384 * 1024 * 1024) { bitmap.close(); throw new Error("Annotated PNG export exceeds the 384 MB browser working-set budget"); }
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height); const context = canvas.getContext("2d", { willReadFrequently: true });
    if (!context) { bitmap.close(); throw new Error("2D OffscreenCanvas is unavailable for annotated export"); }
    context.drawImage(bitmap, 0, 0); bitmap.close(); const rgba = context.getImageData(0, 0, canvas.width, canvas.height).data;
    return { bytes: exportAnnotatedPng({ data: rgba, width: canvas.width, height: canvas.height }, request.cells) };
  }
  if (!workspaceExportNeedsLabelMap(request.kind)) throw new Error(`Unknown workspace artifact ${request.kind}`);
  const labels = labelMap(request.cells, request.width, request.height);
  if (request.kind === "mask-png") return { bytes: exportSegmentationMaskPng(labels, request.width, request.height) };
  const payload = buildBareSegmentationNpyPayload(labels, request.width, request.height, request.provenance);
  return { bytes: payload.npy, sidecar: payload.metadataJson };
}

self.onmessage = async (event: MessageEvent<WorkspaceExportRequest>) => {
  try {
    const result = await artifact(event.data);
    self.postMessage({ id: event.data.id, ok: true, ...result }, [result.bytes.buffer]);
  } catch (error) { self.postMessage({ id: event.data.id, ok: false, error: error instanceof Error ? error.message : String(error) }); }
};

export {};
