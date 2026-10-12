import type { LocalByteStore, OperationOptions, ResourceLimits, WorkspaceAxis, WorkspacePlate, ZarrArray, ZarrDataset, ZarrPlaneSelection, ImagePlane } from './types';
import { checkAbort, fail, finite, integer, product, resourceLimits, safeRelativePath, yieldTask } from './guards';

type JSONRecord = Record<string, unknown>;
function object(value: unknown, name: string): JSONRecord { if (!value || typeof value !== 'object' || Array.isArray(value)) fail('malformed-zarr', `${name} must be an object.`); return value as JSONRecord; }
function list(value: unknown, name: string, max = 256): unknown[] { if (!Array.isArray(value) || value.length > max) fail('malformed-zarr', `${name} must be a bounded array.`); return value as unknown[]; }
function text(value: unknown, name: string): string { if (typeof value !== 'string' || !value || value.length > 4096) fail('malformed-zarr', `${name} must be a nonempty string.`); return value as string; }
interface DType { bytes: number; kind: string; min: number; max: number; read: (view: DataView, offset: number) => number }
function dtype(raw: string): DType {
  const match = /^([<>|])([uif])([1248])$/.exec(raw);
  if (!match) fail('unsupported-dtype', `Unsupported Zarr dtype ${raw}. Use 8/16/32-bit integer or 32/64-bit float arrays.`);
  const [, endian, kind, width] = match!; const bytes = Number(width); const le = endian !== '>';
  if ((endian === '|' && bytes !== 1) || (kind === 'f' && bytes < 4) || (kind !== 'f' && bytes === 8)) fail('unsupported-dtype', `Unsupported Zarr dtype ${raw}; 64-bit integers cannot be represented faithfully by this viewer.`);
  const read = kind === 'f' ? (v: DataView, p: number) => bytes === 4 ? v.getFloat32(p, le) : v.getFloat64(p, le)
    : kind === 'u' ? (v: DataView, p: number) => bytes === 1 ? v.getUint8(p) : bytes === 2 ? v.getUint16(p, le) : v.getUint32(p, le)
    : (v: DataView, p: number) => bytes === 1 ? v.getInt8(p) : bytes === 2 ? v.getInt16(p, le) : v.getInt32(p, le);
  const min = kind === 'f' ? -Infinity : kind === 'u' ? 0 : -(2 ** (bytes * 8 - 1));
  const max = kind === 'f' ? Infinity : 2 ** (bytes * 8 - (kind === 'i' ? 1 : 0)) - 1;
  return { bytes, kind, min, max, read };
}
function displaySample(value: number, dt: DType, isFill = false): number {
  if (typeof value !== 'number' || (dt.kind !== 'f' && (!Number.isInteger(value) || value < dt.min || value > dt.max))) fail('malformed-zarr', `${isFill ? 'Fill value' : 'Pixel'} is outside its declared Zarr dtype.`);
  const converted = Math.fround(value);
  if (Number.isFinite(value) && !Number.isFinite(converted)) fail('unsupported-intensity-range', `A finite ${isFill ? 'fill value' : 'float64 pixel'} exceeds the Float32 display range. Re-encode or rescale the intensity data.`);
  if (dt.kind !== 'f' && converted !== value) fail('unsupported-intensity-precision', `A 32-bit integer ${isFill ? 'fill value' : 'pixel'} cannot be represented exactly by the Float32 viewer. Re-encode to a supported intensity range; labels must remain 16-bit.`);
  return converted;
}
function axisKind(name: string, type: unknown): WorkspaceAxis['kind'] { const lower = name.toLowerCase(); if (lower === 'x' || lower === 'y' || lower === 'z') return lower; if (lower === 't' || type === 'time') return 'time'; if (lower === 'c' || type === 'channel') return 'channel'; return 'other'; }
function transforms(value: unknown, rank: number, scale: number[], translation: number[]): void {
  if (value === undefined) return;
  for (const raw of list(value, 'Coordinate transformations', 32)) {
    const item = object(raw, 'Coordinate transformation'); const type = item.type;
    if (type !== 'scale' && type !== 'translation') fail('unsupported-transform', `Unsupported NGFF coordinate transform ${String(type)}.`);
    const numbers = list(item[type], String(type), 16); if (numbers.length !== rank) fail('malformed-zarr', 'Coordinate transform rank does not match the array.');
    for (let i = 0; i < rank; i++) {
      const n = finite(numbers[i], `Coordinate ${type}`);
      if (type === 'scale') { if (n <= 0) fail('malformed-zarr', 'NGFF scales must be positive.'); scale[i] *= n; translation[i] *= n; }
      else translation[i] += n;
      if (!Number.isFinite(scale[i]) || !Number.isFinite(translation[i])) fail('malformed-zarr', 'Coordinate transforms overflow.');
    }
  }
}
/** Reads NGFF/Zarr v2 only, from a host-owned local directory. Blosc, filters,
 * sharding and v3 fail explicitly instead of silently displaying wrong pixels. */
