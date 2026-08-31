import { describe, expect, it } from "vitest";
import {
  assessImageQuality,
  cellCycleHistogram,
  colocalization,
  confluenceFromMask,
  detectPuncta,
  markerPositivity,
  measureCellIntensities,
  nuclearCytoplasmicRatio,
  sampleLineProfile,
  scratchWoundSeries,
  spatialStatistics,
  spheroidAnalysis,
  viability,
  type CellIntensity,
  type LabelMap,
  type Raster,
} from "../../src/analysis";

const labels: LabelMap = { width: 4, height: 2, data: new Uint32Array([1, 1, 2, 2, 1, 1, 2, 2]) };
const raster: Raster = {
  width: 4, height: 2, channels: 2,
  data: new Float32Array([2, 1, 2, 1, 10, 20, 10, 20, 2, 1, 2, 1, 10, 20, 10, 20]),
};

describe("intensity assays", () => {
  it("measures source pixels and preserves dead-channel precedence", () => {
    const cells = measureCellIntensities(labels, raster, { includeMedian: true });
    expect(cells.map(({ areaPx }) => areaPx)).toEqual([4, 4]);
    expect(cells[0].channels[0]).toMatchObject({ mean: 2, integrated: 8, median: 2 });
    expect(markerPositivity(cells, { channel: 0, threshold: { mode: "manual", value: 5 } })).toMatchObject({ positiveCount: 1, percentPositive: 50 });
    const result = viability(cells, {
      liveChannel: 0, deadChannel: 1,
      liveThreshold: { mode: "manual", value: 1 }, deadThreshold: { mode: "manual", value: 5 },
    });
    expect(result).toMatchObject({ liveCount: 1, deadCount: 1, doublePositiveCount: 1, percentViable: 50 });
    expect(result.perCell.find(({ label }) => label === 2)?.state).toBe("dead");
  });

  it("computes nuclear:cytoplasmic ratios from aligned source pixels", () => {
    const cellLabels = { width: 4, height: 4, data: new Uint32Array(16).fill(1) };
    const nuclei = { width: 4, height: 4, data: new Uint32Array([0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0]) };
    const intensities = new Float32Array(16).fill(2);
    for (const index of [5, 6, 9, 10]) intensities[index] = 10;
    const result = nuclearCytoplasmicRatio(cellLabels, nuclei, { width: 4, height: 4, channels: 1, data: intensities }, { channel: 0 });
    expect(result).toMatchObject({ cellCount: 1, skippedCount: 0, meanRatio: 5, medianRatio: 5 });
  });

  it("reports pixel-level Pearson and thresholded Manders, not cell-mean correlation", () => {
    const image = { width: 2, height: 2, channels: 2, data: new Float32Array([0, 0, 1, 2, 2, 4, 3, 6]) };
    const result = colocalization({ width: 2, height: 2, data: new Uint32Array(4).fill(1) }, image, { channelA: 0, channelB: 1, threshold: { mode: "zero" } });
    expect(result.image.pearson).toBeCloseTo(1, 12);
    expect(result.image.mandersM1).toBeCloseTo(1, 12);
    expect(result.image.mandersM2).toBeCloseTo(1, 12);
    expect(result.thresholds.note).toMatch(/threshold-dependent/);
  });

  it("gates a two-peak DNA histogram and labels every cell as an estimate", () => {
    const cells: CellIntensity[] = Array.from({ length: 24 }, (_, index) => ({
      label: index + 1, areaPx: 1,
      channels: [{ channel: 0, mean: index < 14 ? 100 : 200, median: index < 14 ? 100 : 200, integrated: (index < 14 ? 100 : 200) + (index % 3 - 1) }],
    }));
    const result = cellCycleHistogram(cells, { channel: 0, bins: 32 });
    expect(result.cellCount).toBe(24);
    expect(Object.values(result.counts).reduce((sum, count) => sum + count, 0)).toBe(24);
    expect(result.g2Peak / result.g1Peak).toBeGreaterThan(1.6);
    expect(result.caveat).toMatch(/flow cytometry/);
  });
});

