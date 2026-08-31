import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { enforceLoadedSourceLimit, historySnapshot } from "../src/App";
import type { WorkspaceImage } from "../src/app/types";
import { DebouncedByIdWriter } from "../src/app/debouncedMetadata";
import { Filmstrip } from "../src/components/Filmstrip";
import { polygonArea } from "../src/domain/geometry";
import {
  IncrementalLabelStitcher,
  ReusableSessionSlot,
  disposeTileTensors,
  labelMapToGeometry,
} from "../src/models/WebGpuInference";
import { confluenceAndMaskFromIntensity } from "../src/analysis/area";
import { connectedComponents } from "../src/analysis/math";
import { assayNeedsCellLabels } from "../src/workers/assay.worker";
import { workspaceExportNeedsLabelMap } from "../src/workers/workspace-export.worker";

function workspace(id: string, sourceLoaded = true): WorkspaceImage {
  return {
    id,
    file: new File([id], `${id}.png`, { type: "image/png" }),
    fileName: `${id}.png`,
    objectUrl: sourceLoaded ? `blob:source-${id}` : "",
    thumbnailUrl: `blob:thumb-${id}`,
    sourceLoaded,
    width: 16,
    height: 16,
    importedAt: "2026-08-31T00:00:00.000Z",
    cells: [{ id: `cell-${id}`, cx: 4, cy: 4, diameterPx: 4, diameterUm: 4, confidence: 0.5, contourPx: [[2, 2], [6, 2], [6, 6], [2, 6]] }],
    condition: "Control",
    pxPerUm: 1,
    groundTruth: [],
    rois: [],
    note: "",
    reviewConfidence: "high",
  };
}

describe("bounded inference allocation", () => {
  it("stitches tile maps as they arrive and preserves overlap unions", () => {
    const stitcher = new IncrementalLabelStitcher(5, 1);
    stitcher.add({ originX: 0, originY: 0, width: 3, height: 1, labels: new Uint32Array([1, 1, 1]) });
    stitcher.add({ originX: 2, originY: 0, width: 3, height: 1, labels: new Uint32Array([7, 7, 0]) });
    expect([...stitcher.finish()]).toEqual([1, 1, 1, 1, 0]);
  });

  it("turns a dense megapixel label into four boundary vertices, not a million point objects", () => {
    const side = 1024;
    const geometry = labelMapToGeometry(new Uint32Array(side * side).fill(1), side);
    expect(geometry).toHaveLength(1);
    expect(geometry[0].contourPx).toHaveLength(4);
    expect(polygonArea(geometry[0].contourPx)).toBe(side * side);
    expect(geometry[0].centroidPx).toEqual({ x: side / 2, y: side / 2 });
  });

  it("reuses same-key sessions, releases on switch/dispose, and disposes every tile tensor", async () => {
    const first = { release: vi.fn() };
    const second = { release: vi.fn() };
    const slot = new ReusableSessionSlot<typeof first>();
    const createFirst = vi.fn(async () => first);
    expect(await slot.acquire("model-a", createFirst)).toBe(first);
    expect(await slot.acquire("model-a", createFirst)).toBe(first);
    expect(createFirst).toHaveBeenCalledTimes(1);
    expect(await slot.acquire("model-b", async () => second)).toBe(second);
    expect(first.release).toHaveBeenCalledTimes(1);
    await slot.dispose();
    expect(second.release).toHaveBeenCalledTimes(1);

    const input = { data: new Float32Array(), dims: [], dispose: vi.fn() };
    const outputA = { data: new Uint32Array(), dims: [], dispose: vi.fn() };
    const outputB = { data: new Uint32Array(), dims: [], dispose: vi.fn() };
    await disposeTileTensors(input, { a: outputA, b: outputB });
    expect(input.dispose).toHaveBeenCalledOnce();
    expect(outputA.dispose).toHaveBeenCalledOnce();
    expect(outputB.dispose).toHaveBeenCalledOnce();
  });
});

describe("bounded workspace and assay work", () => {
  it("debounces metadata per image without dropping a pending write during image switches", async () => {
    vi.useFakeTimers();
    try {
      const persisted = vi.fn<(value: { id: string; note: string }) => void>();
      const writer = new DebouncedByIdWriter(350, persisted);
      writer.queue({ id: "image-a", note: "A" });
      writer.queue({ id: "image-b", note: "B" });
      await vi.advanceTimersByTimeAsync(349);
      expect(persisted).not.toHaveBeenCalled();
      await vi.advanceTimersByTimeAsync(1);
      expect(persisted).toHaveBeenCalledTimes(2);
      expect(persisted.mock.calls.map(([value]) => value)).toEqual([
        { id: "image-a", note: "A" },
        { id: "image-b", note: "B" },
      ]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("keeps only the recent two source rasters while preserving thumbnails and compact cell summaries", () => {
    const revoke = vi.fn();
    Object.defineProperty(URL, "revokeObjectURL", { configurable: true, value: revoke });
    const limited = enforceLoadedSourceLimit([workspace("a"), workspace("b"), workspace("c")], ["c", "b"]);
    expect(limited.filter((image) => image.sourceLoaded)).toHaveLength(2);
    expect(limited[0]).toMatchObject({ objectUrl: "", thumbnailUrl: "blob:thumb-a", sourceLoaded: false });
    expect(limited[0].cells[0].contourPx).toBeUndefined();
    expect(revoke).toHaveBeenCalledWith("blob:source-a");
    Reflect.deleteProperty(URL, "revokeObjectURL");
  });

  it("renders list imagery from thumbnail URLs and snapshots immutable history by reference", () => {
    const image = workspace("thumb");
    const html = renderToStaticMarkup(<Filmstrip images={[image]} activeId={image.id} onSelect={() => undefined} onImport={() => undefined} />);
    expect(html).toContain("blob:thumb-thumb");
    expect(html).not.toContain("blob:source-thumb");
    const snapshot = historySnapshot(image);
    expect(snapshot.cells).toBe(image.cells);
    expect(snapshot.groundTruth).toBe(image.groundTruth);
    expect(snapshot.rois).toBe(image.rois);
  });

  it("rasterizes cells only for consuming assays and labels only mask exports", () => {
    expect(["qc", "line-profile", "area", "neurite"].map((kind) => assayNeedsCellLabels(kind as Parameters<typeof assayNeedsCellLabels>[0]))).toEqual([false, false, false, false]);
    expect(assayNeedsCellLabels("intensity")).toBe(true);
    expect(assayNeedsCellLabels("puncta")).toBe(true);
    expect(workspaceExportNeedsLabelMap("annotated-png")).toBe(false);
    expect(workspaceExportNeedsLabelMap("mask-png")).toBe(true);
    expect(workspaceExportNeedsLabelMap("bare-npy")).toBe(true);
  });

  it("creates confluence and its reusable threshold mask in one semantic pass", () => {
    const result = confluenceAndMaskFromIntensity(
      { width: 2, height: 2, channels: 1, data: new Uint8Array([0, 0, 10, 10]) },
      { pxPerUm: 1, threshold: { mode: "fixed", value: 5 } },
    );
    expect([...result.mask.data]).toEqual([0, 0, 1, 1]);
    expect(result.confluence.coveragePct).toBe(50);
    expect(connectedComponents(result.mask.data, 2, 2)[0].pixels).toBeInstanceOf(Uint32Array);
  });
});