export async function openOMEZarr(store: LocalByteStore, options: OperationOptions = {}): Promise<ZarrDataset> {
  const limits = resourceLimits(options); let totalBytes = 0; const metadata: Uint8Array[] = [];
  const readJSON = async (path: string, required = true): Promise<JSONRecord | null> => {
    checkAbort(options.signal); const remaining = limits.maxMetadataBytes - totalBytes;
    if (remaining <= 0) fail('resource-limit', 'OME-Zarr metadata exceeds the local budget.');
    const bytes = await store.read(safeRelativePath(path), remaining, options.signal); checkAbort(options.signal);
    if (!bytes) { if (required) fail('metadata-missing', `OME-Zarr metadata is missing at ${path}.`); return null; }
    if (bytes.byteLength > remaining) fail('resource-limit', 'OME-Zarr metadata exceeds the local budget.');
    totalBytes += bytes.byteLength; metadata.push(bytes);
    try { return object(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)), path); }
    catch (error) { if (error instanceof Error && error.name === 'WorkspaceError') throw error; fail('malformed-zarr', `Invalid JSON metadata at ${path}.`); }
  };
  const attrs = await readJSON('.zattrs', false);
  if (!attrs) {
    if (await store.read('zarr.json', limits.maxMetadataBytes, options.signal)) fail('unsupported-version', 'Zarr v3 is not supported. Re-encode this dataset as Zarr v2.');
    fail('metadata-missing', 'Choose a local OME-Zarr directory containing .zattrs.');
  }
  const arrays: ZarrArray[] = []; let datasetName = store.name; let plate: WorkspacePlate | undefined;
  const appendArrays = async (attributes: JSONRecord, prefix = '', fieldPath?: string): Promise<void> => {
    const multiscales = list(attributes.multiscales, 'NGFF multiscales', 32);
    if (!multiscales.length) fail('malformed-zarr', 'NGFF multiscales is empty.');
    if (multiscales.length > 1) fail('unsupported-multiscales', 'Choose a local NGFF image/field with one multiscale pyramid. Multiple independent pyramids in one field are unsupported.');
    const pyramidStart = arrays.length;
    for (const rawScale of multiscales) {
      const multiscale = object(rawScale, 'NGFF multiscale');
      if (typeof multiscale.name === 'string' && !prefix) datasetName = multiscale.name;
      for (const rawDataset of list(multiscale.datasets, 'Multiscale datasets')) {
        if (arrays.length >= 256) fail('resource-limit', 'This workspace supports at most 256 local pyramid arrays/fields.');
        const dataset = object(rawDataset, 'Multiscale dataset'); const relative = safeRelativePath(text(dataset.path, 'Array path')); const path = prefix ? `${prefix}/${relative}` : relative;
        if (arrays.some(array => array.path === path)) fail('malformed-zarr', 'NGFF array paths must be unique.');
        const meta = (await readJSON(`${path}/.zarray`))!;
        if (meta.zarr_format !== 2) fail('unsupported-version', `Zarr format ${String(meta.zarr_format)} is not supported. Use v2.`);
        const shape = list(meta.shape, 'Array shape', 16).map(n => integer(n, 'Shape dimension', 1));
        const chunks = list(meta.chunks, 'Chunk shape', 16).map(n => integer(n, 'Chunk dimension', 1));
        if (shape.length < 2 || chunks.length !== shape.length) fail('malformed-zarr', 'Array shape/chunks must have matching ranks of at least two.');
        const rank = shape.length; const dt = dtype(text(meta.dtype, 'Data type')); product([...chunks, dt.bytes], 'Decoded chunk bytes', limits.maxDecodedChunkBytes);
        if (meta.order !== 'C') fail('unsupported-order', 'Only C-order Zarr arrays are supported.');
        if (meta.filters !== undefined && meta.filters !== null && list(meta.filters, 'Filters').length) fail('unsupported-codec', 'Zarr filters are unsupported. Re-encode without filters.');
        let compressor: ZarrArray['compressor'] = null;
        if (meta.compressor !== null && meta.compressor !== undefined) {
          const codec = object(meta.compressor, 'Compressor');
          if (codec.id !== 'zlib' && codec.id !== 'gzip') fail('unsupported-codec', `Zarr codec ${String(codec.id)} is unavailable. Re-encode with no compression, zlib or gzip.`);
          compressor = codec.id;
        }
        const separator = meta.dimension_separator ?? '.'; if (separator !== '.' && separator !== '/') fail('malformed-zarr', 'Invalid Zarr dimension separator.');
        const defaultAxes = rank === 2 ? ['y', 'x'] : rank === 3 ? ['c', 'y', 'x'] : rank === 4 ? ['z', 'c', 'y', 'x'] : [...Array.from({ length: Math.max(0, rank - 5) }, (_, i) => `axis${i}`), 't', 'z', 'c', 'y', 'x'];
        const axisMeta = multiscale.axes === undefined ? defaultAxes : list(multiscale.axes, 'NGFF axes', 16);
        if (axisMeta.length !== rank) fail('malformed-zarr', 'NGFF axes rank disagrees with the array.');
        const scale = Array<number>(rank).fill(1); const translation = Array<number>(rank).fill(0);
        transforms(dataset.coordinateTransformations, rank, scale, translation); transforms(multiscale.coordinateTransformations, rank, scale, translation);
        const names = new Set<string>(); const kinds = new Set<string>();
        const axes = axisMeta.map((raw, i): WorkspaceAxis => {
          const item = typeof raw === 'string' ? { name: raw } : object(raw, 'NGFF axis'); const name = text(item.name, 'Axis name'); const kind = axisKind(name, item.type);
          if (names.has(name) || (kind !== 'other' && kinds.has(kind))) fail('malformed-zarr', 'NGFF axis names/kinds must be unique.'); names.add(name); kinds.add(kind);
          if (item.unit !== undefined && typeof item.unit !== 'string') fail('malformed-zarr', 'Axis units must be strings.');
          const unit = typeof item.unit === 'string' && item.unit.trim() ? item.unit : undefined;
          const hasScale = [...(Array.isArray(dataset.coordinateTransformations) ? dataset.coordinateTransformations : []), ...(Array.isArray(multiscale.coordinateTransformations) ? multiscale.coordinateTransformations : [])].some(raw => raw && typeof raw === 'object' && (raw as JSONRecord).type === 'scale');
          return { id: `${store.id}:axis:${name}`, name, kind, length: shape[i], scale: scale[i], unit, calibrated: Boolean(unit && hasScale) };
        });
        if (!axes.some(a => a.kind === 'x') || !axes.some(a => a.kind === 'y')) fail('malformed-zarr', 'NGFF arrays must identify distinct X and Y axes.');
        const base = arrays[pyramidStart];
        if (base) for (const axis of axes.filter(axis => axis.kind !== 'x' && axis.kind !== 'y')) { const baseIndex = base.axes.findIndex(a => a.name === axis.name && a.kind === axis.kind), index = axes.findIndex(a => a.name === axis.name); if (baseIndex < 0 || base.axes[baseIndex].length !== axis.length || base.axes[baseIndex].scale !== axis.scale || base.axes[baseIndex].unit !== axis.unit || base.translation[baseIndex] !== translation[index]) fail('unsupported-pyramid-axis', 'Nonspatial and Z axes must retain the same identity, length, scale and translation across pyramid levels.'); }
        let fillValue = 0;
        if (meta.fill_value !== null && meta.fill_value !== undefined) { if (meta.fill_value === 'NaN') fillValue = NaN; else if (meta.fill_value === 'Infinity') fillValue = Infinity; else if (meta.fill_value === '-Infinity') fillValue = -Infinity; else fillValue = finite(meta.fill_value, 'Fill value'); }
        displaySample(fillValue, dt, true);
        arrays.push({ path, fieldPath, shape, chunks, dtype: meta.dtype as string, compressor, order: 'C', separator, fillValue, axes, translation });
      }
    }
  };
  if (attrs.plate) {
    const p = object(attrs.plate, 'NGFF plate'); const names = (raw: unknown, title: string) => list(raw ?? [], title, 1024).map(v => text(object(v, title).name, title));
    const rows = names(p.rows, 'Plate rows'); const columns = names(p.columns, 'Plate columns');
    if (new Set(rows).size !== rows.length || new Set(columns).size !== columns.length) fail('malformed-zarr', 'Plate row/column names must be unique.');
    plate = { name: typeof p.name === 'string' ? p.name : store.name, rows, columns, wells: [] };
    for (const rawWell of list(p.wells ?? [], 'Plate wells', 1024)) {
      const well = object(rawWell, 'Plate well'); const path = safeRelativePath(text(well.path, 'Well path')); const parts = path.split('/');
      const row = well.rowIndex === undefined ? rows.indexOf(parts[0]) : integer(well.rowIndex, 'Well row index', 0, rows.length - 1);
      const column = well.columnIndex === undefined ? columns.indexOf(parts[1]) : integer(well.columnIndex, 'Well column index', 0, columns.length - 1);
      if (row < 0 || column < 0) fail('malformed-zarr', 'Well path does not identify a declared row/column.');
      const wellAttrs = await readJSON(`${path}/.zattrs`); const images = list(object(wellAttrs!.well, 'Well metadata').images, 'Well images', 256);
      const fields = [];
      for (const [index, rawImage] of images.entries()) {
        const fieldPath = `${path}/${safeRelativePath(text(object(rawImage, 'Well image').path, 'Field path'))}`;
        fields.push({ id: `${store.id}:${fieldPath}`, name: `Field ${index + 1}`, path: fieldPath, layerIDs: [] });
        await appendArrays((await readJSON(`${fieldPath}/.zattrs`))!, fieldPath, fieldPath);
      }
      plate.wells.push({ id: `${store.id}:${path}`, row, column, label: rows[row] + columns[column], path, fields });
    }
  }
  if (attrs.multiscales) await appendArrays(attrs);
  if (!arrays.length) fail('malformed-zarr', 'This NGFF directory has no readable image arrays.');
  const allMetadata = new Uint8Array(totalBytes); let offset = 0; for (const bytes of metadata) { allMetadata.set(bytes, offset); offset += bytes.byteLength; }
  const hash = await sha256(allMetadata); checkAbort(options.signal);
  const channels: ZarrDataset['channels'] = [];
  if (attrs.omero && typeof attrs.omero === 'object') {
    const omero = object(attrs.omero, 'OMERO metadata');
    for (const raw of list(omero.channels ?? [], 'OMERO channels', 1024)) {
      const channel = object(raw, 'OMERO channel'); const hex = typeof channel.color === 'string' && /^[0-9a-f]{6}$/i.test(channel.color) ? channel.color : 'ffffff';
      const window = channel.window && typeof channel.window === 'object' ? object(channel.window, 'Channel window') : {};
      channels.push({ name: typeof channel.label === 'string' ? channel.label : `Channel ${channels.length + 1}`, color: [parseInt(hex.slice(0, 2), 16), parseInt(hex.slice(2, 4), 16), parseInt(hex.slice(4, 6), 16)], min: typeof window.start === 'number' && Number.isFinite(window.start) ? window.start : undefined, max: typeof window.end === 'number' && Number.isFinite(window.end) ? window.end : undefined });
    }
  }
  return { name: datasetName, source: { id: store.id, name: store.name, kind: 'zarr', metadataSha256: hash }, arrays, plate, channels };
}

