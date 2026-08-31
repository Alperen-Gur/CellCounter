import type { BatchAnalysis, BrowserImageSource, CalibrationSource, ImageAnalysis } from "../domain/types";
import type { ModelArtifactCache } from "../models/WebGpuInference";
import type { GroundTruthMark, WorkspaceCell, WorkspaceRoi } from "../app/types";

const DATABASE_NAME = "cellcounter-web";
const DATABASE_VERSION = 2;

export interface WorkspaceImageMetadata {
  readonly id: string;
  readonly fileName: string;
  readonly mediaType: string;
  readonly widthPx: number;
  readonly heightPx: number;
  readonly importedAt: string;
  readonly condition: string;
  readonly pxPerUm: number;
  readonly analysisId: string | null;
  readonly sourceSha256?: string;
  readonly sourceByteLength?: number;
  readonly sourceMediaType?: string;
  readonly calibrationSource?: CalibrationSource;
  readonly calibrationConfidence?: "high" | "medium" | "low";
  readonly planeCount?: number;
  readonly samplesPerPixel?: number;
  readonly bitsPerSample?: number;
  readonly thumbnail?: Blob;
  readonly groundTruth?: readonly GroundTruthMark[];
  readonly rois?: readonly WorkspaceRoi[];
  readonly note?: string;
  readonly reviewConfidence?: "high" | "medium" | "low";
  readonly modelId?: string;
  /** Geometry-free summaries keep library/review useful without hydrating contours. */
  readonly cellSummaries?: readonly WorkspaceCell[];
}

interface StoredSource {
  readonly id: string;
  readonly fileName: string;
  readonly mediaType: string;
  readonly byteLength: number;
  readonly lastModified: number | null;
  readonly storage: "indexeddb" | "opfs";
  readonly blob?: Blob;
}

interface FileHandleLike {
  getFile(): Promise<File>;
  createWritable(): Promise<{ write(data: Blob): Promise<void>; close(): Promise<void>; abort?(): Promise<void> }>;
}

interface DirectoryHandleLike {
  getDirectoryHandle(name: string, options?: { create?: boolean }): Promise<DirectoryHandleLike>;
  getFileHandle(name: string, options?: { create?: boolean }): Promise<FileHandleLike>;
  removeEntry(name: string, options?: { recursive?: boolean }): Promise<void>;
}

interface StorageManagerWithOpfs {
  getDirectory?: () => Promise<DirectoryHandleLike>;
}

function requestResult<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("IndexedDB request failed"));
  });
}

function transactionComplete(transaction: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onabort = () => reject(transaction.error ?? new Error("IndexedDB transaction aborted"));
    transaction.onerror = () => reject(transaction.error ?? new Error("IndexedDB transaction failed"));
  });
}

async function openDatabase(factory: IDBFactory): Promise<IDBDatabase> {
  const request = factory.open(DATABASE_NAME, DATABASE_VERSION);
  request.onupgradeneeded = () => {
    const database = request.result;
    if (!database.objectStoreNames.contains("sources")) database.createObjectStore("sources", { keyPath: "id" });
    if (!database.objectStoreNames.contains("analyses")) database.createObjectStore("analyses", { keyPath: "id" });
    if (!database.objectStoreNames.contains("batches")) database.createObjectStore("batches", { keyPath: "id" });
    if (!database.objectStoreNames.contains("modelArtifacts")) database.createObjectStore("modelArtifacts");
    if (!database.objectStoreNames.contains("workspaceImages")) database.createObjectStore("workspaceImages", { keyPath: "id" });
  };
  return requestResult(request);
}

function opfsFileName(id: string): string {
  const bytes = new TextEncoder().encode(id);
  let value = "";
  for (const byte of bytes) value += byte.toString(16).padStart(2, "0");
  return `${value}.blob`;
}

class OpfsSourceStore {
  constructor(private readonly directory: DirectoryHandleLike) {}

