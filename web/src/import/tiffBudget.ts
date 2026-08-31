export const TIFF_IMPORT_BUDGET_BYTES = 384 * 1024 * 1024;
/** Source + decoder RGB + RGBA/ImageData + canvas backing + PNG encoder working buffers. */
export const TIFF_IMPORT_BYTES_PER_PIXEL = 20;

export function estimatedTiffImportBytes(sourceBytes: number, width: number, height: number): number {
  return sourceBytes + width * height * TIFF_IMPORT_BYTES_PER_PIXEL;
}

export function assertImageImportBudget(sourceBytes: number, width: number, height: number, label = "Image"): void {
  const estimated = estimatedTiffImportBytes(sourceBytes, width, height);
  if (!Number.isSafeInteger(width * height) || width <= 0 || height <= 0 || estimated > TIFF_IMPORT_BUDGET_BYTES) {
    throw new Error(`${label} dimensions ${width}×${height} are estimated to need ${Math.ceil(estimated / 1024 / 1024)} MB, above the 384 MB browser import budget`);
  }
}

export function assertTiffImportBudget(sourceBytes: number, width: number, height: number): void {
  assertImageImportBudget(sourceBytes, width, height, "TIFF");
}
