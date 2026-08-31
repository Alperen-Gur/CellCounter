export type PixelArray =
  | Uint8Array
  | Uint8ClampedArray
  | Uint16Array
  | Uint32Array
  | Int16Array
  | Float32Array
  | Float64Array;

export interface Raster {
  readonly data: PixelArray;
  readonly width: number;
  readonly height: number;
  /** Interleaved channel count. */
  readonly channels: number;
}
export interface LabelMap {
  readonly data: Uint32Array;
  readonly width: number;
  readonly height: number;
}

export interface Point {
  readonly x: number;
  readonly y: number;
}

export interface IdentifiedPoint extends Point {
  readonly id: string;
}

export function assertRaster(raster: Raster): void {
  if (!Number.isInteger(raster.width) || raster.width <= 0 ||
      !Number.isInteger(raster.height) || raster.height <= 0 ||
      !Number.isInteger(raster.channels) || raster.channels <= 0) {
    throw new RangeError("Raster dimensions and channel count must be positive integers.");
  }
  if (raster.data.length !== raster.width * raster.height * raster.channels) {
    throw new RangeError("Raster data length does not match width × height × channels.");
  }
}

export function assertLabelMap(labels: LabelMap): void {
  if (!Number.isInteger(labels.width) || labels.width <= 0 ||
      !Number.isInteger(labels.height) || labels.height <= 0 ||
      labels.data.length !== labels.width * labels.height) {
    throw new RangeError("Label-map data length does not match its positive dimensions.");
  }
}

export function assertAligned(labels: LabelMap, raster: Raster): void {
  assertLabelMap(labels);
  assertRaster(raster);
  if (labels.width !== raster.width || labels.height !== raster.height) {
    throw new RangeError("Raster and label-map dimensions must match.");
  }
}

export function assertCalibration(pxPerUm: number): void {
  if (!Number.isFinite(pxPerUm) || pxPerUm <= 0) {
    throw new RangeError("pxPerUm must be a finite number greater than zero.");
  }
}
