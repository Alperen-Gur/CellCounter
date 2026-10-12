import type { PixelArray, Raster } from "../analysis/types";
import { rasterHeader } from "./rasterHeader";

export interface SourceDimensions { t: number; z: number; c: number; channelNames: string[]; }
export interface PlaneSelection { t?: number; z?: number; projection?: "first" | "max" | "mean" | "sum"; channels?: readonly number[]; }
const MAX_PIXELS = 4_000_000;
const MAX_BYTES = 384 * 1024 * 1024;
function attribute(text: string, name: string): string | undefined { return new RegExp(`\\b${name}\\s*=\\s*["']([^"']+)["']`, "i").exec(text)?.[1]; }
function positive(value: string | undefined, fallback: number): number { const n = Number(value ?? fallback); if (!Number.isSafeInteger(n) || n < 1 || n > 1000000) throw new Error("Invalid OME axis length"); return n; }
export function describeSourceDimensions(description: string, samples: number, planes: number): SourceDimensions {
  if ([...description.matchAll(/<(?:\w+:)?Pixels\b/gi)].length > 1) throw new Error("This OME-TIFF contains multiple series. Export the desired series locally before import.");
  if (!Number.isSafeInteger(samples) || samples < 1 || samples > 16 || !Number.isSafeInteger(planes) || planes < 1) throw new Error("TIFF sample/plane counts exceed browser limits.");
  const pixels = /<(?:\w+:)?Pixels\b([^>]*)>/i.exec(description)?.[1];
  if (!pixels) return { t: 1, z: planes, c: samples, channelNames: Array.from({ length: samples }, (_, i) => `Channel ${i + 1}`) };
  const c = positive(attribute(pixels, "SizeC"), samples);
  if (c > 16) throw new Error("OME-TIFF channel count exceeds the 16-channel browser limit.");
  const t = positive(attribute(pixels, "SizeT"), 1), z = positive(attribute(pixels, "SizeZ"), 1);
  if (!Number.isSafeInteger(t * z * c) || t * z * c > 1000000) throw new Error("OME plane count exceeds the bounded browser axis index.");
  const names = [...description.matchAll(/<(?:\w+:)?Channel\b([^>]*)>/gi)].map((match, index) => attribute(match[1], "Name") ?? `Channel ${index + 1}`);
  return { t, z, c, channelNames: Array.from({ length: c }, (_, i) => names[i] ?? `Channel ${i + 1}`) };
}
function check(width: number, height: number, channels: number, bytes: number) {
  const pixels = width * height;
  if (!Number.isSafeInteger(pixels) || pixels < 1 || pixels > MAX_PIXELS || channels < 1 || channels > 16 || bytes + pixels * channels * 16 > MAX_BYTES) throw new Error("Selected source plane exceeds the 4-million-pixel / 384 MB browser working-set budget. Crop or downsample locally first.");
}
function aborted(signal?: AbortSignal) { if (signal?.aborted) throw new DOMException("Source preparation cancelled", "AbortError"); }
/** Original raw samples at one time point, one Z or explicit Z projection. Never mixes times/channels into Z. */
export async function readNativeRaster(source: Blob, fileName: string, selection: PlaneSelection = {}, signal?: AbortSignal): Promise<Raster> {
  aborted(signal);
  if (!/\.tiff?$|\.ome\.tiff?$/i.test(fileName) && !/tiff/i.test(source.type)) {
    const header = await rasterHeader(source);
    check(header.width, header.height, 3, source.size);
    aborted(signal);
    const bitmap = await createImageBitmap(source);
    try {
      if (!(bitmap.width === header.width && bitmap.height === header.height) && !(header.jpeg && bitmap.width === header.height && bitmap.height === header.width)) throw new Error("Decoded raster dimensions disagree with its bounded header.");
      check(bitmap.width, bitmap.height, 3, source.size);
      if ((selection.t ?? 0) !== 0 || (selection.z ?? 0) !== 0) throw new Error("This raster has one time and Z plane.");
      const context = new OffscreenCanvas(bitmap.width, bitmap.height).getContext("2d", { willReadFrequently: true });
      if (!context) throw new Error("OffscreenCanvas is unavailable for source preparation.");
      context.drawImage(bitmap, 0, 0); const rgba = context.getImageData(0, 0, bitmap.width, bitmap.height).data;
      const channels = selection.channels ?? [0, 1, 2];
      if (!channels.length || channels.some((channel) => !Number.isInteger(channel) || channel < 0 || channel > 2)) throw new Error("Selected RGB source channel is unavailable.");
      const values = new Float32Array(bitmap.width * bitmap.height * channels.length);
      for (let i = 0; i < bitmap.width * bitmap.height; i++) for (let c = 0; c < channels.length; c++) values[i * channels.length + c] = rgba[i * 4 + channels[c]];
      aborted(signal); return { data: values, width: bitmap.width, height: bitmap.height, channels: channels.length };
    } finally { bitmap.close(); }
  }
  if (source.size > 64 * 1024 * 1024) throw new Error("Raw TIFF preparation exceeds the 64 MB browser input budget. Export the selected plane locally first.");
  const { fromArrayBuffer } = await import("geotiff");
  const tiff = await fromArrayBuffer(await source.arrayBuffer()); const first = await tiff.getImage(0); const count = await tiff.getImageCount();
  const width = first.getWidth(), height = first.getHeight(), samples = first.getSamplesPerPixel();
  const description = String(first.getFileDirectory().ImageDescription ?? "");
  if (description.length > 2 * 1024 * 1024) throw new Error("OME metadata exceeds the bounded browser parser budget.");
  const dims = describeSourceDimensions(description, samples, count); const channels = selection.channels ?? Array.from({ length: dims.c }, (_, c) => c);
  check(width, height, Math.max(samples, channels.length), source.size);
  if (channels.some((c) => !Number.isInteger(c) || c < 0 || c >= dims.c)) throw new Error("Selected source channel is unavailable.");
  const t = selection.t ?? 0, z = selection.z ?? 0;
  if (!Number.isInteger(t) || t < 0 || t >= dims.t || !Number.isInteger(z) || z < 0 || z >= dims.z) throw new Error("Selected time/Z plane is unavailable.");
  if (dims.c % samples !== 0) throw new Error("OME channels cannot be mapped to interleaved TIFF samples safely.");
  const groupedC = dims.c / samples;
  const totalPlanes = dims.z * groupedC * dims.t;
  const pixelsAttrs = /<(?:\w+:)?Pixels\b([^>]*)>/i.exec(description)?.[1];
  const order = (pixelsAttrs ? attribute(pixelsAttrs, "DimensionOrder") : "XYZCT") ?? "XYZCT";
  const axes = [...order].filter((axis) => "ZCT".includes(axis));
  if (axes.length !== 3 || new Set(axes).size !== 3) throw new Error("Unsupported OME dimension order.");
  const lengths: Record<string, number> = { Z: dims.z, C: groupedC, T: dims.t };
  if (count < dims.z * groupedC * dims.t) throw new Error("OME source references missing TIFF planes; multi-file OME must be assembled locally first.");
  const indexFor = (tt: number, zz: number, cc: number) => { const values: Record<string, number> = { Z: zz, C: cc, T: tt }; let stride = 1, index = 0; for (const axis of axes) { index += values[axis] * stride; stride *= lengths[axis]; } return index; };
  const explicit = new Map<number, number>(), mappedIfds = new Set<number>();
  for (const match of description.matchAll(/<(?:\w+:)?TiffData\b([^>]*)(?:\/\s*>|>([\s\S]*?)<\/(?:\w+:)?TiffData>)/gi)) {
    if (/<(?:\w+:)?UUID\b/i.test(match[2] ?? "")) throw new Error("Multi-file OME-TIFF references need local assembly before import.");
    const attrs = match[1], ifd = Number(attribute(attrs, "IFD") ?? 0);
    const c0 = Number(attribute(attrs, "FirstC") ?? 0), z0 = Number(attribute(attrs, "FirstZ") ?? 0), t0 = Number(attribute(attrs, "FirstT") ?? 0);
    const n = Number(attribute(attrs, "PlaneCount") ?? (attribute(attrs, "IFD") ? 1 : count));
    if (![ifd, c0, z0, t0, n].every(Number.isSafeInteger) || ifd < 0 || n < 1 || ifd + n > count || c0 < 0 || c0 >= dims.c || z0 < 0 || z0 >= dims.z || t0 < 0 || t0 >= dims.t || c0 % samples !== 0) throw new Error("Invalid OME TIFF plane mapping.");
    const base = indexFor(t0, z0, c0 / samples);
    if (base + n > totalPlanes) throw new Error("OME TIFF plane mapping extends outside its axes.");
    for (let i = 0; i < n; i++) { if (explicit.has(base + i) || mappedIfds.has(ifd + i)) throw new Error("OME TIFF mappings overlap. Export the desired series locally first."); explicit.set(base + i, ifd + i); mappedIfds.add(ifd + i); }
  }
  const projection = selection.projection ?? "first";
  if (!["first", "max", "mean", "sum"].includes(projection)) throw new Error("Unsupported Z projection.");
  if (projection !== "first" && dims.z > 64) throw new Error("Browser projections support at most 64 Z planes.");
  const zValues = projection === "first" ? [z] : Array.from({ length: dims.z }, (_, i) => i);
  const output = new Float32Array(width * height * channels.length);
  const means = projection === "mean" ? new Float64Array(output.length) : undefined;
  for (let zi = 0; zi < zValues.length; zi++) {
    const groups = [...new Set(channels.map((c) => Math.floor(c / samples)))];
    for (const group of groups) {
      aborted(signal); const logical = indexFor(t, zValues[zi], group); const ifd = explicit.size ? explicit.get(logical) : logical;
      if (ifd === undefined || ifd >= count) throw new Error("OME TIFF plane mapping is incomplete.");
      const image = await tiff.getImage(ifd);
      if (image.getWidth() !== width || image.getHeight() !== height || image.getSamplesPerPixel() !== samples) throw new Error("Selected TIFF planes have incompatible dimensions or samples.");
      const directory = image.getFileDirectory();
      const tileWidth = Number(directory.TileWidth ?? width), tileHeight = Number(directory.TileLength ?? Math.min(height, Number(directory.RowsPerStrip ?? height)));
      const bits = Array.isArray(directory.BitsPerSample) || ArrayBuffer.isView(directory.BitsPerSample) ? Array.from(directory.BitsPerSample as ArrayLike<number>) : [Number(directory.BitsPerSample ?? 8)];
      if (![tileWidth, tileHeight].every((n) => Number.isSafeInteger(n) && n > 0 && n <= 65536) || bits.some((n) => ![8, 16, 32, 64].includes(n)) || tileWidth * tileHeight * samples * Math.max(...bits) / 8 > 32 * 1024 * 1024) throw new Error("Decoded TIFF block exceeds the 32 MB block budget. Retile or export this plane locally.");
      const data = await image.readRasters({ interleave: true }) as PixelArray;
      for (let ci = 0; ci < channels.length; ci++) if (Math.floor(channels[ci] / samples) === group) for (let i = 0; i < width * height; i++) {
        const value = Number(data[i * samples + channels[ci] % samples]); if (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value))) throw new Error("Source plane contains non-finite intensities.");
        if (Math.fround(value) !== value) throw new Error("Source sample requires precision beyond the browser Float32 analysis path. Export a float32 plane locally with an explicit intensity transform first.");
        const at = i * channels.length + ci;
        if (means) { means[at] = zi === 0 ? value : means[at] + (value - means[at]) / (zi + 1); continue; }
        const projected = zi === 0 ? value : projection === "max" ? Math.max(output[at], value) : output[at] + value; output[at] = projected; if (Number.isInteger(projected) && output[at] !== projected) throw new Error("Integer projection exceeds exact Float32 sample precision. Choose max/mean or create an explicit local transform."); if (!Number.isFinite(output[at])) throw new Error("Source conversion/projection exceeds the browser Float32 intensity range.");
      }
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
  }
  if (means) for (let i = 0; i < output.length; i++) { output[i] = means[i]; if (!Number.isFinite(output[i])) throw new Error("Mean projection exceeds the Float32 intensity range."); }
  aborted(signal); return { data: output, width, height, channels: channels.length };
}
