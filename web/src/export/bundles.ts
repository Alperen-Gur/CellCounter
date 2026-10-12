import { zipSync } from "fflate";
import type { WorkspaceImage, GroundTruthMark } from "../app/types";
import { calibrationForImage } from "../app/provenance";
import { deterministicJson, exportCellsCsv } from "./tabular";
import { contourPoints, type ExportCell } from "./types";
import { encodeLabelTIFF } from "../../../shared/microscopy/paint";
import { preparePlane } from "../models/ClassicalInference";
import { exportImageJRoiZip } from "./imagej";

const MAX_ENTRIES_BYTES = 48 * 1024 * 1024;
const MAX_SOURCE_BYTES = 64 * 1024 * 1024;
const encoder = new TextEncoder();
function abort(signal?: AbortSignal) { if (signal?.aborted) throw new DOMException("Export cancelled", "AbortError"); }
async function sha(bytes: Uint8Array): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes.slice().buffer)), b => b.toString(16).padStart(2, "0")).join("");
}
function text(value: unknown): Uint8Array { return encoder.encode(deterministicJson(value)); }
function finite(value: number, name: string): void { if (!Number.isFinite(value)) throw new Error(`${name} must be finite.`); }
function markdown(value: string): string { return value.replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]!).replace(/[\\`*_{}\[\]()#+.!|~-]/g, "\\$&").replace(/[\r\n]+/g, " "); }
function csv(value: string | number): string { let s = String(value); if (typeof value === "string" && /^[=+@\-\t\r]/.test(s.trimStart())) s = `'${s}`; return `"${s.replaceAll('"', '""')}"`; }

/** Bound the entire metadata graph before JSON serialization or structured cloning.
 * Blobs are immutable handles; their source byte limits are checked separately. */
export function validateMetadataGraph(value: unknown, budget = { nodes: 0, characters: 0 }): void {
  const ancestors = new WeakSet<object>();
  const visit = (item: unknown, depth: number): void => {
    if (++budget.nodes > 1_000_000 || depth > 32) throw new Error("Review metadata exceeds its bounded graph budget. Export fewer images.");
    if (typeof item === "string") budget.characters += item.length;
    else if (item && typeof item === "object" && !(item instanceof Blob)) {
      if (ancestors.has(item)) throw new Error("Review metadata contains a circular reference.");
      ancestors.add(item);
      if (Array.isArray(item)) {
        if (item.length > 1_000_000 - budget.nodes) throw new Error("Review metadata array exceeds its transfer budget.");
        for (const child of item) visit(child, depth + 1);
      } else {
        if (Object.getPrototypeOf(item) !== Object.prototype && Object.getPrototypeOf(item) !== null) throw new Error("Review metadata must contain plain records.");
        for (const key in item) if (Object.hasOwn(item, key)) {
          budget.characters += key.length;
          visit((item as Record<string, unknown>)[key], depth + 1);
        }
      }
      ancestors.delete(item);
    }
    if (budget.characters > 4 * 1024 * 1024) throw new Error("Review metadata exceeds four million characters. Export fewer images.");
  };
  visit(value, 0);
}

/** Digest used by explicit reviewer sign-off. All geometry and run/source identity are bound. */
export async function reviewedFingerprint(image: WorkspaceImage): Promise<string> {
  validateMetadataGraph(image);
  if (!image.analysis) throw new Error("Load the complete analysis before signing off review.");
  const { displayPlane: _displayPlane, ...analysis } = image.analysis;
  return sha(text({ sourceSha256: image.sourceSha256, editRevision: image.editRevision ?? 0,
    calibration: calibrationForImage(image), width: image.width, height: image.height,
    analysis, cells: image.cells, rois: image.rois, groundTruth: image.groundTruth }));
}
export type DatasetSplit = "train" | "validation" | "test";
export interface ReviewedTrainingSample {
  image: WorkspaceImage;
  source: Blob;
  reviewedFingerprint: string;
  specimenGroup: string;
  split: DatasetSplit;
}

/** Even-odd scanline fill, with bounded work and no silent instance overlap or dropped masks. */
function instanceLabels(cells: readonly ExportCell[], width: number, height: number): Uint16Array {
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width < 1 || height < 1 || width * height > 4_000_000) throw new Error("Training masks require a source plane of at most four million pixels.");
  if (!cells.length || cells.length > 65535) throw new Error("A training mask needs 1–65,535 instances.");
  const labels = new Uint16Array(width * height), ids = new Set<string>();
  let work = 0;
  cells.forEach((cell, index) => {
    if (ids.has(cell.id)) throw new Error("Duplicate object identity in training masks."); ids.add(cell.id);
    if (!cell.contourPx || cell.contourPx.length < 3) throw new Error("Training export needs complete source contours; reload the analysis before exporting.");
    const points = contourPoints(cell);
    if (points.length > 8192) throw new Error("A training contour exceeds 8,192 vertices.");
    let minY = height, maxY = 0;
    for (const p of points) {
      finite(p.x, "Contour X"); finite(p.y, "Contour Y");
      if (p.x < 0 || p.y < 0 || p.x > width || p.y > height) throw new Error("Training contour is outside its source image.");
      minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
    }
    const y0 = Math.max(0, Math.ceil(minY - .5)), y1 = Math.min(height - 1, Math.floor(maxY - .5));
    work += Math.max(0, y1 - y0 + 1) * points.length;
    if (work > 80_000_000) throw new Error("Training contours exceed the bounded rasterization budget. Export fewer or simpler masks.");
    let count = 0;
    for (let y = y0; y <= y1; y++) {
      const crossings: number[] = [], scan = y + .5;
      for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
        const a = points[j], b = points[i];
        if ((a.y > scan) !== (b.y > scan)) crossings.push(a.x + (scan - a.y) * (b.x - a.x) / (b.y - a.y));
      }
      crossings.sort((a, b) => a - b);
      for (let i = 0; i + 1 < crossings.length; i += 2) {
        const x0 = Math.max(0, Math.ceil(crossings[i] - .5)), x1 = Math.min(width - 1, Math.ceil(crossings[i + 1] - .5) - 1);
        work += Math.max(0, x1 - x0 + 1);
        if (work > 80_000_000) throw new Error("Training mask fill exceeds its bounded work budget.");
        for (let x = x0; x <= x1; x++) {
          const at = y * width + x;
          if (labels[at] && labels[at] !== index + 1) throw new Error("Training instances overlap. Resolve overlapping contours before exporting.");
          labels[at] = index + 1; count++;
        }
      }
    }
    if (!count) throw new Error(`Object ${index + 1} contains no source pixel centers. Correct or remove it before exporting.`);
  });
  return labels;
}
/** Uncompressed Float32 grayscale TIFF; sample values are not rescaled to a display preview. */
function floatTiff(width: number, height: number, values: Float32Array, pxPerUm: number): Uint8Array {
  const description = encoder.encode(JSON.stringify({ type: "CellCounter source plane", pxPerUm }) + "\0");
  const tags = 11, descOffset = 8 + 2 + tags * 12 + 4, dataOffset = (descOffset + description.length + 3) & ~3;
  const bytes = new Uint8Array(dataOffset + values.length * 4), view = new DataView(bytes.buffer);
  bytes.set([73, 73]); view.setUint16(2, 42, true); view.setUint32(4, 8, true); view.setUint16(8, tags, true); let offset = 10;
  const tag = (id: number, type: number, count: number, value: number) => { view.setUint16(offset, id, true); view.setUint16(offset + 2, type, true); view.setUint32(offset + 4, count, true); view.setUint32(offset + 8, value, true); offset += 12; };
  tag(256, 4, 1, width); tag(257, 4, 1, height); tag(258, 3, 1, 32); tag(259, 3, 1, 1); tag(262, 3, 1, 1);
  tag(270, 2, description.length, descOffset); tag(273, 4, 1, dataOffset); tag(277, 3, 1, 1); tag(278, 4, 1, height); tag(279, 4, 1, values.length * 4); tag(339, 3, 1, 3);
  bytes.set(description, descOffset);
  for (let i = 0; i < values.length; i++) { finite(values[i], "Training intensity"); view.setFloat32(dataOffset + i * 4, values[i], true); }
  return bytes;
}
class Bundle {
  private bytes = 0;
  private entries: Record<string, Uint8Array> = Object.create(null) as Record<string, Uint8Array>;
  add(name: string, value: Uint8Array) {
    if (Object.hasOwn(this.entries, name)) throw new Error("Duplicate artifact name.");
    this.bytes += value.byteLength;
    if (this.bytes > MAX_ENTRIES_BYTES) throw new Error("Export exceeds 48 MiB of uncompressed artifacts. Select fewer images.");
    this.entries[name] = value;
  }
  async inventory(): Promise<Record<string, { sha256: string; byteLength: number }>> {
    const files: Record<string, { sha256: string; byteLength: number }> = Object.create(null);
    for (const [name, bytes] of Object.entries(this.entries)) files[name] = { sha256: await sha(bytes), byteLength: bytes.byteLength };
    return files;
  }
  finish(): Uint8Array { return zipSync(this.entries, { level: 0 }); }
}
export async function buildReviewedDataset(samples: readonly ReviewedTrainingSample[], signal?: AbortSignal): Promise<Uint8Array> {
  validateTrainingTransfer(samples);
  const groupSplits = new Map<string, DatasetSplit>(), splits = new Set<DatasetSplit>(), sourceHashes = new Set<string>(), imageIds = new Set<string>();
  for (const sample of samples) {
    const group = sample.specimenGroup.trim().normalize("NFC");
    if (!group || group.length > 128 || /[\x00-\x1f]/.test(group)) throw new Error("Assign each image an explicit specimen group of at most 128 characters.");
    if (!["train", "validation", "test"].includes(sample.split)) throw new Error("Choose a dataset split for every image.");
    if (groupSplits.has(group) && groupSplits.get(group) !== sample.split) throw new Error("All images from one specimen group must remain in the same split.");
    groupSplits.set(group, sample.split); splits.add(sample.split);
    if (imageIds.has(sample.image.id)) throw new Error("The same image was selected more than once."); imageIds.add(sample.image.id);
  }
  if (splits.size !== 3 || groupSplits.size < 3) throw new Error("Training, validation and test each need at least one independent specimen group.");
  const bundle = new Bundle(), planeHashes = new Set<string>(), manifestSamples: unknown[] = [], groups: Record<string, string> = Object.create(null) as Record<string, string>;
  for (const [index, sample] of samples.entries()) {
    abort(signal); const { image } = sample, analysis = image.analysis;
    if (!analysis || !image.sourceSha256 || !/^[0-9a-f]{64}$/i.test(image.sourceSha256)) throw new Error("A complete analyzed source and its SHA-256 are required.");
    if (sample.reviewedFingerprint !== await reviewedFingerprint(image)) throw new Error("Analysis changed after reviewer sign-off. Review the current result again.");
    if (!Number.isFinite(image.pxPerUm) || image.pxPerUm <= 0 || image.calibrationConfidence !== "high" || image.calibrationSource === "default" || analysis.calibration.pxPerUm !== image.pxPerUm) throw new Error("Verify high-confidence calibration before exporting a reviewed training snapshot.");
    if (sample.source.size > MAX_SOURCE_BYTES) throw new Error("Training export supports preserved source files up to 64 MiB each.");
    const sourceHash = await sha(new Uint8Array(await sample.source.arrayBuffer()));
    if (sourceHash !== image.sourceSha256.toLowerCase()) throw new Error("Preserved source no longer matches its recorded identity.");
    if ((analysis.originalSource?.sha256 ?? analysis.image.sha256).toLowerCase() !== sourceHash) throw new Error("Reviewed analysis belongs to a different preserved source.");
    if (sourceHashes.has(sourceHash)) throw new Error("Duplicate source content cannot be included twice in a training snapshot."); sourceHashes.add(sourceHash);
    if (analysis.originalSource?.analysisTransform === "tiff-first-plane-rgb8-preview") throw new Error("This analysis used the old TIFF preview conversion. Reanalyze the original plane before training export.");
    const plane = await preparePlane({ source: { id: image.id, fileName: image.fileName, mediaType: sample.source.type, byteLength: sample.source.size, lastModified: null, blob: sample.source }, parameters: analysis.parameters, calibration: analysis.calibration, signal });
    if (plane.width !== image.width || plane.height !== image.height) throw new Error("Source plane and reviewed geometry have different dimensions.");
    const planeHash = `${plane.width}:${plane.height}:${await sha(new Uint8Array(plane.values.buffer, plane.values.byteOffset, plane.values.byteLength))}`;
    if (planeHashes.has(planeHash)) throw new Error("Identical source planes cannot be included twice, even from differently encoded files.");
    planeHashes.add(planeHash);
    const cells: ExportCell[] = analysis.cells.map(cell => ({ id: cell.id, cx: cell.centroidPx.x, cy: cell.centroidPx.y, diameterPx: cell.equivalentDiameterPx, contourPx: cell.contourPx }));
    const labels = instanceLabels(cells, plane.width, plane.height);
    const sourceBytes = floatTiff(plane.width, plane.height, plane.values, image.pxPerUm);
    const maskBytes = encodeLabelTIFF(plane.width, plane.height, labels, { x: 1 / image.pxPerUm, y: 1 / image.pxPerUm, unit: "um" });
    const stem = `sample-${String(index + 1).padStart(4, "0")}`, imagePath = `${sample.split}/${stem}.tif`, maskPath = `${sample.split}/${stem}_masks.tif`;
    const group = sample.specimenGroup.trim().normalize("NFC"); groups[imagePath] = group;
    manifestSamples.push({ imageId: image.id, fileName: image.fileName, sourceSha256: sourceHash, imageFile: imagePath, imageSha256: await sha(sourceBytes), maskFile: maskPath, maskSha256: await sha(maskBytes), width: plane.width, height: plane.height, group, split: sample.split, reviewedFingerprint: sample.reviewedFingerprint, reviewConfidence: image.reviewConfidence, calibration: analysis.calibration, parameters: analysis.parameters, model: analysis.model, instanceIds: cells.map(cell => cell.id), editRevision: image.editRevision ?? 0 });
    bundle.add(imagePath, sourceBytes); bundle.add(maskPath, maskBytes);
    await new Promise(resolve => setTimeout(resolve, 0));
  }
  bundle.add("manifest.json", text({ schemaVersion: 1, id: crypto.randomUUID(), createdAt: new Date().toISOString(), source: "CellCounter reviewed browser-local snapshot", geometry: "source-pixel contours rasterized at pixel centers; overlap rejected", intensity: "selected raw source plane, no display normalization or preprocessing", samples: manifestSamples }));
  bundle.add("groups.json", text(groups)); abort(signal); return bundle.finish();
}

/** Bound geometry before structured cloning the snapshot into a worker. */
export function validateTrainingTransfer(samples: readonly ReviewedTrainingSample[]): void {
  if (samples.length < 3 || samples.length > 128) throw new Error("Select 3–128 reviewed images in independent training, validation and test groups.");
  validateMetadataGraph(samples);
  let vertices = 0, cells = 0;
  for (const { image, source } of samples) {
    if (source.size > MAX_SOURCE_BYTES) throw new Error("Training export supports preserved source files up to 64 MiB each.");
    if ((image.analysis?.correctionLog.length ?? 0) > 10000 || image.groundTruth.length > 100000 || image.rois.length > 10000) throw new Error("Review metadata exceeds the transfer budget.");
    cells += image.cells.length + (image.analysis?.cells.length ?? 0);
    for (const cell of image.cells) vertices += cell.contourPx?.length ?? 0;
    for (const cell of image.analysis?.cells ?? []) vertices += cell.contourPx.length;
    if (cells > 100000 || vertices > 500000) throw new Error("Reviewed geometry exceeds the worker transfer budget. Select fewer images.");
  }
}

export function exportGroundTruthCsv(marks: readonly GroundTruthMark[]): string {
  return "id,x_px,y_px,diameter_px\n" + marks.map(mark => { [mark.x, mark.y, mark.diameterPx].forEach(n => finite(n, "Ground-truth coordinate")); return [mark.id, mark.x, mark.y, mark.diameterPx].map(csv).join(","); }).join("\n") + "\n";
}
export interface SampleBundleInput {
  title: string; width: number; height: number; cells: readonly ExportCell[];
  groundTruth?: readonly GroundTruthMark[]; provenance: Readonly<Record<string, unknown>>;
  originalSource?: Blob; originalFileName?: string; analysisSource?: Blob;
  /** Already-built overlay, mask, ROI or PDF bytes; fixed safe basenames only. */
  artifacts?: Readonly<Record<string, Uint8Array>>;
}
export function exportMarkdownReport(input: Omit<SampleBundleInput, "originalSource" | "analysisSource" | "artifacts">): string {
  return `# ${markdown(input.title)}\n\nObjects: ${input.cells.length}\n\nDimensions: ${input.width} × ${input.height} source pixels\n\nGround-truth marks: ${input.groundTruth?.length ?? 0}\n\n## Provenance\n\n${Object.entries(input.provenance).sort(([a], [b]) => a.localeCompare(b)).map(([key, value]) => `- **${markdown(key)}:** ${markdown(typeof value === "string" ? value : JSON.stringify(value) ?? "")}`).join("\n")}\n`;
}
export async function buildSampleBundle(input: SampleBundleInput, signal?: AbortSignal): Promise<Uint8Array> {
  const bundle = new Bundle(); abort(signal);
  bundle.add("report.md", encoder.encode(exportMarkdownReport(input)));
  bundle.add("cells.csv", encoder.encode(exportCellsCsv(input.cells, input.provenance)));
  bundle.add("ground-truth.csv", encoder.encode(exportGroundTruthCsv(input.groundTruth ?? [])));
  bundle.add("provenance.json", text(input.provenance));
  bundle.add("geometry.json", text({ coordinateSpace: "source-pixels", width: input.width, height: input.height, cells: input.cells }));
  bundle.add("imagej-rois.zip", exportImageJRoiZip(input.cells));
  const manifest: Record<string, unknown> = { schemaVersion: 1, originalFileName: input.originalFileName ?? null, files: {} };
  const analysisExtension = ({ "image/png": "png", "image/jpeg": "jpg", "image/tiff": "tif", "image/bmp": "bmp" } as Record<string, string>)[input.analysisSource?.type ?? ""] ?? "bin";
  const originalExtension = input.originalFileName?.split(".").at(-1)?.toLowerCase();
  const sourceName = originalExtension && /^[a-z0-9]{1,16}$/.test(originalExtension) ? `original.${originalExtension}` : "source.original";
  for (const [name, source] of [[sourceName, input.originalSource], [`analysis-plane.${analysisExtension}`, input.analysisSource]] as const) if (source) {
    if (source.size > MAX_SOURCE_BYTES) throw new Error("Sample bundles support source files up to 64 MiB.");
    const bytes = new Uint8Array(await source.arrayBuffer()); abort(signal); bundle.add(name, bytes);
    (manifest.files as Record<string, unknown>)[name] = { sha256: await sha(bytes), mediaType: source.type, byteLength: bytes.length };
  }
  for (const [name, bytes] of Object.entries(input.artifacts ?? {})) {
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]*\.(png|pdf|tif|json|zip)$/.test(name)) throw new Error("Invalid sample artifact name.");
    bundle.add(name, bytes);
  }
  manifest.files = { ...await bundle.inventory(), ...(manifest.files as Record<string, unknown>) };
  bundle.add("manifest.json", text(manifest)); abort(signal); return bundle.finish();
}
