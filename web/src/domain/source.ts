import type { BrowserImageSource } from "./types";

/** Creates the only source type accepted by the browser pipeline: a local Blob. */
export function createBrowserImageSource(
  blob: Blob,
  options: { id?: string; fileName?: string; lastModified?: number | null } = {},
): BrowserImageSource {
  if (!(blob instanceof Blob)) throw new TypeError("Image source must be a Blob or File");

  const file = typeof File !== "undefined" && blob instanceof File ? blob : null;
  const id = options.id ?? crypto.randomUUID();
  const fileName = options.fileName ?? file?.name ?? `${id}.image`;
  if (!fileName.trim()) throw new TypeError("Image source fileName cannot be empty");

  return Object.freeze({
    id,
    fileName,
    mediaType: blob.type || "application/octet-stream",
    byteLength: blob.size,
    lastModified: options.lastModified ?? file?.lastModified ?? null,
    blob,
  });
}

export function sourceMetadata(source: BrowserImageSource): Omit<BrowserImageSource, "blob"> {
  const { blob: _blob, ...metadata } = source;
  return metadata;
}
