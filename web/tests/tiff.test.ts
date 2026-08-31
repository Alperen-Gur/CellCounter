import { describe, expect, it } from "vitest";
import { parseBaselineCalibration, parseImageJCalibration, parseOmeCalibration } from "../src/import/tiff";
import { assertImageImportBudget, assertTiffImportBudget, estimatedTiffImportBytes } from "../src/import/tiffBudget";

describe("TIFF/OME calibration", () => {
  it("reads isotropic OME physical size as pixels per micrometre", () => {
    const result = parseOmeCalibration('<OME><Pixels PhysicalSizeX="0.25" PhysicalSizeY="0.25" PhysicalSizeXUnit="µm" PhysicalSizeYUnit="µm"/></OME>');
    expect(result).toEqual({ pxPerUm: 4, source: "OME-XML", confidence: "high" });
  });

  it("converts nanometres and refuses materially anisotropic metadata", () => {
    expect(parseOmeCalibration('<Pixels PhysicalSizeX="250" PhysicalSizeY="250" PhysicalSizeXUnit="nm" PhysicalSizeYUnit="nm"/>')?.pxPerUm).toBe(4);
    expect(parseOmeCalibration('<Pixels PhysicalSizeX="0.25" PhysicalSizeY="0.5" PhysicalSizeXUnit="µm"/>')).toBeUndefined();
  });

  it("reads ImageJ calibration", () => {
    expect(parseImageJCalibration("ImageJ=1.54f\nunit=um\npixel_width=0.5\npixel_height=0.5")?.pxPerUm).toBe(2);
  });

  it("requires an explicit baseline resolution unit", () => {
    expect(parseBaselineCalibration({ XResolution: [25_400, 1], YResolution: [25_400, 1], ResolutionUnit: 2 })?.pxPerUm).toBe(1);
    expect(parseBaselineCalibration({ XResolution: [25_400, 1], YResolution: [25_400, 1] })).toBeUndefined();
    expect(parseBaselineCalibration({ XResolution: 100, YResolution: 200, ResolutionUnit: 2 })).toBeUndefined();
  });

  it("budgets the full TIFF decode working set conservatively", () => {
    expect(estimatedTiffImportBytes(8 * 1024 * 1024, 4_000, 4_000)).toBe(328_388_608);
    expect(() => assertTiffImportBudget(8 * 1024 * 1024, 4_000, 4_000)).not.toThrow();
    expect(() => assertTiffImportBudget(32 * 1024 * 1024, 5_000, 5_000)).toThrow(/384 MB browser import budget/);
    expect(() => assertImageImportBudget(32 * 1024 * 1024, 5_000, 5_000)).toThrow(/^Image dimensions/);
  });
});
