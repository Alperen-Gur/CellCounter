import test from "node:test";
import assert from "node:assert/strict";
import { AnalysisQueue, settingsKey } from "../src/kernel/workflow/AnalysisQueue.ts";
import type { AnalysisJob, QueueRuntime } from "../src/kernel/workflow/AnalysisQueue.ts";

const params = { modelId: "cp-cyto3", pxPerUm: 1, confidenceThreshold: .5, channels: [0,0] as [number,number], backgroundSubtract: false, rollingBallRadius: 50, watershedSplit: false, watershedMinDistanceUm: 8, smallThresholdUm: 20, largeThresholdUm: 30, expectedDiameterUm: 0, useGpu: false };
function setup(initial: AnalysisJob[] = []) {
  let saved = structuredClone(initial);
  const calls: string[] = [];
  const results = new Map<string,string>();
  const runtime: QueueRuntime = {
    load: async () => structuredClone(saved), save: async jobs => { saved = structuredClone([...jobs]); },
    available: async () => ({ installed: true }),
    detect: async item => { calls.push(item.imageId); return { cells: [], imageWidth: 100, imageHeight: 100 }; },
    commit: async item => { const id = crypto.randomUUID(); results.set(item.imageId, id); return id; },
    resultExists: async item => results.get(item.imageId) === item.detectionId,
  };
  return { queue: new AnalysisQueue(runtime), runtime, calls, results, saved: () => saved };
}
async function create(queue: AnalysisQueue) {
  return queue.create({ batchId: "batch", name: "Study", task: "countCells", calibrationSource: "manual", params,
    items: ["a","b","c"].map(imageId => ({ imageId, path: imageId, fileName: `${imageId}.png`, status: "pending" })) });
}

test("imports are saved as drafts without requiring a model or starting detection", async () => {
  const { queue, runtime, calls, saved } = setup(); runtime.available = async () => { throw new Error("not installed"); };
  await create(queue); assert.equal(saved()[0].status, "draft"); assert.deepEqual(calls, []);
});
test("representative preview is reused by the batch only for matching settings and saved detection", async () => {
  const { queue, calls, results } = setup(); const id = await create(queue);
  await queue.run(id, "b"); assert.equal(queue.getSnapshot()[0].status, "draft");
  await queue.run(id); assert.deepEqual(calls, ["b","a","c"]);
  results.delete("b"); await queue.run(id); assert.deepEqual(calls, ["b","a","c","b"]);
  await queue.update(id, { ...params, expectedDiameterUm: 25 }, "countCells", "manual");
  await queue.run(id); assert.equal(calls.length, 7);
});
test("pause finishes the current image and recovery resumes remaining images", async () => {
  const context = setup(); const id = await create(context.queue);
  context.runtime.detect = async item => { context.calls.push(item.imageId); context.queue.pause(id); return { cells: [], imageWidth: 100, imageHeight: 100 }; };
  await context.queue.run(id); assert.equal(context.queue.getSnapshot()[0].status, "paused"); assert.deepEqual(context.calls, ["a"]);
  const restored = new AnalysisQueue({ ...context.runtime, detect: async item => { context.calls.push(item.imageId); return { cells: [], imageWidth: 100, imageHeight: 100 }; } });
  await restored.run(id); assert.deepEqual(context.calls, ["a","b","c"]); assert.equal(restored.getSnapshot()[0].status, "completed");
});
test("interrupted in-flight jobs become paused and never start on launch", async () => {
  const context = setup(); await create(context.queue);
  const interrupted = structuredClone(context.saved()); interrupted[0].status = "running"; interrupted[0].items[0].status = "running";
  const restored = setup(interrupted); await restored.queue.initialize();
  assert.equal(restored.queue.getSnapshot()[0].status, "paused"); assert.equal(restored.queue.getSnapshot()[0].items[0].status, "pending"); assert.deepEqual(restored.calls, []);
});
test("retry preserves successful images and reports missing models against a saved job", async () => {
  const context = setup(); const id = await create(context.queue); let fail = true;
  context.runtime.detect = async item => { context.calls.push(item.imageId); if (item.imageId === "b" && fail) throw new Error("test failure"); return { cells: [], imageWidth: 10, imageHeight: 10 }; };
  await context.queue.run(id); assert.equal(context.queue.getSnapshot()[0].status, "failed"); fail = false;
  await context.queue.run(id); assert.deepEqual(context.calls, ["a","b","c","b"]);
  context.runtime.available = async () => ({ installed: false, reason: "Install the model" });
  await assert.rejects(context.queue.run(id), /Install the model/); assert.equal(context.saved()[0].error, "Install the model");
});
test("failed persistence leaves last durable state intact and settings key ignores property order", async () => {
  const context = setup(); const id = await create(context.queue);
  context.runtime.save = async () => { throw new Error("disk full"); };
  await assert.rejects(context.queue.update(id, { ...params, pxPerUm: 2 }, "countCells", "manual"), /disk full/);
  assert.equal(context.queue.getSnapshot()[0].params.pxPerUm, 1);
  assert.equal(settingsKey(params), settingsKey({ ...params, modelId: "cp-cyto3" }));
});
