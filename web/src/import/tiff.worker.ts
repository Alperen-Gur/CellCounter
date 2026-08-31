/// <reference lib="webworker" />
import type { TypedArray } from "geotiff";
import { assertTiffImportBudget } from "./tiffBudget";

const MAX_RASTER_PIXELS = 40_000_000;

interface DecodeRequest { readonly id: string; readonly source: ArrayBuffer; }

function toRgba(rgb: TypedArray, width: number, height: number): Uint8ClampedArray {
  const pixels = width * height;
  const channels = rgb.length / pixels;
  if (channels < 3 || !Number.isInteger(channels)) throw new Error("TIFF decoder returned an unsupported channel layout");
  const result = new Uint8ClampedArray(pixels * 4);
  for (let index = 0; index < pixels; index += 1) {
    const source = index * channels;
    const target = index * 4;
    result[target] = Number(rgb[source]);
    result[target + 1] = Number(rgb[source + 1]);
    result[target + 2] = Number(rgb[source + 2]);
    result[target + 3] = channels > 3 ? Number(rgb[source + 3]) : 255;
  }
  return result;
}

self.onmessage = async (event: MessageEvent<DecodeRequest>) => {
  const { id, source } = event.data;
  try {
    const { fromArrayBuffer } = await import("geotiff");
    const tiff = await fromArrayBuffer(source);
    const imageCount = await tiff.getImageCount();
    if (!imageCount) throw new Error("TIFF contains no image planes");
    const image = await tiff.getImage(0);
    const width = image.getWidth();
    const height = image.getHeight();
    if (width * height > MAX_RASTER_PIXELS) throw new Error(`TIFF dimensions ${width}×${height} exceed the 40 megapixel browser import ceiling`);
    assertTiffImportBudget(source.byteLength, width, height);
    const directory = image.getFileDirectory() as Record<string, unknown>;
    const rawDescription = directory.ImageDescription;
    const description = Array.isArray(rawDescription) ? String(rawDescription[0] ?? "") : String(rawDescription ?? "");
    const rgb = await image.readRGB({ interleave: true });
    if (typeof OffscreenCanvas === "undefined") throw new Error("OffscreenCanvas is required for non-blocking TIFF normalization in this browser");
    const canvas = new OffscreenCanvas(width, height);
    const context = canvas.getContext("2d");
    if (!context) throw new Error("2D OffscreenCanvas is unavailable for TIFF normalization");
    context.putImageData(new ImageData(toRgba(rgb as TypedArray, width, height), width, height), 0, 0);
    const blob = await canvas.convertToBlob({ type: "image/png" });
    self.postMessage({ id, ok: true, blob, width, height, imageCount, description, baseline: { XResolution: directory.XResolution, YResolution: directory.YResolution, ResolutionUnit: directory.ResolutionUnit }, samplesPerPixel: image.getSamplesPerPixel(), bitsPerSample: image.getBitsPerSample(0) });
  } catch (error) {
    self.postMessage({ id, ok: false, error: error instanceof Error ? error.message : String(error) });
  }
};

export {};
