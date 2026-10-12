import type { WorkspaceImage } from "./types";
import { sha256Hex } from "../models/hash";
import { decodeTiff } from "../import/tiff";
import { assertImageImportBudget } from "../import/tiffBudget";
import { rasterHeader } from "../import/rasterHeader";

const SUPPORTED_MIME = new Set(["image/png", "image/jpeg", "image/webp", "image/bmp"]);
const SUPPORTED_SUFFIX = /\.(png|jpe?g|webp|bmp)$/i;
const TIFF_MIME = new Set(["image/tiff", "image/x-tiff"]);
const TIFF_SUFFIX = /\.ome\.tiff?$|\.tiff?$/i;

export class UnsupportedImageError extends Error {
  constructor(fileName: string) {
    super(`${fileName} is not browser-decodable. Convert proprietary microscopy files to PNG, JPEG, WebP, BMP, or OME-TIFF before import.`);
    this.name = "UnsupportedImageError";
  }
}

async function createThumbnail(file: File): Promise<Blob | undefined> {
  const bitmap = await createImageBitmap(file, { resizeWidth: 160, resizeHeight: 120, resizeQuality: "medium" }).catch(() => null);
  if (!bitmap || typeof OffscreenCanvas === "undefined") return undefined;
  const scale = Math.min(1, 160 / bitmap.width, 120 / bitmap.height);
  const canvas = new OffscreenCanvas(Math.max(1, Math.round(bitmap.width * scale)), Math.max(1, Math.round(bitmap.height * scale)));
  const context = canvas.getContext("2d");
  if (!context) { bitmap.close(); return undefined; }
  context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  return canvas.convertToBlob({ type: "image/webp", quality: 0.76 }).catch(() => undefined);
}

export async function decodeImageFile(file: File): Promise<WorkspaceImage> {
  const isTiff = TIFF_MIME.has(file.type) || TIFF_SUFFIX.test(file.name);
  if (isTiff) {
    const decoded = await decodeTiff(file);
    const thumbnailBlob = await createThumbnail(decoded.displayFile);
    const thumbnailUrl = thumbnailBlob ? URL.createObjectURL(thumbnailBlob) : undefined;
    return {
      id: crypto.randomUUID(), file: decoded.displayFile, originalFile: file, fileName: file.name, objectUrl: URL.createObjectURL(decoded.displayFile),
      width: decoded.width, height: decoded.height, importedAt: new Date().toISOString(), cells: [], condition: "Unassigned",
      pxPerUm: decoded.calibration?.pxPerUm ?? 1, sourceSha256: decoded.sourceSha256, sourceByteLength: file.size,
      sourceMediaType: file.type || "image/tiff", calibrationSource: decoded.calibration?.source === "OME-XML" ? "ome-xml" : decoded.calibration?.source === "ImageJ" ? "imagej" : decoded.calibration?.source === "TIFF baseline" ? "tiff-baseline" : "default", calibrationConfidence: decoded.calibration?.confidence ?? "low", sourceDimensions: { t: decoded.dimensions.t, z: decoded.dimensions.z, c: decoded.dimensions.c }, channelNames: decoded.dimensions.channelNames, planeCount: decoded.imageCount,
      samplesPerPixel: decoded.samplesPerPixel, bitsPerSample: decoded.bitsPerSample,
      thumbnailBlob, thumbnailUrl, sourceLoaded: true,
      groundTruth: [], rois: [], note: "", reviewConfidence: "high",
    };
  }
  if (!SUPPORTED_MIME.has(file.type) && !SUPPORTED_SUFFIX.test(file.name)) {
    throw new UnsupportedImageError(file.name);
  }

  const header = await rasterHeader(file);
  assertImageImportBudget(file.size, header.width, header.height);
  const bitmap = await createImageBitmap(file).catch(() => null);
  if (!bitmap) throw new UnsupportedImageError(file.name);
  let sourceSha256: string;
  try {
    if ((bitmap.width !== header.width || bitmap.height !== header.height) && !(header.jpeg && bitmap.width === header.height && bitmap.height === header.width)) throw new Error("Decoded source dimensions differ from its verified raster header.");
    assertImageImportBudget(file.size, bitmap.width, bitmap.height);
    sourceSha256 = await sha256Hex(await file.arrayBuffer());
  }
  catch (error) { bitmap.close(); throw error; }
  const objectUrl = URL.createObjectURL(file);
  const thumbnailBlob = await createThumbnail(file);
  const thumbnailUrl = thumbnailBlob ? URL.createObjectURL(thumbnailBlob) : undefined;
  const result: WorkspaceImage = {
    id: crypto.randomUUID(),
    file,
    fileName: file.name,
    objectUrl,
    width: bitmap.width,
    height: bitmap.height,
    importedAt: new Date().toISOString(),
    cells: [],
    condition: "Unassigned",
    pxPerUm: 1,
    sourceSha256,
    sourceByteLength: file.size,
    sourceMediaType: file.type,
    calibrationSource: "default",
    calibrationConfidence: "low",
    thumbnailBlob,
    thumbnailUrl,
    sourceLoaded: true,
    groundTruth: [], rois: [], note: "", reviewConfidence: "high",
  };
  bitmap.close();
  return result;
}

export async function decodeImageFiles(files: FileList | File[]): Promise<{ images: WorkspaceImage[]; errors: string[] }> {
  const result: { images: WorkspaceImage[]; errors: string[] } = { images: [], errors: [] };
  // Decode sequentially: several microscope TIFFs can each consume hundreds of MB transiently.
  for (const file of Array.from(files)) {
    try { result.images.push(await decodeImageFile(file)); }
    catch (error) { result.errors.push(error instanceof Error ? error.message : String(error)); }
  }
  return result;
}

export function releaseImage(image: WorkspaceImage): void {
  if (image.objectUrl) URL.revokeObjectURL(image.objectUrl);
  if (image.thumbnailUrl && image.thumbnailUrl !== image.objectUrl) URL.revokeObjectURL(image.thumbnailUrl);
}
