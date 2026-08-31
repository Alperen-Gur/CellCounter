import { describe, expect, it } from "vitest";
import { applyCorrection, CorrectionHistory, type CorrectionState } from "../../src/domain/corrections";
import { compareBatches } from "../../src/domain/comparison";
import { deterministicJson, exportAnalysisJson, exportCellsCsv } from "../../src/domain/export";
import { measureCell } from "../../src/domain/measurements";
import { createBrowserImageSource } from "../../src/domain/source";
import type { BatchAnalysis, CellGeometry } from "../../src/domain/types";
import { calibration, provenance, sampleAnalysis, sampleCells } from "./fixtures/sample";

describe("browser domain core", () => {
  it("keeps canonical geometry in source pixels and derives calibrated measures", () => {
    const geometry: CellGeometry = {
      id: "square",
      centroidPx: { x: 999, y: 999 },
      contourPx: [{ x: 0, y: 0 }, { x: 4, y: 0 }, { x: 4, y: 4 }, { x: 0, y: 4 }],
      confidence: 0.75,
      origin: "model",
    };
    const result = measureCell(geometry, calibration, { widthPx: 20, heightPx: 20 }, [2, 4]);
    expect(result.centroidPx).toEqual({ x: 2, y: 2 });
    expect(result.centroidUm).toEqual({ x: 1, y: 1 });
    expect(result.areaPx2).toBe(16);
    expect(result.areaUm2).toBe(4);
    expect(result.perimeterPx).toBe(16);
    expect(result.perimeterUm).toBe(8);
    expect(result.circularity).toBeCloseTo(Math.PI / 4);
    expect(result.edgeTouching).toBe(true);
    expect(result.sizeClass).toBe("bin-2");
  });

  it("rejects invalid calibration and degenerate cell geometry", () => {
    expect(() => measureCell(
      { id: "bad", centroidPx: { x: 0, y: 0 }, contourPx: [], confidence: 1, origin: "manual" },
      { ...calibration, pxPerUm: 0 },
      { widthPx: 1, heightPx: 1 },
    )).toThrow(/pxPerUm/);
  });

  it("applies deterministic add, remove, merge and split corrections", () => {
    const context = { calibration, imageSize: { widthPx: 100, heightPx: 100 }, sizeThresholdsUm: [2, 4] };
    let state: CorrectionState = { cells: sampleCells(), log: [] };
    state = applyCorrection(state, {
      id: "add-1", appliedAt: "2026-08-31T10:00:00.000Z", kind: "add", centerPx: { x: 10, y: 10 }, diameterUm: 2,
    }, context);
    expect(state.cells.map((cell) => cell.id)).toContain("add-1:cell");
    state = applyCorrection(state, {
      id: "merge-1", appliedAt: "2026-08-31T10:01:00.000Z", kind: "merge", cellIds: ["cell-1", "add-1:cell"],
    }, context);
    expect(state.cells.map((cell) => cell.id)).toEqual(["merge-1:cell"]);
    state = applyCorrection(state, {
      id: "split-1", appliedAt: "2026-08-31T10:02:00.000Z", kind: "split", cellId: "merge-1:cell",
      line: [{ x: 5, y: -10 }, { x: 5, y: 20 }],
    }, context);
    expect(state.cells.map((cell) => cell.id).sort()).toEqual(["split-1:cell-1", "split-1:cell-2"]);
    state = applyCorrection(state, {
      id: "remove-1", appliedAt: "2026-08-31T10:03:00.000Z", kind: "remove", cellIds: ["split-1:cell-1"],
    }, context);
    expect(state.cells).toHaveLength(1);
    expect(state.log.map((entry) => entry.kind)).toEqual(["add", "merge", "split", "remove"]);
  });

  it("supports bounded correction undo and redo without mutable cell aliases", () => {
    const initial = { cells: sampleCells(), log: [] };
    const history = new CorrectionHistory(initial, 2);
    const context = { calibration, imageSize: { widthPx: 100, heightPx: 100 }, sizeThresholdsUm: [2, 4] };
    history.apply({
      id: "remove", appliedAt: "2026-08-31T10:00:00.000Z", kind: "remove", cellIds: ["cell-1"],
    }, context);
    expect(history.state.cells).toHaveLength(0);
    expect(history.undo().cells).toHaveLength(1);
    expect(history.redo().cells).toHaveLength(0);
  });

  it("produces deterministic batch summaries and two-group statistics", () => {
    const batches: BatchAnalysis[] = [
      { id: "b", name: "B", condition: "treated", analyses: [sampleAnalysis("b", 20), sampleAnalysis("b2", 30), sampleAnalysis("b3", 40)] },
      { id: "a", name: "A", condition: "control", analyses: [sampleAnalysis("a"), sampleAnalysis("a2", 5), sampleAnalysis("a3", 10)] },
    ];
    const result = compareBatches(batches, [2, 4]);
    expect(result.groups.map((group) => group.batchId)).toEqual(["a", "b"]);
    expect(result.groups.map((group) => group.cellCount)).toEqual([3, 3]);
    expect(result.mannWhitney).not.toBeNull();
    expect(result.mannWhitney?.pValue).toBeGreaterThanOrEqual(0);
    expect(result.mannWhitney?.pValue).toBeLessThanOrEqual(1);
  });

  it("serializes JSON and CSV deterministically with complete provenance", () => {
    const analysis = sampleAnalysis();
    const json = exportAnalysisJson(analysis, provenance);
    expect(exportAnalysisJson(analysis, provenance)).toBe(json);
    expect(json).toContain('"artifactSha256"');
    const csv = exportCellsCsv(analysis, provenance);
    expect(exportCellsCsv(analysis, provenance)).toBe(csv);
    expect(csv).toContain("# model_artifact_sha256:");
    expect(csv).toContain("centroid_x_px,centroid_y_px");
    expect(deterministicJson({ z: 1, a: { y: 2, b: 3 } })).toBe('{\n  "a": {\n    "b": 3,\n    "y": 2\n  },\n  "z": 1\n}\n');
  });

  it("accepts Blob/File sources without ever introducing a native path", () => {
    const blob = new Blob([new Uint8Array([1, 2, 3])], { type: "image/png" });
    const source = createBrowserImageSource(blob, { id: "source", fileName: "cells.png" });
    expect(source.blob).toBe(blob);
    expect(source.byteLength).toBe(3);
    expect(source).not.toHaveProperty("path");
  });
});
