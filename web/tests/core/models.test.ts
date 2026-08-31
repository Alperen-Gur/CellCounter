import { afterEach, describe, expect, it, vi } from "vitest";
import { WebGpuInference, assertWebGpuAvailable, stitchLabelTiles } from "../../src/models/WebGpuInference";
import { MODEL_CATALOG, getModelManifest } from "../../src/models/catalog";
import {
  ArtifactHashMismatchError,
  ModelArtifactUnavailableError,
  NoWebGpuError,
  UnsupportedOperatorError,
  normalizeInferenceError,
} from "../../src/models/errors";
import { sha256Hex, verifySha256 } from "../../src/models/hash";
import { calibration, parameters } from "./fixtures/sample";

const originalGpu = Object.getOwnPropertyDescriptor(globalThis.navigator, "gpu");

afterEach(() => {
  if (originalGpu) Object.defineProperty(globalThis.navigator, "gpu", originalGpu);
  else Reflect.deleteProperty(globalThis.navigator, "gpu");
  vi.restoreAllMocks();
});

describe("strict WebGPU model catalog", () => {
  it("contains exactly the selected three versioned manifests", () => {
    expect(MODEL_CATALOG.map((manifest) => manifest.id)).toEqual(["cpsam_v2", "cp-cyto3", "sd-fluo"]);
    expect(new Set(MODEL_CATALOG.map((manifest) => manifest.id)).size).toBe(3);
    for (const manifest of MODEL_CATALOG) {
      expect(manifest.manifestVersion).toMatch(/^\d+\.\d+\.\d+$/);
      expect(manifest.artifact.sha256).toMatch(/^[a-f0-9]{64}$/);
      expect(manifest.artifact.availability).toBe("buildRequired");
      expect(manifest.output.kind).toBe("instance-label-map");
    }
    expect(getModelManifest("sd-fluo").family).toBe("stardist");
  });

  it("validates SHA-256 and fails on tampered bytes", async () => {
    const empty = new ArrayBuffer(0);
    const digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    expect(await sha256Hex(empty)).toBe(digest);
    await expect(verifySha256("cp-cyto3", empty, digest)).resolves.toBeUndefined();
    await expect(verifySha256("cp-cyto3", new Uint8Array([1]).buffer, digest)).rejects.toBeInstanceOf(
      ArtifactHashMismatchError,
    );
  });

  it("fails explicitly when WebGPU is unavailable", async () => {
    Reflect.deleteProperty(globalThis.navigator, "gpu");
    await expect(assertWebGpuAvailable()).rejects.toBeInstanceOf(NoWebGpuError);
  });

  it("fails build-required artifacts without fetching or substituting a model", async () => {
    Object.defineProperty(globalThis.navigator, "gpu", {
      configurable: true,
      value: { requestAdapter: vi.fn().mockResolvedValue({}) },
    });
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const inference = new WebGpuInference();
    await expect(inference.analyze({
      source: {
        id: "image", fileName: "image.png", mediaType: "image/png", byteLength: 0, lastModified: null, blob: new Blob(),
      },
      calibration,
      parameters,
    })).rejects.toBeInstanceOf(ModelArtifactUnavailableError);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("maps unsupported operators to an explicit compatibility error", () => {
    const error = normalizeInferenceError(new Error("kernel not found for ConvTranspose"), "cpsam_v2");
    expect(error).toBeInstanceOf(UnsupportedOperatorError);
    expect(error.code).toBe("unsupported-operator");
  });

  it("stitches overlapping tile instances into stable source-resolution labels", () => {
    const labels = stitchLabelTiles([
      { originX: 0, originY: 0, width: 3, height: 1, labels: new Uint32Array([1, 1, 1]) },
      { originX: 2, originY: 0, width: 3, height: 1, labels: new Uint32Array([7, 7, 0]) },
    ], 5, 1);
    expect([...labels]).toEqual([1, 1, 1, 1, 0]);
  });
});