  async put(id: string, blob: Blob): Promise<void> {
    const name = opfsFileName(id);
    const target = await this.directory.getFileHandle(name, { create: true });
    const writer = await target.createWritable();
    try {
      await writer.write(blob);
      await writer.close();
      const stored = await target.getFile();
      if (stored.size !== blob.size) {
        await this.directory.removeEntry(name).catch(() => undefined);
        throw new Error(`OPFS write was truncated for ${id}`);
      }
    } catch (error) {
      await writer.abort?.().catch(() => undefined);
      throw error;
    }
  }

  async get(id: string): Promise<Blob | null> {
    try {
      return await (await this.directory.getFileHandle(opfsFileName(id))).getFile();
    } catch (error) {
      if (error instanceof DOMException && error.name === "NotFoundError") return null;
      throw error;
    }
  }

  async delete(id: string): Promise<void> {
    await this.directory.removeEntry(opfsFileName(id)).catch((error: unknown) => {
      if (!(error instanceof DOMException) || error.name !== "NotFoundError") throw error;
    });
  }
}

export interface BrowserRepositoryOptions {
  readonly indexedDB?: IDBFactory;
  readonly storageManager?: StorageManagerWithOpfs | null;
}

/** Browser-only repository. No native paths, network storage, telemetry, or uploads. */
export class BrowserRepository {
  private constructor(
    private readonly database: IDBDatabase,
    private readonly opfs: OpfsSourceStore | null,
  ) {}

  static async open(options: BrowserRepositoryOptions = {}): Promise<BrowserRepository> {
    const factory = options.indexedDB ?? globalThis.indexedDB;
    if (!factory) throw new Error("IndexedDB is unavailable; local projects cannot be persisted");
    const database = await openDatabase(factory);
    const storage = options.storageManager === undefined
      ? (globalThis.navigator?.storage as StorageManagerWithOpfs | undefined)
      : options.storageManager ?? undefined;
    let opfs: OpfsSourceStore | null = null;
    if (storage?.getDirectory) {
      try {
        const root = await storage.getDirectory();
        const directory = await root.getDirectoryHandle("cellcounter-images", { create: true });
        opfs = new OpfsSourceStore(directory);
      } catch {
        // OPFS is an optimization. IndexedDB remains the explicit local fallback.
        opfs = null;
      }
    }
    return new BrowserRepository(database, opfs);
  }

  get usesOpfs(): boolean {
    return this.opfs !== null;
  }

  readonly modelArtifactCache: ModelArtifactCache = {
    get: async (key) => this.getModelArtifact(key),
    put: async (key, value) => this.putModelArtifact(key, value),
    delete: async (key) => this.deleteModelArtifact(key),
  };

  close(): void {
    this.database.close();
  }

  async putSource(source: BrowserImageSource): Promise<void> {
    let record: StoredSource;
    if (this.opfs) {
      await this.opfs.put(source.id, source.blob);
      record = { ...source, storage: "opfs", blob: undefined };
    } else {
      record = { ...source, storage: "indexeddb", blob: source.blob };
    }
    const transaction = this.database.transaction("sources", "readwrite");
    const completed = transactionComplete(transaction);
    transaction.objectStore("sources").put(record);
    try {
      await completed;
    } catch (error) {
      if (record.storage === "opfs") await this.opfs?.delete(source.id);
      throw error;
    }
  }

  async getSource(id: string): Promise<BrowserImageSource | null> {
    const transaction = this.database.transaction("sources", "readonly");
    const completed = transactionComplete(transaction);
    const record = (await requestResult(transaction.objectStore("sources").get(id))) as StoredSource | undefined;
    await completed;
    if (!record) return null;
    const blob = record.storage === "opfs" ? await this.opfs?.get(id) : record.blob;
    if (!blob) throw new Error(`Image bytes are missing from local storage: ${id}`);
    return {
      id: record.id,
      fileName: record.fileName,
      mediaType: record.mediaType,
      byteLength: record.byteLength,
      lastModified: record.lastModified,
      blob,
    };
  }

  async deleteSource(id: string): Promise<void> {
    const transaction = this.database.transaction("sources", "readwrite");
    const completed = transactionComplete(transaction);
    transaction.objectStore("sources").delete(id);
    await completed;
    await this.opfs?.delete(id);
  }

