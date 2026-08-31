import { describe, expect, it } from "vitest";
import { createBrowserImageSource } from "../src/domain/source";
import { applyCorrection, compareBatches, measureCells } from "../src/domain/analysis";
import { deterministicJson, exportAnalysisJson, exportCellsCsv } from "../src/domain/export";
import type { AnalysisParameters, AnalysisProvenance, BatchAnalysis, Calibration, CellMeasurement, ImageAnalysis } from "../src/domain/types";
import type { InferenceEngine, WebInferenceRequest } from "../src/models/WebGpuInference";
import { BrowserRepository } from "../src/storage/BrowserRepository";
import { InferenceWorkerClient, type WorkerPort } from "../src/workers/InferenceWorkerClient";
import { createInferenceWorkerController } from "../src/workers/controller";
import type { InferenceWorkerRequest, InferenceWorkerResponse } from "../src/workers/protocol";

const calibration: Calibration = { pxPerUm: 2, source: "manual", confidence: "high" };
const parameters: AnalysisParameters = {
  modelId: "cp-cyto3",
  confidenceThreshold: 0.5,
  expectedDiameterUm: 12,
  channels: [0, 0],
  backgroundSubtract: false,
  rollingBallRadiusPx: 50,
  watershedSplit: true,
  watershedMinDistanceUm: 8,
  sizeThresholdsUm: [10, 20],
};

function fixtureCells() {
  return measureCells([
    { id: "cell-b", centroidPx: { x: 30, y: 30 }, contourPx: [{ x: 26, y: 26 }, { x: 34, y: 26 }, { x: 34, y: 34 }, { x: 26, y: 34 }], confidence: .88, origin: "model" },
    { id: "cell-a", centroidPx: { x: 12, y: 12 }, contourPx: [{ x: 8, y: 8 }, { x: 16, y: 8 }, { x: 16, y: 16 }, { x: 8, y: 16 }], confidence: .94, origin: "model" },
  ], calibration, { widthPx: 64, heightPx: 64 }, parameters.sizeThresholdsUm);
}

class LoopbackWorker implements WorkerPort {
  private listeners = new Set<(event: MessageEvent<InferenceWorkerResponse>) => void>();
  private readonly controller;

  constructor(engine: InferenceEngine) {
    this.controller = createInferenceWorkerController(engine, (data) => queueMicrotask(() => this.listeners.forEach((listener) => listener(new MessageEvent("message", { data })) )));
  }

  postMessage(message: InferenceWorkerRequest): void { this.controller.handle(message); }
  addEventListener(_type: "message", listener: (event: MessageEvent<InferenceWorkerResponse>) => void): void { this.listeners.add(listener); }
  removeEventListener(_type: "message", listener: (event: MessageEvent<InferenceWorkerResponse>) => void): void { this.listeners.delete(listener); }
  terminate(): void { this.controller.cancelAll(); this.listeners.clear(); }
}

function analysis(cells: readonly CellMeasurement[] = fixtureCells()): ImageAnalysis {
  return {
    schemaVersion: 1,
    id: "analysis-1",
    image: { id: "image-1", fileName: "fixture.png", mediaType: "image/png", byteLength: 4, sha256: "a".repeat(64), widthPx: 64, heightPx: 64, importedAt: "2026-08-31T00:00:00.000Z" },
    calibration,
    parameters,
    model: { id: "cp-cyto3", displayName: "Cellpose cyto3", manifestVersion: "1.0.0", artifactSha256: "b".repeat(64), runtime: "onnxruntime-web/webgpu", runtimeVersion: "1.22.0" },
    ranAt: "2026-08-31T00:01:00.000Z",
    cells,
    correctionLog: [],
    imageStats: {},
  };
}

