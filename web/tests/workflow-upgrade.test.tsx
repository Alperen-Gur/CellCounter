import { afterEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, cleanup } from "@testing-library/react";
import { BrowserRepository } from "../src/storage/BrowserRepository";
import { DurableQueueRunner, compareMaskVariants, estimatedRemainingMs, previewKey, recoverJob, restoreVariant, retryJob, type AnalysisJob, type RunSnapshot } from "../src/app/workflow";
import { ClassicalInference, segmentPlane, watershedLabels } from "../src/models/ClassicalInference";
import { handleKeyboard, type KeyActions } from "../src/hooks/useKeyboard";
import { LinkedMeasurements } from "../src/components/LinkedMeasurements";
import { ReviewView } from "../src/views/ReviewView";
import { calibration, parameters, sampleAnalysis } from "./core/fixtures/sample";
import type { WorkspaceImage } from "../src/app/types";

const frozen: RunSnapshot = { calibration, parameters: { ...parameters, modelId: "classical", watershedSplit: false, minimumAreaPx: 4 }, model: { id: "classical", displayName: "Classical threshold + watershed", manifestVersion: "1.0.0", artifactSha256: "not-applicable:bundled-algorithm", runtime: "browser/classical", runtimeVersion: "1.0.0" } };
function job(): AnalysisJob { return { id: "queue-test", createdAt: "2026-09-08T00:00:00Z", updatedAt: "2026-09-08T00:00:00Z", state: "paused", settings: frozen, items: ["a", "b", "c"].map((imageId) => ({ imageId, fileName: `${imageId}.png`, sourceSha256: "a".repeat(64), calibration, state: "pending" })) }; }
afterEach(cleanup);

function twoSquares() {
  const values = new Float32Array(24 * 16);
  for (let y = 3; y < 7; y++) for (let x = 3; x < 7; x++) values[y * 24 + x] = 200;
  for (let y = 8; y < 13; y++) for (let x = 15; x < 20; x++) values[y * 24 + x] = 100;
  return { width: 24, height: 16, values };
}

describe("real classical segmentation", () => {
  it("segments actual intensity pixels into measured instance contours with no weights or network", () => {
    const plane = twoSquares();
    const result = segmentPlane(plane, { ...frozen.parameters, thresholdMethod: "otsu" }, calibration);
    expect(result.cells).toHaveLength(2);
    expect(result.cells.map((cell) => cell.areaPx2)).toEqual([16, 25]);
    expect(result.cells[0].areaUm2).toBe(16 / calibration.pxPerUm ** 2);
    expect(result.cells[0].contourPx).toHaveLength(4);
    expect(plane.values[3 * 24 + 3]).toBe(200);
    const high = segmentPlane(plane, { ...frozen.parameters, thresholdMethod: "manual", manualThreshold: .75 }, calibration);
    expect(high.cells).toHaveLength(1);
    expect(high.cells[0].areaPx2).toBe(16);
    expect(segmentPlane(plane, { ...frozen.parameters, minimumAreaPx: 20 }, calibration).cells.map((cell) => cell.areaPx2)).toEqual([25]);
  });
  it("handles dark objects, blank fields, triangle and adaptive thresholds without fabricating learned detections", () => {
    const plane = twoSquares();
    const inverse = { ...plane, values: plane.values.map((value) => 200 - value) };
    expect(segmentPlane(inverse, { ...frozen.parameters, thresholdMethod: "manual", manualThreshold: .75, invert: true }, calibration).cells).toHaveLength(2);
    expect(segmentPlane({ width: 5, height: 5, values: new Float32Array(25).fill(12) }, frozen.parameters, calibration).cells).toHaveLength(0);
    for (const thresholdMethod of ["triangle", "adaptive"] as const) expect(segmentPlane(plane, { ...frozen.parameters, thresholdMethod, expectedDiameterUm: 4 }, calibration).cells.length).toBeGreaterThan(0);
  });
  it("watershed separates two touching peaks and conserves all foreground pixels", () => {
    const width = 35; const height = 21; const binary = new Uint8Array(width * height);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) if (Math.hypot(x - 11, y - 10) < 8 || Math.hypot(x - 23, y - 10) < 8) binary[y * width + x] = 1;
    const labels = watershedLabels(binary, width, height, 10);
    expect(new Set(labels).size).toBe(3);
    expect(Array.from(labels).filter(Boolean)).toHaveLength(Array.from(binary).filter(Boolean).length);
  });
  it("does not split isolated round objects into spurious distance ridges", () => {
    const width = 320; const height = 200; const values = new Float32Array(width * height);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) if (Math.hypot(x - 80, y - 95) < 25 || Math.hypot(x - 215, y - 95) < 33) values[y * width + x] = 200;
    expect(segmentPlane({ width, height, values }, { ...frozen.parameters, watershedSplit: true, watershedMinDistanceUm: 8 }, { ...calibration, pxPerUm: 1 }).cells).toHaveLength(2);
  });
  it("rejects another model identity and pre-cancelled processing", async () => {
    const engine = new ClassicalInference();
    const source = { id: "test", fileName: "test.png", byteLength: 1, lastModified: null, mediaType: "image/png", blob: new Blob(["x"]) };
    await expect(engine.analyze({ source, parameters, calibration })).rejects.toThrow(/explicitly selected/);
    const controller = new AbortController(); controller.abort();
    await expect(engine.analyze({ source, parameters: frozen.parameters, calibration, signal: controller.signal })).rejects.toMatchObject({ name: "AbortError" });
  });
});

