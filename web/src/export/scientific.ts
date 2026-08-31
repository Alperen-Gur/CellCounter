import { contourPoints, type ExportCell } from "./types";
import { deterministicJson } from "./tabular";

export function exportCellsGeoJson(cells: readonly ExportCell[], properties: Readonly<Record<string, unknown>> = {}): string {
  const features = [...cells].sort((a, b) => a.id.localeCompare(b.id)).map((cell) => {
    let points = contourPoints(cell);
    let twiceSignedArea = 0;
    for (let index = 0; index < points.length; index += 1) {
      const current = points[index]; const next = points[(index + 1) % points.length];
      twiceSignedArea += current.x * next.y - next.x * current.y;
    }
    // RFC 7946's right-hand rule is applied to the numeric x/y coordinate pair,
    // even though image-space y points down on screen.
    if (twiceSignedArea < 0) points = [...points].reverse();
    const closed = [...points, points[0]].map(({ x, y }) => [x, y]);
    return {
      type: "Feature",
      id: cell.id,
      properties: {
        ...properties,
        cell_id: cell.id,
        centroid_x_px: cell.cx,
        centroid_y_px: cell.cy,
        diameter_px: cell.diameterPx,
        diameter_um: cell.diameterUm ?? null,
        confidence: cell.confidence ?? null,
        is_manual: Boolean(cell.isManual),
      },
      geometry: { type: "Polygon", coordinates: [closed] },
    };
  });
  return deterministicJson({
    type: "FeatureCollection",
    cellcounter_coordinate_convention: "source-image pixel coordinates (x right, y down); not WGS84 longitude/latitude",
    features,
  });
}

/** NumPy v1.0, C-order, little-endian uint32 label image (Cellpose `_seg.npy` substrate). */
export function encodeLabelMapNpy(labels: Uint32Array, width: number, height: number): Uint8Array {
  if (width <= 0 || height <= 0 || labels.length !== width * height) throw new RangeError("Label-map dimensions do not match its data.");
  const encoder = new TextEncoder();
  const base = `{'descr': '<u4', 'fortran_order': False, 'shape': (${height}, ${width}), }`;
  const headerLength = Math.ceil((10 + base.length + 1) / 64) * 64 - 10;
  if (headerLength > 65_535) throw new RangeError("NPY v1 header exceeds 65,535 bytes.");
  const header = encoder.encode(base.padEnd(headerLength - 1, " ") + "\n");
  const output = new Uint8Array(10 + header.length + labels.length * 4);
  output.set([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59, 1, 0], 0);
  output[8] = header.length & 0xff; output[9] = header.length >>> 8;
  output.set(header, 10);
  const view = new DataView(output.buffer);
  for (let index = 0; index < labels.length; index += 1) view.setUint32(10 + header.length + index * 4, labels[index], true);
  return output;
}

/** Safe bare-mask interchange; not the Cellpose GUI's pickled dictionary `_seg.npy` session. */
export function buildBareSegmentationNpyPayload(labels: Uint32Array, width: number, height: number, metadata: Readonly<Record<string, unknown>> = {}): { readonly npy: Uint8Array; readonly metadataJson: string } {
  return { npy: encodeLabelMapNpy(labels, width, height), metadataJson: deterministicJson({ schemaVersion: 1, shape: [height, width], dtype: "uint32", ...metadata }) };
}
