import { describe, expect, it } from "vitest";
import {
  ANALYSIS_PROTOCOL_KIND,
  analyzeNeurites,
  applyAnalysisProtocol,
  matchGroundTruth,
  otsuThreshold,
  parseAnalysisProtocol,
  measureCellIntensities,
  serializeAnalysisProtocol,
  trackCells,
  validateAnalysisProtocol,
  type AnalysisProtocolV1,
} from "../../src/analysis";

const protocol: AnalysisProtocolV1 = {
  schemaVersion: 1,
  kind: ANALYSIS_PROTOCOL_KIND,
  id: "protocol-1",
  name: "Keratinocyte 10x",
  notes: "Validated lab settings",
  createdAt: "2026-08-31T00:00:00.000Z",
  appVersion: "1.0.8",
  appBuild: "1",
  model: { id: "cp-cyto3", name: "Cellpose cyto3", family: "cellpose" },
  detection: { expectedDiameterUm: 20, channelsCyto: 1, channelsNuclei: 0, confidenceThreshold: 0.6 },
  calibration: { pxPerUm: 2 },
  sizeBins: { thresholdsUm: [10, 20] },
  preprocessing: { backgroundSubtract: true, rollingBallRadiusPx: 50, watershedSplit: true, watershedMinDistanceUm: 8 },
  manualMarkerDiameterUm: 12,
};

describe("tracking, neurites and ground truth", () => {
  it("uses global assignment, calibration and explicit frame timing", () => {
    const result = trackCells([
      { frame: 0, points: [{ id: "a0", x: 0, y: 0 }, { id: "b0", x: 20, y: 0 }] },
      { frame: 1, points: [{ id: "b1", x: 22, y: 0 }, { id: "a1", x: 2, y: 0 }] },
      { frame: 2, points: [{ id: "a2", x: 4, y: 0 }, { id: "b2", x: 24, y: 0 }] },
    ], { pxPerUm: 2, frameIntervalMin: 5, maxDisplacementUm: 3 });
    expect(result.tracks).toHaveLength(2);
    expect(result.tracks[0]).toMatchObject({ durationFrames: 2, durationMin: 10, totalPathLengthUm: 2, netDisplacementUm: 2, meanSpeedUmPerMin: 0.2, directionalityRatio: 1 });
    expect(result.summary.tracksWithMotion).toBe(2);
  });

  it("skeletonizes and attributes neurites while surfacing the overlap caveat", () => {
    const data = new Uint32Array(11 * 7);
    for (let x = 1; x <= 9; x += 1) data[3 * 11 + x] = 1;
    for (let y = 1; y <= 5; y += 1) data[y * 11 + 6] = 1;
    const result = analyzeNeurites({ width: 11, height: 7, data }, [{ id: "soma-1", x: 1, y: 3, radiusPx: 1 }], { pxPerUm: 1 });
    expect(result.totalSkeletonLengthUm).toBeGreaterThan(0);
    expect(result.cells[0].skeletonPixelCount).toBeGreaterThan(0);
    expect(result.cells[0].branchPointCount).toBeGreaterThan(0);
    expect(result.caveat).toMatch(/cannot be reliably separated/);
  });

  it("honours a pre-aborted signal before a full-resolution neurite pass", () => {
    const controller = new AbortController(); controller.abort();
    expect(() => analyzeNeurites({ width: 128, height: 128, data: new Uint32Array(128 * 128).fill(1) }, [], { pxPerUm: 1, signal: controller.signal })).toThrow();
  });

  it("computes one-to-one ground-truth precision, recall and F1", () => {
    const result = matchGroundTruth([{ id: "t1", x: 0, y: 0 }, { id: "t2", x: 10, y: 0 }], [{ id: "d1", x: 1, y: 0 }, { id: "d2", x: 50, y: 0 }], 2);
    expect(result).toMatchObject({ truePositive: 1, falsePositive: 1, falseNegative: 1, precision: 0.5, recall: 0.5, f1: 0.5 });
  });
});

describe("versioned protocols and performance regression", () => {
  it("validates, serializes, parses and atomically applies every protocol field", () => {
    expect(validateAnalysisProtocol(protocol, ["cp-cyto3"])).toBe(protocol);
    const serialized = serializeAnalysisProtocol(protocol);
    expect(serializeAnalysisProtocol(parseAnalysisProtocol(serialized, ["cp-cyto3"]))).toBe(serialized);
    expect(applyAnalysisProtocol(protocol, ["cp-cyto3"])).toEqual({
      modelId: "cp-cyto3", expectedDiameterUm: 20, channels: [1, 0], confidenceThreshold: 0.6, pxPerUm: 2,
      sizeThresholdsUm: [10, 20], backgroundSubtract: true, rollingBallRadiusPx: 50, watershedSplit: true,
      watershedMinDistanceUm: 8, manualMarkerDiameterUm: 12,
    });
    expect(() => validateAnalysisProtocol({ ...protocol, schemaVersion: 2 })).toThrow(/schemaVersion/);
  });

  it("thresholds a million pixels without argument spreading or source copies", () => {
    const values = new Float32Array(1_000_000);
    for (let index = values.length / 2; index < values.length; index += 1) values[index] = 100;
    expect(otsuThreshold(values)).toBe(50);
  });

  it("measures a million-pixel field with bounded default accumulators and cancellation", () => {
    const labels = new Uint32Array(1_000_000).fill(1);
    const pixels = new Uint8Array(1_000_000).fill(2);
    const result = measureCellIntensities({ data: labels, width: 1000, height: 1000 }, { data: pixels, width: 1000, height: 1000, channels: 1 });
    expect(result[0]).toMatchObject({ areaPx: 1_000_000, channels: [{ integrated: 2_000_000, mean: 2, median: null }] });
    const controller = new AbortController(); controller.abort();
    expect(() => measureCellIntensities({ data: labels, width: 1000, height: 1000 }, { data: pixels, width: 1000, height: 1000, channels: 1 }, { signal: controller.signal })).toThrow();
  });
});
