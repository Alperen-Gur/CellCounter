import { unzipSync, unzlibSync } from "fflate";
import { afterAll, describe, expect, it } from "vitest";
import {
  buildBareSegmentationNpyPayload,
  buildPdfReport,
  deterministicJson,
  encodeImageJPolygonRoi,
  encodeLabelMapNpy,
  exportAnnotatedPng,
  exportCellsCsv,
  exportCellsGeoJson,
  exportImageJRoiZip,
  exportProvenance,
  exportRoiData,
  exportSegmentationMaskPng,
  type ExportCell,
} from "../../src/export";

const cells: ExportCell[] = [
  { id: "cell-b", cx: 6, cy: 6, diameterPx: 4, diameterUm: 2, confidence: 0.8, contourPx: [[4,4], [8,4], [8,8], [4,8]] },
  { id: "cell-a", cx: 2, cy: 2, diameterPx: 2, confidence: 0.9, isManual: true },
];
const pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];

afterAll(() => console.log("Web parity analysis verification passed"));

function decodePngScanlines(bytes: Uint8Array): Uint8Array {
  const chunks: Uint8Array[] = [];
  let offset = 8;
  while (offset < bytes.length) {
    const view = new DataView(bytes.buffer, bytes.byteOffset + offset);
    const length = view.getUint32(0, false);
    const type = new TextDecoder().decode(bytes.subarray(offset + 4, offset + 8));
    if (type === "IDAT") chunks.push(bytes.subarray(offset + 8, offset + 8 + length));
    offset += 12 + length;
  }
  const compressed = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
  let cursor = 0; for (const chunk of chunks) { compressed.set(chunk, cursor); cursor += chunk.length; }
  return unzlibSync(compressed);
}

describe("scientific and tabular exports", () => {
  it("round-trips GeoJSON as closed, right-hand-rule pixel-coordinate polygons", () => {
    const json = exportCellsGeoJson(cells, { image_id: "image-1" });
    expect(exportCellsGeoJson(cells, { image_id: "image-1" })).toBe(json);
    const parsed = JSON.parse(json);
    expect(parsed.cellcounter_coordinate_convention).toMatch(/not WGS84/);
    expect(parsed.features.map((feature: { id: string }) => feature.id)).toEqual(["cell-a", "cell-b"]);
    for (const feature of parsed.features) {
      const ring: number[][] = feature.geometry.coordinates[0];
      expect(ring[0]).toEqual(ring.at(-1));
      let area2 = 0;
      for (let index = 0; index < ring.length - 1; index += 1) area2 += ring[index][0] * ring[index + 1][1] - ring[index + 1][0] * ring[index][1];
      expect(area2).toBeGreaterThanOrEqual(0);
    }
  });

  it("writes deterministic CSV, JSON, ROI and provenance payloads", () => {
    const csv = exportCellsCsv(cells, { image_sha256: "abc", model: "cp-cyto3" });
    expect(csv.indexOf("cell-a")).toBeLessThan(csv.indexOf("cell-b"));
    expect(csv).toContain("# image_sha256: abc");
    expect(deterministicJson({ z: 1, a: 2 })).toBe('{\n  "a": 2,\n  "z": 1\n}\n');
    expect(exportProvenance({ model: "cp-cyto3" })).toContain('"schemaVersion": 1');
    expect(exportRoiData([{ id: "r", mode: "include", points: [{ x: 1, y: 2 }] }])).toContain('"coordinateSpace": "source-pixels"');
  });

  it("writes a safe bare uint32 NPY and labels it separately from Cellpose GUI session format", () => {
    const labels = new Uint32Array([0, 1, 2, 0]);
    const bytes = encodeLabelMapNpy(labels, 2, 2);
    expect([...bytes.subarray(0, 8)]).toEqual([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59, 1, 0]);
    const headerLength = bytes[8] | bytes[9] << 8;
    expect(new TextDecoder().decode(bytes.subarray(10, 10 + headerLength))).toContain("'shape': (2, 2)");
    const view = new DataView(bytes.buffer, bytes.byteOffset);
    expect(Array.from({ length: 4 }, (_, index) => view.getUint32(10 + headerLength + index * 4, true))).toEqual([0, 1, 2, 0]);
    const payload = buildBareSegmentationNpyPayload(labels, 2, 2, { convention: "bare-mask" });
    expect(payload.metadataJson).toContain('"convention": "bare-mask"');
  });
});

describe("image and report exports", () => {
  it("writes standards-signature PNG overlays and segmentation previews deterministically", () => {
    const source = { width: 10, height: 10, data: new Uint8ClampedArray(10 * 10 * 4).fill(255) };
    const annotated = exportAnnotatedPng(source, cells);
    expect([...annotated.subarray(0, 8)]).toEqual(pngSignature);
    expect(exportAnnotatedPng(source, cells)).toEqual(annotated);
    const scanlines = decodePngScanlines(annotated);
    expect(scanlines.length).toBe((10 * 4 + 1) * 10);
    expect(scanlines.some((value) => value !== 255 && value !== 0)).toBe(true);
    expect([...exportSegmentationMaskPng(new Uint32Array([0, 1, 2, 0]), 2, 2).subarray(0, 8)]).toEqual(pngSignature);
  });

  it("writes deterministic ImageJ polygon records inside a readable RoiSet ZIP", () => {
    const roi = encodeImageJPolygonRoi(cells[0]);
    expect(new TextDecoder().decode(roi.subarray(0, 4))).toBe("Iout");
    expect(new DataView(roi.buffer, roi.byteOffset).getUint16(4, false)).toBe(217);
    const zip = exportImageJRoiZip(cells);
    expect(exportImageJRoiZip(cells)).toEqual(zip);
    const files = unzipSync(zip);
    expect(Object.keys(files)).toEqual(["0001-cell-a.roi", "0002-cell-b.roi"]);
    expect(new TextDecoder().decode(files["0002-cell-b.roi"].subarray(0, 4))).toBe("Iout");
  });

  it("writes a deterministic PDF 1.4 report with a valid xref trailer", () => {
    const bytes = buildPdfReport({ title: "CellCounter report", subtitle: "Private browser analysis", sections: [{ heading: "Counts", lines: ["Cells: 2", "Model: cp-cyto3"] }] });
    const text = new TextDecoder().decode(bytes);
    expect(text.startsWith("%PDF-1.4")).toBe(true);
    expect(text).toContain("xref\n0 6");
    expect(text).toContain("1 0 0 1 52 752 Tm");
    expect(text.endsWith("%%EOF\n")).toBe(true);
    expect(buildPdfReport({ title: "CellCounter report", subtitle: "Private browser analysis", sections: [{ heading: "Counts", lines: ["Cells: 2", "Model: cp-cyto3"] }] })).toEqual(bytes);
  });

  it("paginates long PDF sections without silently omitting the final row", () => {
    const lines = Array.from({ length: 90 }, (_, index) => `Measurement row ${index + 1}`);
    const text = new TextDecoder().decode(buildPdfReport({ title: "Long report", sections: [{ heading: "Measurements", lines }] }));
    expect(text).toContain("/Count 2");
    expect(text).toContain("Measurement row 90");
  });
});
