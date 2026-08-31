import type { Calibration, ImageAnalysis, ImageDescriptor } from "../domain/types";
import type { WorkspaceImage } from "./types";

type ImageIdentity = Pick<WorkspaceImage,
  | "id"
  | "file"
  | "originalFile"
  | "fileName"
  | "importedAt"
  | "pxPerUm"
  | "sourceSha256"
  | "sourceByteLength"
  | "sourceMediaType"
  | "calibrationSource"
  | "calibrationConfidence"
  | "planeCount"
  | "bitsPerSample"
  | "samplesPerPixel"
>;

export function calibrationForImage(image: ImageIdentity): Calibration {
  return {
    pxPerUm: image.pxPerUm,
    source: image.calibrationSource ?? "default",
    confidence: image.calibrationConfidence ?? "low",
  };
}

export function analysisIdentities(
  image: ImageIdentity,
  analysisSha256: string,
  widthPx: number,
  heightPx: number,
): { image: ImageDescriptor; originalSource?: NonNullable<ImageAnalysis["originalSource"]> } {
  const normalizedTiff = Boolean(image.originalFile);
  return {
    image: {
      id: image.id,
      fileName: normalizedTiff ? `${image.fileName}::normalized-first-plane.png` : image.fileName,
      mediaType: image.file.type || "application/octet-stream",
      byteLength: image.file.size,
      sha256: analysisSha256,
      widthPx,
      heightPx,
      importedAt: image.importedAt,
    },
    originalSource: image.sourceSha256 ? {
      fileName: image.fileName,
      mediaType: (image.sourceMediaType ?? image.originalFile?.type ?? image.file.type) || "application/octet-stream",
      byteLength: image.sourceByteLength ?? image.originalFile?.size ?? image.file.size,
      sha256: image.sourceSha256,
      analysisTransform: normalizedTiff ? "tiff-first-plane-rgb8-preview" : "identity",
      planeCount: image.planeCount ?? 1,
      bitsPerSample: image.bitsPerSample ?? 8,
      samplesPerPixel: image.samplesPerPixel ?? 3,
    } : undefined,
  };
}
