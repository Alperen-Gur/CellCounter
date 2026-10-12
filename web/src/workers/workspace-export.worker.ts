/// <reference lib="webworker" />
import { buildSampleBundle } from "../export/bundles";
import type { GroundTruthMark } from "../app/types";
import { assertRasterHeader } from "../import/rasterHeader";
import { buildBareSegmentationNpyPayload, buildPdfReport, exportAnnotatedPng, exportCellsGeoJson, exportImageJRoiZip, exportSegmentationMaskPng, type ExportCell } from "../export";

export type WorkspaceArtifactKind = "annotated-png" | "mask-png" | "bare-npy" | "imagej-roi" | "geojson" | "pdf" | "sample-bundle";
export interface WorkspaceExportRequest {
  readonly id: string;
  readonly kind: WorkspaceArtifactKind;
  readonly source?: Blob;
  readonly originalSource?: Blob;
  readonly originalFileName?: string;
  readonly groundTruth?: readonly GroundTruthMark[];
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
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width <= 0 || height <= 0 || width * height > 4_000_000) throw new Error("Mask export supports positive integer dimensions and at most four million source pixels. Export table/ROI geometry for larger images.");
  const labels = new Uint32Array(width * height);
  let work = 0;
  cells.forEach((cell, cellIndex) => {
    const polygon = contours(cell); let minX = Infinity; let maxX = -Infinity; let minY = Infinity; let maxY = -Infinity;
    for (const point of polygon) { minX = Math.min(minX, point.x); maxX = Math.max(maxX, point.x); minY = Math.min(minY, point.y); maxY = Math.max(maxY, point.y); }
    const x0 = Math.max(0, Math.floor(minX)), x1 = Math.min(width - 1, Math.ceil(maxX)), y0 = Math.max(0, Math.floor(minY)), y1 = Math.min(height - 1, Math.ceil(maxY));
    work += Math.max(0, x1 - x0 + 1) * Math.max(0, y1 - y0 + 1) * polygon.length;
    if (work > 100_000_000) throw new Error("Mask rasterization exceeds 100 million polygon operations. Export fewer objects or ROI geometry.");
    for (let y = y0; y <= y1; y += 1) for (let x = x0; x <= x1; x += 1) if (pointInPolygon(x + .5, y + .5, polygon)) labels[y * width + x] = cellIndex + 1;
  });
  return labels;
}

async function artifact(request: WorkspaceExportRequest): Promise<{ bytes: Uint8Array; sidecar?: string }> {
  const pixels = request.width * request.height;
  if (!Number.isSafeInteger(request.width) || !Number.isSafeInteger(request.height) || request.width <= 0 || request.height <= 0) throw new Error("Export dimensions must be positive integers.");
  if (request.cells.length > 100000) throw new Error("Export exceeds 100,000 objects.");
  let vertices = 0;
  for (const cell of request.cells) {
    if (![cell.cx, cell.cy, cell.diameterPx, cell.confidence ?? 1].every(Number.isFinite) || cell.diameterPx <= 0) throw new Error("Export object measurements must be finite and positive.");
    vertices += cell.contourPx?.length ?? 32;
    if (vertices > 500000) throw new Error("Export exceeds 500,000 contour vertices.");
    for (const point of cell.contourPx ?? []) { const p = "x" in point ? [point.x, point.y] : point; if (!p.every(Number.isFinite)) throw new Error("Export contour coordinates must be finite."); }
  }
  if (request.kind === "sample-bundle") {
    if ((request.originalSource?.size ?? 0) + (request.source?.size ?? 0) + pixels * 5 > 48 * 1024 * 1024) throw new Error("Sample sources and worst-case overlay exceed the 48 MiB bundle budget. Export artifacts separately.");
    const overlay = await artifact({ ...request, kind: "annotated-png" });
    const pdf = await artifact({ ...request, kind: "pdf" });
    return { bytes: await buildSampleBundle({ title: request.title, width: request.width, height: request.height, cells: request.cells, provenance: request.provenance, groundTruth: request.groundTruth, originalSource: request.originalSource, originalFileName: request.originalFileName, analysisSource: request.source, artifacts: { "annotated.png": overlay.bytes, "report.pdf": pdf.bytes } }) };
  }
  if (request.kind === "imagej-roi") return { bytes: exportImageJRoiZip(request.cells) };
  if (request.kind === "geojson") return { bytes: new TextEncoder().encode(exportCellsGeoJson(request.cells, request.provenance)) };
  if (request.kind === "pdf") return { bytes: buildPdfReport({ title: request.title, subtitle: "Private browser-local CellCounter report", sections: [
    { heading: "Summary", lines: [`Objects: ${request.cells.length}`, `Dimensions: ${request.width} x ${request.height} source pixels`] },
    { heading: "Reproducibility", lines: Object.entries(request.provenance).sort(([a], [b]) => a.localeCompare(b)).map(([key, value]) => `${key}: ${typeof value === "object" ? JSON.stringify(value) : String(value)}`) },
  ] }) };
  if (request.kind === "annotated-png") {
    if (!request.source) throw new Error("Annotated PNG export needs the locally loaded analysis raster");
    // RGBA decode/canvas/readback/overlay, scanlines, compression output, CRC
    // buffers and final concatenation can coexist; reserve 48 bytes/pixel.
    if (pixels > 4_000_000 || pixels * 48 + request.source.size > 256 * 1024 * 1024) throw new Error("Annotated PNG export exceeds its four-million-pixel or 256 MiB encoder working-set budget.");
    await assertRasterHeader(request.source, request.width, request.height);
    const bitmap = await createImageBitmap(request.source);
    if (bitmap.width !== request.width || bitmap.height !== request.height) { bitmap.close(); throw new Error("Analysis raster dimensions do not match source-coordinate cells"); }
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