export async function sha256(bytes: Uint8Array): Promise<string> { const hash = await crypto.subtle.digest('SHA-256', bytes.slice().buffer); return Array.from(new Uint8Array(hash), b => b.toString(16).padStart(2, '0')).join(''); }
async function decompress(encoded: Uint8Array, compressor: ZarrArray['compressor'], expectedBytes: number, signal?: AbortSignal): Promise<Uint8Array> {
  if (!compressor) { if (encoded.byteLength !== expectedBytes) fail('corrupt-chunk', `Zarr chunk has ${encoded.byteLength} bytes; expected ${expectedBytes}.`); return encoded; }
  if (typeof DecompressionStream === 'undefined') fail('unsupported-codec', 'This browser runtime cannot decompress Zarr chunks. Use uncompressed arrays.');
  checkAbort(signal);
  // Incremental read bounds decoded output, including hostile compression bombs.
  const stream = new Blob([encoded.slice().buffer]).stream().pipeThrough(new DecompressionStream(compressor === 'zlib' ? 'deflate' : 'gzip'));
  const reader = stream.getReader(); const output = new Uint8Array(expectedBytes); let offset = 0;
  const cancel = () => { void reader.cancel().catch(() => {}); }; signal?.addEventListener('abort', cancel, { once: true });
  try { while (true) { checkAbort(signal); const result = await reader.read(); checkAbort(signal); if (result.done) break; if (result.value.length > expectedBytes - offset) fail('corrupt-chunk', 'Decoded Zarr chunk exceeds its declared shape.'); output.set(result.value, offset); offset += result.value.length; }
    if (offset !== expectedBytes) fail('corrupt-chunk', `Decoded Zarr chunk has ${offset} bytes; expected ${expectedBytes}.`);
    return output;
  } catch (error) { checkAbort(signal); if (error instanceof Error && error.name === 'WorkspaceError') throw error; return fail('corrupt-chunk', `Failed to decompress a ${compressor} chunk.`); }
  finally { signal?.removeEventListener('abort', cancel); void reader.cancel().catch(() => {}); reader.releaseLock(); }
}
export function calibrationFromAxes(axes: WorkspaceAxis[]): ImagePlane['calibration'] {
  const x = axes.find(a => a.kind === 'x'); const y = axes.find(a => a.kind === 'y');
  if (!x?.calibrated || !y?.calibrated || !x.unit || x.unit !== y.unit) return undefined;
  return { x: x.scale, y: y.scale, unit: x.unit };
}
/** Only the selected plane's intersecting chunks are read. Missing v2 chunks
 * use the declared fill value (the Zarr sparse-array rule). No whole-stack load. */
