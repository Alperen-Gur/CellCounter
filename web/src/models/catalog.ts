import type { ModelId } from "../domain/types";

export type ArtifactAvailability = "buildRequired" | "ready";

export interface ModelManifest {
  readonly schemaVersion: 1;
  readonly id: ModelId;
  readonly displayName: string;
  readonly family: "cellpose-sam" | "cellpose" | "stardist";
  readonly manifestVersion: string;
  readonly artifact: {
    readonly availability: ArtifactAvailability;
    readonly url: string;
    /** Release-pinned SHA-256. Build-required sentinels are never accepted at runtime. */
    readonly sha256: string;
    readonly byteLength: number;
  };
  readonly input: {
    readonly name: string;
    readonly channels: 3;
    readonly tileSize: number;
    readonly overlapPx: number;
    readonly dataType: "float32";
    readonly normalization: "percentile-1-99-per-channel";
  };
  readonly output: {
    readonly name: string;
    readonly kind: "instance-label-map";
    readonly dataType: "int32" | "int64" | "uint32";
  };
  readonly citationUrl: string;
  readonly licenseNote: string;
}

/**
 * These sentinels are syntactically pinned so the catalog is deterministic,
 * but `buildRequired` makes them non-runnable. Release packaging must replace
 * the digest, byte length and availability atomically after parity validation.
 */
export const MODEL_CATALOG = Object.freeze([
  {
    schemaVersion: 1,
    id: "cpsam_v2",
    displayName: "Cellpose-SAM v2",
    family: "cellpose-sam",
    manifestVersion: "1.0.0",
    artifact: {
      availability: "buildRequired",
      url: "/models/cpsam_v2/1.0.0/cpsam_v2.fp16.onnx",
      sha256: "0000000000000000000000000000000000000000000000000000000000000000",
      byteLength: 0,
    },
    input: {
      name: "image",
      channels: 3,
      tileSize: 256,
      overlapPx: 32,
      dataType: "float32",
      normalization: "percentile-1-99-per-channel",
    },
    output: { name: "labels", kind: "instance-label-map", dataType: "int32" },
    citationUrl: "https://github.com/MouseLand/cellpose",
    licenseNote: "Review Cellpose model/data licensing before redistribution.",
  },
  {
    schemaVersion: 1,
    id: "cp-cyto3",
    displayName: "Cellpose cyto3",
    family: "cellpose",
    manifestVersion: "1.0.0",
    artifact: {
      availability: "buildRequired",
      url: "/models/cp-cyto3/1.0.0/cyto3.fp16.onnx",
      sha256: "0000000000000000000000000000000000000000000000000000000000000000",
      byteLength: 0,
    },
    input: {
      name: "image",
      channels: 3,
      tileSize: 256,
      overlapPx: 32,
      dataType: "float32",
      normalization: "percentile-1-99-per-channel",
    },
    output: { name: "labels", kind: "instance-label-map", dataType: "int32" },
    citationUrl: "https://github.com/MouseLand/cellpose",
    licenseNote: "Review Cellpose model/data licensing before redistribution.",
  },
  {
    schemaVersion: 1,
    id: "sd-fluo",
    displayName: "StarDist Versatile Fluorescence",
    family: "stardist",
    manifestVersion: "1.0.0",
    artifact: {
      availability: "buildRequired",
      url: "/models/sd-fluo/1.0.0/stardist-fluo.fp16.onnx",
      sha256: "0000000000000000000000000000000000000000000000000000000000000000",
      byteLength: 0,
    },
    input: {
      name: "image",
      channels: 3,
      tileSize: 512,
      overlapPx: 32,
      dataType: "float32",
      normalization: "percentile-1-99-per-channel",
    },
    output: { name: "labels", kind: "instance-label-map", dataType: "int32" },
    citationUrl: "https://github.com/stardist/stardist",
    licenseNote: "Model source is StarDist 2D_versatile_fluo; preserve upstream notices.",
  },
] as const satisfies readonly ModelManifest[]);

export function getModelManifest(id: ModelId): ModelManifest {
  const manifest = MODEL_CATALOG.find((candidate) => candidate.id === id);
  if (!manifest) throw new RangeError(`Unknown web model: ${id}`);
  return manifest;
}