describe("durable processing and preview reuse", () => {
  it("persists running transitions before processing and resumes without repeating completed images", async () => {
    const repo = await BrowserRepository.open({ storageManager: null });
    try {
      const processed: string[] = [];
      let runner: DurableQueueRunner;
      runner = new DurableQueueRunner({ persist: (next) => repo.putJob(next), changed: () => {}, process: async (item, snapshot) => {
        expect((await repo.listJobs()).find((next) => next.id === "queue-test")?.items.find((next) => next.imageId === item.imageId)?.state).toBe("running");
        expect(snapshot).toEqual(frozen);
        processed.push(item.imageId); if (item.imageId === "a") runner.pause(); return { reusedPreview: true };
      } });
      const paused = await runner.run(job());
      expect(paused.state).toBe("paused"); expect(paused.items.map((item) => item.state)).toEqual(["complete", "pending", "pending"]);
      const done = await runner.run(paused);
      expect(done.state).toBe("complete"); expect(processed).toEqual(["a", "b", "c"]);
      expect((await repo.listJobs()).find((next) => next.id === done.id)).toEqual(done);
      await repo.putPreview({ id: "a", imageId: "a", key: previewKey("a".repeat(64), frozen), analysis: sampleAnalysis() });
      expect((await repo.getPreview("a"))?.analysis.cells).toHaveLength(1);
      await repo.putVariant({ id: "variant", imageId: "a", name: "Before change", createdAt: "2026-09-08", analysis: sampleAnalysis() });
      expect(await repo.listVariants("b")).toHaveLength(0);
      expect(await repo.listVariants("a")).toHaveLength(1);
    } finally { repo.close(); }
  });
  it("retains successful results across retry, and startup recovery pauses interrupted jobs", async () => {
    let fail = true; const processed: string[] = [];
    const runner = new DurableQueueRunner({ persist: async () => {}, changed: () => {}, process: async (item) => { processed.push(item.imageId); if (item.imageId === "b" && fail) throw new Error("decoder failed"); return { reusedPreview: false }; } });
    const failed = await runner.run(job());
    expect(failed.state).toBe("failed"); expect(failed.items.map((item) => item.state)).toEqual(["complete", "failed", "complete"]);
    fail = false; expect((await runner.run(retryJob(failed))).state).toBe("complete");
    expect(processed).toEqual(["a", "b", "c", "b"]);
    const interrupted = recoverJob({ ...failed, state: "running", items: failed.items.map((item) => item.imageId === "b" ? { ...item, state: "running" } : item) });
    expect(interrupted.state).toBe("paused"); expect(interrupted.items.map((item) => item.state)).toEqual(["complete", "pending", "complete"]);
    expect(recoverJob(interrupted)).toBe(interrupted);
  });
  it("cancels only the current image, leaving pending work resumable", async () => {
    const runner = new DurableQueueRunner({ persist: async () => {}, changed: () => {}, process: async (_item, _snapshot, signal) => { runner.cancel(); signal.throwIfAborted(); return { reusedPreview: false }; } });
    const result = await runner.run(job());
    expect(result.state).toBe("paused"); expect(result.items.every((item) => item.state === "pending")).toBe(true);
  });
  it("blocks execution when persistence fails, and rejects a concurrent runner", async () => {
    const process = vi.fn();
    await expect(new DurableQueueRunner({ persist: async () => { throw new Error("quota"); }, changed: () => {}, process }).run(job())).rejects.toThrow("quota");
    expect(process).not.toHaveBeenCalled();
  });
  it("reuses only the exact source, calibration, model and all analysis settings; ETA excludes reused previews", () => {
    const baseline = previewKey("a".repeat(64), frozen);
    expect(previewKey("a".repeat(64), structuredClone(frozen))).toBe(baseline);
    for (const patch of [{ projection: "max" }, { sourceChannel: 1 }, { watershedSplit: true }, { backgroundSubtract: true }, { minimumAreaPx: 99 }, { manualThreshold: .8 }, { thresholdMethod: "manual" }, { invert: true }] as const) expect(previewKey("a".repeat(64), { ...frozen, parameters: { ...frozen.parameters, ...patch } })).not.toBe(baseline);
    expect(previewKey("b".repeat(64), frozen)).not.toBe(baseline);
    expect(previewKey("a".repeat(64), { ...frozen, calibration: { ...calibration, pxPerUm: 3 } })).not.toBe(baseline);
    expect(previewKey("a".repeat(64), { ...frozen, model: { ...frozen.model, runtimeVersion: "next" } })).not.toBe(baseline);
    const current = job();
    expect(estimatedRemainingMs(current)).toBeNull();
    expect(estimatedRemainingMs({ ...current, items: [{ ...current.items[0], state: "complete", durationMs: 1000 }, current.items[1], current.items[2]] })).toBe(2000);
  });
});