  async putAnalysis(analysis: ImageAnalysis): Promise<void> {
    await this.putRecord("analyses", analysis);
  }

  async getAnalysis(id: string): Promise<ImageAnalysis | null> {
    return this.getRecord<ImageAnalysis>("analyses", id);
  }

  async listAnalyses(): Promise<ImageAnalysis[]> {
    return this.listRecords<ImageAnalysis>("analyses");
  }

  async deleteAnalysis(id: string): Promise<void> {
    await this.deleteRecord("analyses", id);
  }

  async putBatch(batch: BatchAnalysis): Promise<void> {
    await this.putRecord("batches", batch);
  }

  async getBatch(id: string): Promise<BatchAnalysis | null> {
    return this.getRecord<BatchAnalysis>("batches", id);
  }

  async listBatches(): Promise<BatchAnalysis[]> {
    return this.listRecords<BatchAnalysis>("batches");
  }

  async deleteBatch(id: string): Promise<void> {
    await this.deleteRecord("batches", id);
  }

  async putWorkspaceImage(metadata: WorkspaceImageMetadata): Promise<void> {
    await this.putRecord("workspaceImages", metadata);
  }

  async getWorkspaceImage(id: string): Promise<WorkspaceImageMetadata | null> {
    return this.getRecord<WorkspaceImageMetadata>("workspaceImages", id);
  }

  async listWorkspaceImages(): Promise<WorkspaceImageMetadata[]> {
    return this.listRecords<WorkspaceImageMetadata>("workspaceImages");
  }

  async deleteWorkspaceImage(id: string): Promise<void> {
    await this.deleteRecord("workspaceImages", id);
  }

  private async putRecord(store: "analyses" | "batches" | "workspaceImages", value: { readonly id: string }): Promise<void> {
    const transaction = this.database.transaction(store, "readwrite");
    const completed = transactionComplete(transaction);
    transaction.objectStore(store).put(value);
    await completed;
  }

  private async getRecord<T>(store: "analyses" | "batches" | "workspaceImages", id: string): Promise<T | null> {
    const transaction = this.database.transaction(store, "readonly");
    const completed = transactionComplete(transaction);
    const result = (await requestResult(transaction.objectStore(store).get(id))) as T | undefined;
    await completed;
    return result ?? null;
  }

  private async listRecords<T extends { readonly id: string }>(store: "analyses" | "batches" | "workspaceImages"): Promise<T[]> {
    const transaction = this.database.transaction(store, "readonly");
    const completed = transactionComplete(transaction);
    const result = (await requestResult(transaction.objectStore(store).getAll())) as T[];
    await completed;
    return result.sort((left, right) => (left.id < right.id ? -1 : left.id > right.id ? 1 : 0));
  }

  private async deleteRecord(store: "analyses" | "batches" | "workspaceImages", id: string): Promise<void> {
    const transaction = this.database.transaction(store, "readwrite");
    const completed = transactionComplete(transaction);
    transaction.objectStore(store).delete(id);
    await completed;
  }

  private async getModelArtifact(key: string): Promise<ArrayBuffer | null> {
    const transaction = this.database.transaction("modelArtifacts", "readonly");
    const completed = transactionComplete(transaction);
    const result = (await requestResult(transaction.objectStore("modelArtifacts").get(key))) as ArrayBuffer | undefined;
    await completed;
    return result ?? null;
  }

  private async putModelArtifact(key: string, value: ArrayBuffer): Promise<void> {
    const transaction = this.database.transaction("modelArtifacts", "readwrite");
    const completed = transactionComplete(transaction);
    transaction.objectStore("modelArtifacts").put(value, key);
    await completed;
  }

  private async deleteModelArtifact(key: string): Promise<void> {
    const transaction = this.database.transaction("modelArtifacts", "readwrite");
    const completed = transactionComplete(transaction);
    transaction.objectStore("modelArtifacts").delete(key);
    await completed;
  }
}
