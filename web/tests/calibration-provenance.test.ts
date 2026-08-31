import { describe, expect, it } from "vitest";
import { analysisIdentities, calibrationForImage } from "../src/app/provenance";
import type { WorkspaceImage } from "../src/app/types";

function image(overrides: Partial<WorkspaceImage> = {}): WorkspaceImage {
  const display = new File([new Uint8Array([137, 80, 78, 71])], "preview.png", { type: "image/png" });
  return {
    id: "ome-1",
    file: display,
    originalFile: new File([new Uint8Array(1024)], "source.ome.tiff", { type: "image/tiff" }),
    fileName: "source.ome.tiff",
    objectUrl: "blob:preview",
    width: 512,
    height: 256,
    importedAt: "2026-08-31T00:00:00.000Z",
    cells: [],
    condition: "Control",
    pxPerUm: 4,
    sourceSha256: "a".repeat(64),
    sourceByteLength: 1024,
    sourceMediaType: "image/tiff",
    calibrationSource: "ome-xml",
    calibrationConfidence: "high",
    planeCount: 7,
    samplesPerPixel: 2,
    bitsPerSample: 16,
    groundTruth: [],
    rois: [],
    note: "",
    reviewConfidence: "high",
    ...overrides,
  };
}

describe("calibration and input provenance", () => {
  it("keeps metadata calibration authoritative for inference and exports", () => {
    expect(calibrationForImage(image())).toEqual({ pxPerUm: 4, source: "ome-xml", confidence: "high" });
    expect(calibrationForImage(image({ pxPerUm: 2, calibrationSource: "protocol" }))).toEqual({ pxPerUm: 2, source: "protocol", confidence: "high" });
  });

  it("records the exact inference raster separately from the original TIFF", () => {
    const identities = analysisIdentities(image(), "b".repeat(64), 512, 256);
    expect(identities.image).toMatchObject({
      fileName: "source.ome.tiff::normalized-first-plane.png",
      mediaType: "image/png",
      byteLength: 4,
      sha256: "b".repeat(64),
    });
    expect(identities.originalSource).toEqual({
      fileName: "source.ome.tiff",
      mediaType: "image/tiff",
      byteLength: 1024,
      sha256: "a".repeat(64),
      analysisTransform: "tiff-first-plane-rgb8-preview",
      planeCount: 7,
      bitsPerSample: 16,
      samplesPerPixel: 2,
    });
    expect(identities.image.sha256).not.toBe(identities.originalSource?.sha256);
  });

  it("marks a browser-native raster as identity-transformed", () => {
    const raster = image({ originalFile: undefined, fileName: "field.png", sourceMediaType: "image/png", sourceByteLength: 4 });
    expect(analysisIdentities(raster, "a".repeat(64), 512, 256).originalSource?.analysisTransform).toBe("identity");
  });
});