export async function loadZarrPlane(store: LocalByteStore, dataset: ZarrDataset, selection: ZarrPlaneSelection = {}, options: OperationOptions = {}): Promise<ImagePlane> {
  const limits: ResourceLimits = resourceLimits(options); checkAbort(options.signal);
  if (store.id !== dataset.source.id) fail('source-mismatch', 'The selected local source does not match the inspected dataset.');
  const level = integer(selection.level ?? 0, 'Pyramid level', 0, dataset.arrays.length - 1); const array = dataset.arrays[level];
  const rank = array.shape.length; const xAxis = array.axes.findIndex(a => a.kind === 'x'); const yAxis = array.axes.findIndex(a => a.kind === 'y');
  if (xAxis < 0 || yAxis < 0 || array.chunks.length !== rank || array.axes.length !== rank) fail('malformed-zarr', 'Array axes/chunks are invalid.');
  const width = array.shape[xAxis]; const height = array.shape[yAxis]; const n = product([width, height], 'Plane pixels', limits.maxPixels); const dt = dtype(array.dtype);
  const chunkBytes = product([...array.chunks, dt.bytes], 'Decoded chunk bytes', limits.maxDecodedChunkBytes);
  // Decompression retains the encoded input, its typed-array copy and Blob,
  // plus bounded output/reader buffering. Uncompressed bytes are read in place.
  // Lower the host's read cap to available headroom before any chunk allocation.
  const decodedWorking = array.compressor ? chunkBytes * 3 : 0;
  const encodedCopies = array.compressor ? 3 : 1;
  const encodedLimit = Math.min(limits.maxEncodedChunkBytes, Math.floor((limits.maxWorkingBytes - n * 4 - decodedWorking - 1024 * 1024) / encodedCopies));
  if (encodedLimit < 1 || (!array.compressor && chunkBytes > encodedLimit)) fail('resource-limit', 'This plane and its chunks exceed the working memory budget. Use a coarser pyramid level.');
  const fixed = array.axes.map((axis, index) => {
    if (index === xAxis || index === yAxis) return 0;
    const value = selection.indices?.[axis.name] ?? selection.indices?.[axis.id] ?? (axis.kind === 'time' ? selection.t : axis.kind === 'z' ? selection.z : axis.kind === 'channel' ? selection.c : undefined) ?? 0;
    return integer(value, `Selected ${axis.name} index`, 0, array.shape[index] - 1);
  });
  const xChunks = Math.ceil(width / array.chunks[xAxis]); const yChunks = Math.ceil(height / array.chunks[yAxis]); const chunkCount = product([xChunks, yChunks], 'Intersecting chunk count', limits.maxChunksPerPlane);
  const strides = Array<number>(rank).fill(1); for (let i = rank - 2; i >= 0; i--) strides[i] = strides[i + 1] * array.chunks[i + 1];
  const baseIndex = fixed.reduce((sum, value, index) => sum + (value % array.chunks[index]) * strides[index], 0);
  const fillValue = displaySample(array.fillValue, dt, true);
  const values = new Float32Array(n); if (fillValue !== 0) values.fill(fillValue); let complete = 0;
  for (let cy = 0; cy < yChunks; cy++) for (let cx = 0; cx < xChunks; cx++) {
    checkAbort(options.signal); const coords = fixed.map((value, index) => Math.floor(value / array.chunks[index])); coords[xAxis] = cx; coords[yAxis] = cy;
    const path = `${safeRelativePath(array.path)}/${coords.join(array.separator)}`;
    const encoded = await store.read(path, encodedLimit, options.signal); checkAbort(options.signal);
    if (encoded) {
      if (encoded.byteLength > encodedLimit) fail('resource-limit', 'Encoded chunk exceeds the available local byte budget.');
      const bytes = await decompress(encoded, array.compressor, chunkBytes, options.signal); const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      const startX = cx * array.chunks[xAxis]; const startY = cy * array.chunks[yAxis]; const countX = Math.min(array.chunks[xAxis], width - startX); const countY = Math.min(array.chunks[yAxis], height - startY);
      for (let y = 0; y < countY; y++) {
        if (y % 64 === 0) await yieldTask(options.signal);
        const sourceRow = baseIndex + y * strides[yAxis]; const targetRow = (startY + y) * width + startX;
        for (let x = 0; x < countX; x++) {
          values[targetRow + x] = displaySample(dt.read(view, (sourceRow + x * strides[xAxis]) * dt.bytes), dt);
        }
      }
    }
    options.onProgress?.(++complete / chunkCount);
  }
  checkAbort(options.signal); return { width, height, values, calibration: calibrationFromAxes(array.axes) };
}
export function arrayForViewport(dataset: ZarrDataset, width: number, height: number, fieldPath?: string): number {
  finite(width, 'Viewport width'); finite(height, 'Viewport height'); if (width <= 0 || height <= 0) fail('invalid-viewport', 'Viewport dimensions must be positive.');
  const candidates = dataset.arrays.map((array, index) => ({ array, index, width: array.shape[array.axes.findIndex(a => a.kind === 'x')], height: array.shape[array.axes.findIndex(a => a.kind === 'y')] })).filter(v => fieldPath === undefined || v.array.fieldPath === fieldPath);
  if (!candidates.length) fail('missing-array', 'No arrays exist for this field.');
  const adequate = candidates.filter(v => v.width >= width && v.height >= height);
  const chosen = (adequate.length ? adequate.sort((a, b) => a.width * a.height - b.width * b.height) : candidates.sort((a, b) => b.width * b.height - a.width * a.height))[0]; return chosen.index;
}
