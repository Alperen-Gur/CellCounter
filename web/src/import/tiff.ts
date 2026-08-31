import { sha256Hex } from "../models/hash";

export interface TiffCalibration {
  readonly pxPerUm: number;
  readonly source: "OME-XML" | "ImageJ" | "TIFF baseline";
  readonly confidence: "high" | "medium";
}

export interface DecodedTiff {
  readonly displayFile: File;
  readonly width: number;
  readonly height: number;
  readonly imageCount: number;
  readonly calibration?: TiffCalibration;
  readonly description?: string;
  readonly sourceSha256: string;
  readonly samplesPerPixel: number;
  readonly bitsPerSample: number;
}

function finitePositive(value: unknown): number | undefined {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : undefined;
}

function unitToUm(unit: string | undefined): number | undefined {
  const normalized = (unit ?? "µm").trim().toLocaleLowerCase().replace("μ", "µ");
  if (["µm", "um", "micron", "microns", "micrometer", "micrometre"].includes(normalized)) return 1;
  if (["nm", "nanometer", "nanometre"].includes(normalized)) return 0.001;
  if (["mm", "millimeter", "millimetre"].includes(normalized)) return 1_000;
  if (["cm", "centimeter", "centimetre"].includes(normalized)) return 10_000;
  if (["m", "meter", "metre"].includes(normalized)) return 1_000_000;
  return undefined;
}

function xmlAttribute(xml: string, name: string): string | undefined {
  return new RegExp(`${name}\\s*=\\s*["']([^"']+)["']`, "i").exec(xml)?.[1];
}

/** Parse isotropic OME physical pixel size. The returned unit is pixels/µm. */
export function parseOmeCalibration(description: string): TiffCalibration | undefined {
  if (!/<(?:\w+:)?(?:OME|Pixels)\b/i.test(description)) return undefined;
  const x = finitePositive(xmlAttribute(description, "PhysicalSizeX"));
  if (!x) return undefined;
  const y = finitePositive(xmlAttribute(description, "PhysicalSizeY"));
  const xScale = unitToUm(xmlAttribute(description, "PhysicalSizeXUnit"));
  const yScale = unitToUm(xmlAttribute(description, "PhysicalSizeYUnit") ?? xmlAttribute(description, "PhysicalSizeXUnit"));
  if (!xScale || (y && !yScale)) return undefined;
  const xUm = x * xScale;
  const yUm = y ? y * (yScale ?? xScale) : xUm;
  if (Math.abs(xUm - yUm) / Math.max(xUm, yUm) > 0.05) return undefined;
  const pxPerUm = 1 / ((xUm + yUm) / 2);
  return pxPerUm >= 0.0001 && pxPerUm <= 10_000 ? { pxPerUm, source: "OME-XML", confidence: "high" } : undefined;
}

/** Parse ImageJ description fields such as unit=um and pixel_width=0.65. */
export function parseImageJCalibration(description: string): TiffCalibration | undefined {
  if (!/^ImageJ=/im.test(description)) return undefined;
  const values = new Map(description.split(/\r?\n/).map((line) => line.split("=", 2).map((part) => part.trim())).filter((parts) => parts.length === 2) as Array<[string, string]>);
  const width = finitePositive(values.get("pixel_width") ?? values.get("pixelWidth"));
  const height = finitePositive(values.get("pixel_height") ?? values.get("pixelHeight")) ?? width;
  const scale = unitToUm(values.get("unit"));
  if (!width || !height || !scale || Math.abs(width - height) / Math.max(width, height) > 0.05) return undefined;
  const pxPerUm = 1 / (((width + height) / 2) * scale);
  return pxPerUm >= 0.0001 && pxPerUm <= 10_000 ? { pxPerUm, source: "ImageJ", confidence: "medium" } : undefined;
}

function rational(value: unknown): number | undefined {
  if (Array.isArray(value) || ArrayBuffer.isView(value)) {
    const values = Array.from(value as ArrayLike<number>);
    if (values.length >= 2 && values[1] !== 0) return finitePositive(values[0] / values[1]);
    return finitePositive(values[0]);
  }
  return finitePositive(value);
}

export function parseBaselineCalibration(directory: Record<string, unknown>): TiffCalibration | undefined {
  const x = rational(directory.XResolution);
  const y = rational(directory.YResolution) ?? x;
  const unit = Number(directory.ResolutionUnit);
  const umPerUnit = unit === 2 ? 25_400 : unit === 3 ? 10_000 : undefined;
  if (!x || !y || !umPerUnit || Math.abs(x - y) / Math.max(x, y) > 0.05) return undefined;
  const pxPerUm = ((x + y) / 2) / umPerUnit;
  return pxPerUm >= 0.0001 && pxPerUm <= 10_000 ? { pxPerUm, source: "TIFF baseline", confidence: "medium" } : undefined;
}

interface WorkerResult {
  readonly id: string;
  readonly ok: boolean;
  readonly error?: string;
  readonly blob?: Blob;
  readonly width?: number;
  readonly height?: number;
  readonly imageCount?: number;
  readonly description?: string;
  readonly baseline?: Record<string, unknown>;
  readonly samplesPerPixel?: number;
  readonly bitsPerSample?: number;
}

function decodeInWorker(source: ArrayBuffer): Promise<Omit<WorkerResult, "id" | "ok">> {
  if (typeof Worker === "undefined") return Promise.reject(new Error("Web Workers are required for memory-safe TIFF decoding"));
  const worker = new Worker(new URL("./tiff.worker.ts", import.meta.url), { type: "module", name: "cellcounter-tiff" });
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    worker.onmessage = (event: MessageEvent<WorkerResult>) => {
      if (event.data.id !== id) return;
      worker.terminate();
      if (!event.data.ok) reject(new Error(event.data.error ?? "TIFF worker failed"));
      else resolve(event.data);
    };
    worker.onerror = (event) => { worker.terminate(); reject(new Error(event.message || "TIFF worker failed")); };
    worker.postMessage({ id, source }, [source]);
  });
}

let decodeQueue: Promise<void> = Promise.resolve();

function serializeDecode<T>(task: () => Promise<T>): Promise<T> {
  const result = decodeQueue.then(task, task);
  decodeQueue = result.then(() => undefined, () => undefined);
  return result;
}

/** Decode the first TIFF/OME-TIFF plane locally. Multi-plane count remains visible in provenance. */
export function decodeTiff(file: File, knownSha256?: string): Promise<DecodedTiff> {
  return serializeDecode(async () => {
    const source = await file.arrayBuffer();
    const sourceSha256 = knownSha256 ?? await sha256Hex(source);
    const result = await decodeInWorker(source);
    if (!result.blob || !result.width || !result.height || !result.imageCount) throw new Error("TIFF worker returned an incomplete result");
    const description = result.description ?? "";
    const calibration = parseOmeCalibration(description) ?? parseImageJCalibration(description) ?? parseBaselineCalibration(result.baseline ?? {});
    return { displayFile: new File([result.blob], file.name, { type: "image/png", lastModified: file.lastModified }), width: result.width, height: result.height, imageCount: result.imageCount, calibration, description: description || undefined, sourceSha256, samplesPerPixel: result.samplesPerPixel ?? 1, bitsPerSample: result.bitsPerSample ?? 8 };
  });
}
