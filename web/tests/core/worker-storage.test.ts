import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createBrowserImageSource } from "../../src/domain/source";
import { BrowserRepository } from "../../src/storage/BrowserRepository";
import { InferenceWorkerClient, type WorkerPort } from "../../src/workers/InferenceWorkerClient";
import { createInferenceWorkerController } from "../../src/workers/controller";
import type { InferenceWorkerRequest, InferenceWorkerResponse } from "../../src/workers/protocol";
import { calibration, parameters, sampleAnalysis } from "./fixtures/sample";
import { TestOnlyInferenceEngine } from "./fixtures/TestOnlyInferenceEngine";

function deleteDatabase(): Promise<void> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.deleteDatabase("cellcounter-web");
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
    request.onblocked = () => reject(new Error("Database deletion blocked"));
  });
}

function readBlob(blob: Blob): Promise<ArrayBuffer> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result as ArrayBuffer);
    reader.onerror = () => reject(reader.error);
    reader.readAsArrayBuffer(blob);
  });
}

class LoopbackWorker implements WorkerPort {
  private listeners = new Set<(event: MessageEvent<InferenceWorkerResponse>) => void>();
  private readonly controller;

  constructor(waitForAbort = false) {
    this.controller = createInferenceWorkerController(
      new TestOnlyInferenceEngine(waitForAbort),
      (message) => queueMicrotask(() => {
        const event = new MessageEvent<InferenceWorkerResponse>("message", { data: message });
        for (const listener of this.listeners) listener(event);
      }),
    );
  }

  postMessage(message: InferenceWorkerRequest): void {
    this.controller.handle(message);
  }

  addEventListener(_type: "message", listener: (event: MessageEvent<InferenceWorkerResponse>) => void): void {
    this.listeners.add(listener);
  }

  removeEventListener(_type: "message", listener: (event: MessageEvent<InferenceWorkerResponse>) => void): void {
    this.listeners.delete(listener);
  }

  terminate(): void {
    this.controller.cancelAll();
  }
}

class MemoryOpfsDirectory {
  private readonly files = new Map<string, Blob>();

  async getDirectoryHandle(): Promise<MemoryOpfsDirectory> {
    return this;
  }

  async getFileHandle(name: string, options?: { create?: boolean }) {
    if (!this.files.has(name) && !options?.create) throw new DOMException("Missing", "NotFoundError");
    if (!this.files.has(name)) this.files.set(name, new Blob());
    return {
      getFile: async () => new File([this.files.get(name)!], name, { type: this.files.get(name)!.type }),
      createWritable: async () => ({
        write: async (blob: Blob) => { this.files.set(name, blob); },
        close: async () => undefined,
        abort: async () => undefined,
      }),
    };
  }

  async removeEntry(name: string): Promise<void> {
    if (!this.files.delete(name)) throw new DOMException("Missing", "NotFoundError");
  }
}

describe("browser-local persistence", () => {
  beforeEach(deleteDatabase);
  afterEach(deleteDatabase);

  it("round-trips local image Blobs, analyses, batches and model cache through IndexedDB", async () => {
    const repository = await BrowserRepository.open({ storageManager: null });
    try {
      const source = createBrowserImageSource(new Blob([new Uint8Array([1, 2, 3])], { type: "image/png" }), {
        id: "image-1", fileName: "field.png", lastModified: 123,
      });
      await repository.putSource(source);
      const restored = await repository.getSource(source.id);
      expect(restored?.fileName).toBe("field.png");
      expect(restored?.byteLength).toBe(3);

      const analysis = sampleAnalysis();
      await repository.putAnalysis(analysis);
      expect((await repository.getAnalysis(analysis.id))?.cells).toHaveLength(1);
      expect((await repository.listAnalyses()).map((item) => item.id)).toEqual([analysis.id]);
      await repository.putBatch({ id: "batch", name: "Batch", condition: "control", analyses: [analysis] });
      expect(await repository.getBatch("batch")).not.toBeNull();

      const artifact = new Uint8Array([9, 8, 7]).buffer;
      await repository.modelArtifactCache.put("model", artifact);
      expect([...new Uint8Array((await repository.modelArtifactCache.get("model"))!)]).toEqual([9, 8, 7]);
      await repository.modelArtifactCache.delete("model");
      expect(await repository.modelArtifactCache.get("model")).toBeNull();

      await repository.deleteSource(source.id);
      expect(await repository.getSource(source.id)).toBeNull();
    } finally {
      repository.close();
    }
  });

  it("uses OPFS for image bytes when available while retaining IndexedDB metadata", async () => {
    const directory = new MemoryOpfsDirectory();
    const repository = await BrowserRepository.open({ storageManager: { getDirectory: async () => directory } });
    try {
      const source = createBrowserImageSource(new Blob([new Uint8Array([4, 5, 6])], { type: "image/png" }), {
        id: "opfs-image", fileName: "opfs.png",
      });
      await repository.putSource(source);
      expect(repository.usesOpfs).toBe(true);
      const restored = await repository.getSource(source.id);
      expect([...new Uint8Array(await readBlob(restored!.blob))]).toEqual([4, 5, 6]);
      await repository.deleteSource(source.id);
      expect(await repository.getSource(source.id)).toBeNull();
    } finally {
      repository.close();
    }
  });
});

describe("Worker protocol and AbortSignal cancellation", () => {
  it("streams progress and resolves analysis from an explicitly injected test engine", async () => {
    const client = new InferenceWorkerClient(new LoopbackWorker());
    const progress: number[] = [];
    try {
      const result = await client.analyze({
        source: createBrowserImageSource(new Blob(), { id: "source", fileName: "field.png" }),
        calibration,
        parameters,
        onProgress: (event) => progress.push(event.completed),
      });
      expect(result.imageWidth).toBe(16);
      expect(progress).toEqual([0, 1]);
    } finally {
      client.dispose();
    }
  });

  it("translates AbortSignal into a Worker cancel message and rejects with cancelled", async () => {
    const client = new InferenceWorkerClient(new LoopbackWorker(true));
    const controller = new AbortController();
    const pending = client.analyze({
      source: createBrowserImageSource(new Blob(), { id: "source", fileName: "field.png" }),
      calibration,
      parameters,
      signal: controller.signal,
    });
    controller.abort();
    await expect(pending).rejects.toMatchObject({ code: "cancelled" });
    client.dispose();
  });
});