describe("linked review, variants and contextual shortcuts", () => {
  it("restores mask geometry and original run identity while honoring changed measurement calibration", () => {
    const analysis = sampleAnalysis();
    const restored = restoreVariant({ id: "v", imageId: "i", name: "Earlier", createdAt: "", analysis }, { ...calibration, pxPerUm: calibration.pxPerUm * 2 });
    expect(restored.cells[0].areaUm2).toBe(analysis.cells[0].areaUm2 / 4);
    expect(restored.cells[0].contourPx).toEqual(analysis.cells[0].contourPx);
    expect(restored.model).toEqual(analysis.model);
    expect(restored.workflow?.runCalibration).toEqual(analysis.calibration);
    expect(compareMaskVariants(analysis, restored)).toEqual({ added: 0, removed: 0, changed: 0, unchanged: 1 });
    expect(compareMaskVariants(analysis, { ...analysis, cells: [] })).toMatchObject({ removed: 1 });
  });
  it("links a selected object outside the initial page without rendering the entire population", () => {
    const cells = Array.from({ length: 1500 }, (_, index) => ({ id: `cell-${index}`, cx: index, cy: 1, diameterPx: 10, diameterUm: 10, confidence: .5, areaUm2: 50 }));
    const onSelect = vi.fn();
    render(<LinkedMeasurements cells={cells} selectedId="cell-1499" onSelect={onSelect} />);
    expect(screen.getAllByRole("row")).toHaveLength(51);
    expect(screen.getByText("Page 30 of 30")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "cell-1499" }));
    expect(onSelect).toHaveBeenCalledWith("cell-1499");
    expect(document.querySelectorAll("svg circle").length).toBeLessThanOrEqual(600);
  });
  it("caps a 1,500-object review at 100 cards and lets accepted objects leave a low-confidence field", () => {
    const image = { id: "i", fileName: "many.png", reviewConfidence: "low", cells: Array.from({ length: 1500 }, (_, index) => ({ id: `cell-${index}`, diameterUm: 10, confidence: .3, reviewed: index === 0 })) } as WorkspaceImage;
    render(<ReviewView images={[image]} onOpen={vi.fn()} onAccept={vi.fn()} onReject={vi.fn()} onResize={vi.fn()} />);
    expect(screen.getAllByRole("listitem")).toHaveLength(100);
    expect(screen.getByText("1499")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Next 100" }));
    expect(screen.getAllByRole("listitem")).toHaveLength(100);
    expect(screen.getByText("101–200 of 1499")).toBeInTheDocument();
  });
  it("keeps typing, dialogs, unsupported screens and modified keys out of workspace actions", () => {
    const actions: KeyActions = { route: "models", hasImage: true, importImages: vi.fn(), run: vi.fn(), cancel: vi.fn(), exportResults: vi.fn(), setTool: vi.fn(), toggleTheme: vi.fn(), showHelp: vi.fn(), closeDialog: vi.fn() };
    handleKeyboard(new KeyboardEvent("keydown", { key: "Enter", ctrlKey: true }), actions); expect(actions.run).not.toHaveBeenCalled();
    handleKeyboard(new KeyboardEvent("keydown", { key: "1" }), actions); expect(actions.setTool).not.toHaveBeenCalled();
    handleKeyboard(new KeyboardEvent("keydown", { key: "i", ctrlKey: true }), { ...actions, route: "workspace" }); expect(actions.importImages).not.toHaveBeenCalled();
    handleKeyboard(new KeyboardEvent("keydown", { key: "Enter", ctrlKey: true }), { ...actions, route: "workspace" }); expect(actions.run).toHaveBeenCalledOnce();
    handleKeyboard(new KeyboardEvent("keydown", { key: "Escape" }), { ...actions, modalOpen: true, busy: true }); expect(actions.closeDialog).toHaveBeenCalledOnce(); expect(actions.cancel).not.toHaveBeenCalled();
    const input = document.createElement("input"); document.body.append(input);
    const event = new KeyboardEvent("keydown", { key: "t" }); Object.defineProperty(event, "target", { value: input }); handleKeyboard(event, actions); expect(actions.toggleTheme).not.toHaveBeenCalled(); input.remove();
  });
});