describe("region, puncta, profile, spatial and QC assays", () => {
  it("measures confluence, wound closure and calibrated spheroid geometry", () => {
    const mask = (middleWidth: number): LabelMap => {
      const data = new Uint32Array(6 * 4).fill(1);
      const start = Math.floor((6 - middleWidth) / 2);
      for (let y = 0; y < 4; y += 1) for (let x = start; x < start + middleWidth; x += 1) data[y * 6 + x] = 0;
      return { width: 6, height: 4, data };
    };
    expect(confluenceFromMask(mask(2), 2).coveragePct).toBeCloseTo(66.6666667);
    const wound = scratchWoundSeries([mask(2), mask(1)], { pxPerUm: 2, timepointsHours: [0, 4] });
    expect(wound.totalPercentClosure).toBe(50);
    expect(wound.closureRateUm2PerHour).toBe(0.25);
    const objectMask = { width: 5, height: 5, data: new Uint32Array([0,0,0,0,0, 0,1,1,1,0, 0,1,1,1,0, 0,1,1,1,0, 0,0,0,0,0]) };
    const spheroid = spheroidAnalysis(objectMask, { pxPerUm: 1 });
    expect(spheroid).toMatchObject({ count: 1 });
    expect(spheroid.objects[0]).toMatchObject({ areaUm2: 9, perimeterUm: 12, centroidXpx: 2, centroidYpx: 2 });
  });

  it("detects and assigns a punctum without mutating source arrays", () => {
    const data = new Float32Array(81); data[4 * 9 + 4] = 100;
    const source = new Float32Array(data);
    const result = detectPuncta({ width: 9, height: 9, channels: 1, data }, { width: 9, height: 9, data: new Uint32Array(81).fill(7) }, { threshold: 0.05, minimumDistancePx: 2 });
    expect(result.spots).toHaveLength(1);
    expect(result.spots[0]).toMatchObject({ xPx: 4, yPx: 4, assignedCellLabel: 7 });
    expect(data).toEqual(source);
  });

  it("bilinearly samples RGB/luminance and reports calibrated distance", () => {
    const samples = sampleLineProfile({ width: 2, height: 2, channels: 3, data: new Float32Array([0,0,0, 10,20,30, 0,0,0, 10,20,30]) }, { x: 0, y: 0 }, { x: 1, y: 0 }, { stepPx: 0.5, pxPerUm: 2 });
    expect(samples).toHaveLength(3);
    expect(samples[1].channels).toEqual([5, 10, 15]);
    expect(samples[2].distanceUm).toBe(0.5);
  });

  it("computes nearest-neighbour, density and Clark–Evans with an edge caveat", () => {
    const result = spatialStatistics([{ id: "a", x: 0, y: 0 }, { id: "b", x: 10, y: 0 }, { id: "c", x: 20, y: 0 }], { widthPx: 100, heightPx: 100, pxPerUm: 2, densityRadiusUm: 6 });
    expect(result.meanNearestNeighborUm).toBe(5);
    expect(result.localDensityPerMm2.a).toBeGreaterThan(0);
    expect(result.caveat).toMatch(/edge/);
  });

  it("distinguishes a sharp checkerboard from a flat image", () => {
    const checker = new Uint8Array(64);
    for (let y = 0; y < 8; y += 1) for (let x = 0; x < 8; x += 1) checker[y * 8 + x] = (x + y) % 2 ? 255 : 0;
    const sharp = assessImageQuality({ width: 8, height: 8, channels: 1, data: checker }, { blockSizePx: 4 });
    const flat = assessImageQuality({ width: 8, height: 8, channels: 1, data: new Uint8Array(64).fill(20) }, { blockSizePx: 4 });
    expect(sharp.focusScore).toBeGreaterThan(flat.focusScore);
    expect(flat.illuminationResidual).toBe(0);
  });
});