describe("complete private browser workflow", () => {
  it("imports, segments through the Worker contract, measures, corrects, compares, persists, and exports deterministically", async () => {
    const source = createBrowserImageSource(new Blob([new Uint8Array([1, 2, 3, 4])], { type: "image/png" }), { id: "image-1", fileName: "fixture.png" });
    expect(source.blob).toBeInstanceOf(Blob);

    const engine: InferenceEngine = {
      async analyze(request: WebInferenceRequest) {
        request.onProgress?.({ stage: "inference", completed: 1, total: 1 });
        return { imageWidth: 64, imageHeight: 64, cells: fixtureCells(), imageStats: {} };
      },
    };
    const client = new InferenceWorkerClient(new LoopbackWorker(engine));
    const progress: string[] = [];
    const result = await client.analyze({ source, calibration, parameters, onProgress: (event) => progress.push(event.stage) });
    expect(result.cells).toHaveLength(2);
    expect(result.cells[0].areaUm2).toBe(16);
    expect(progress).toContain("inference");

    const corrected = applyCorrection({ cells: result.cells, log: [] }, {
      id: "correction-1",
      appliedAt: "2026-08-31T00:02:00.000Z",
      kind: "add",
      centerPx: { x: 45, y: 45 },
      diameterUm: 8,
    }, { calibration, imageSize: { widthPx: 64, heightPx: 64 }, sizeThresholdsUm: parameters.sizeThresholdsUm });
    expect(corrected.cells).toHaveLength(3);
    expect(corrected.cells.at(-1)?.origin).toBe("manual");

    const stored = analysis(corrected.cells);
    const repository = await BrowserRepository.open({ indexedDB, storageManager: null });
    await repository.putSource(source);
    await repository.putWorkspaceImage({ id: source.id, fileName: source.fileName, mediaType: source.mediaType, widthPx: 64, heightPx: 64, importedAt: "2026-08-31T00:00:00.000Z", condition: "Control", pxPerUm: 2, analysisId: stored.id });
    await repository.putAnalysis(stored);
    expect((await repository.getSource(source.id))?.byteLength).toBe(4);
    expect((await repository.listWorkspaceImages())[0]).toMatchObject({ id: source.id, condition: "Control", analysisId: stored.id });
    expect((await repository.getAnalysis(stored.id))?.cells).toHaveLength(3);

    const second = { ...stored, id: "analysis-2", cells: stored.cells.map((cell) => ({ ...cell, equivalentDiameterUm: cell.equivalentDiameterUm * 1.2 })) };
    const batches: BatchAnalysis[] = [
      { id: "batch-control", name: "Control", condition: "Control", analyses: [stored] },
      { id: "batch-treatment", name: "Treatment", condition: "Treatment", analyses: [second] },
    ];
    const comparison = compareBatches(batches, parameters.sizeThresholdsUm);
    expect(comparison.groups.map((group) => group.condition)).toEqual(["Control", "Treatment"]);
    expect(comparison.mannWhitney).not.toBeNull();

    const provenance: AnalysisProvenance = {
      appVersion: "0.1.0",
      appBuild: "test",
      buildSha: null,
      exportedAt: "2026-08-31T00:03:00.000Z",
      imageSha256: stored.image.sha256,
      model: stored.model,
      calibration,
      parameters,
    };
    const firstJson = exportAnalysisJson(stored, provenance);
    expect(firstJson).toBe(exportAnalysisJson(stored, provenance));
    expect(deterministicJson({ z: 1, a: 2 })).toBe('{\n  "a": 2,\n  "z": 1\n}\n');
    const csv = exportCellsCsv(stored, provenance);
    expect(csv).toContain("# image_sha256:");
    expect(csv.indexOf("cell-a")).toBeLessThan(csv.indexOf("cell-b"));
    repository.close();
    client.dispose();
  });

  it("propagates cancellation through the Worker boundary without a fallback result", async () => {
    const source = createBrowserImageSource(new Blob(["fixture"], { type: "image/png" }), { id: "cancel-image" });
    const engine: InferenceEngine = {
      analyze(request) {
        return new Promise((_resolve, reject) => request.signal?.addEventListener("abort", () => reject(new DOMException("cancelled", "AbortError")), { once: true }));
      },
    };
    const client = new InferenceWorkerClient(new LoopbackWorker(engine));
    const controller = new AbortController();
    const pending = client.analyze({ source, calibration, parameters, signal: controller.signal });
    controller.abort();
    await expect(pending).rejects.toMatchObject({ code: "cancelled" });
    client.dispose();
  });
});
