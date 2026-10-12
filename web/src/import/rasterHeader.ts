/** Header-only dimensions before browser decoding; never resizes source coordinates. */
export async function rasterHeader(source: Blob): Promise<{ width: number; height: number; jpeg: boolean }> {
  if (source.size > 64 * 1024 * 1024) throw new Error("Browser raster input exceeds 64 MiB. Convert or crop the source locally first.");
  const bytes = new Uint8Array(await source.slice(0, 65536).arrayBuffer()), view = new DataView(bytes.buffer);
  const at = (offset: number, text: string) => [...text].every((c, i) => bytes[offset + i] === c.charCodeAt(0));
  const little24 = (offset: number) => bytes[offset] | bytes[offset + 1] << 8 | bytes[offset + 2] << 16;
  let width = 0, height = 0, jpeg = false;
  if (bytes.length >= 24 && bytes[0] === 137 && at(1, "PNG\r\n\x1a\n") && at(12, "IHDR")) { width = view.getUint32(16); height = view.getUint32(20); }
  else if (bytes.length >= 10 && (at(0, "GIF87a") || at(0, "GIF89a"))) { width = view.getUint16(6, true); height = view.getUint16(8, true); }
  else if (bytes.length >= 26 && at(0, "BM") && view.getUint32(14, true) >= 40) { width = view.getInt32(18, true); height = Math.abs(view.getInt32(22, true)); }
  else if (bytes.length >= 30 && at(0, "RIFF") && at(8, "WEBP")) {
    if (at(12, "VP8X")) { width = little24(24) + 1; height = little24(27) + 1; }
    else if (at(12, "VP8 ") && bytes[23] === 0x9d && bytes[24] === 1 && bytes[25] === 0x2a) { width = view.getUint16(26, true) & 0x3fff; height = view.getUint16(28, true) & 0x3fff; }
    else if (at(12, "VP8L") && bytes[20] === 0x2f) { const bits = view.getUint32(21, true); width = (bits & 0x3fff) + 1; height = (bits >>> 14 & 0x3fff) + 1; }
  } else if (bytes[0] === 0xff && bytes[1] === 0xd8) {
    jpeg = true;
    let cursor = 2;
    while (cursor + 4 <= bytes.length) {
      if (bytes[cursor++] !== 0xff) break;
      while (cursor < bytes.length && bytes[cursor] === 0xff) cursor++;
      const marker = bytes[cursor++];
      if (marker === 0xd9 || marker === 0xda) break;
      if (marker === 0x01 || marker >= 0xd0 && marker <= 0xd7) continue;
      if (cursor + 2 > bytes.length) break;
      const length = view.getUint16(cursor); if (length < 2 || cursor + length > bytes.length) break;
      if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker) && length >= 7) { height = view.getUint16(cursor + 3); width = view.getUint16(cursor + 5); break; }
      cursor += length;
    }
  }
  if (!width || !height) throw new Error("Raster dimensions cannot be verified within the bounded header. Convert this source locally to PNG before opening it.");
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width < 1 || height < 1) throw new Error("The raster header dimensions must be positive integers.");
  return { width, height, jpeg };
}
export async function assertRasterHeader(source: Blob, expectedWidth: number, expectedHeight: number): Promise<void> {
  const { width, height, jpeg } = await rasterHeader(source);
  // JPEG EXIF orientations 5–8 exchange axes during browser decoding. Either
  // ordering reserves the same pixel area; the caller checks decoded dimensions
  // before drawing, so an unrotated mismatch cannot reach source geometry.
  if ((width !== expectedWidth || height !== expectedHeight) && !(jpeg && width === expectedHeight && height === expectedWidth)) throw new Error("Encoded raster dimensions differ from the source-coordinate analysis.");
}
