import { Braces, Download, FileArchive, FileImage, FileText, Map, Table2, X } from "lucide-react";
import { useMemo, useState } from "react";
import type { WorkspaceImage } from "../app/types";
import { filterCellsByRois } from "../app/roi";
import { exportCellsCsv, exportProvenance, exportRoiData } from "../export";
import { buildWorkspaceArtifact, type WorkspaceArtifactKind } from "../workers/WorkspaceExportClient";

function save(name: string, value: BlobPart, type: string) {
  const url = URL.createObjectURL(new Blob([value], { type })); const anchor = document.createElement("a");
  anchor.href = url; anchor.download = name; anchor.click(); setTimeout(() => URL.revokeObjectURL(url), 0);
}

const artifactTypes: Record<WorkspaceArtifactKind, { extension: string; type: string }> = {
  "annotated-png": { extension: "annotated.png", type: "image/png" }, "mask-png": { extension: "mask.png", type: "image/png" },
  "bare-npy": { extension: "labels.npy", type: "application/octet-stream" }, "imagej-roi": { extension: "RoiSet.zip", type: "application/zip" },
  geojson: { extension: "cells.geojson", type: "application/geo+json" }, pdf: { extension: "report.pdf", type: "application/pdf" },
};

export function ExportDialog({ image, onClose }: { image: WorkspaceImage; onClose: () => void }) {
  const [busy, setBusy] = useState<WorkspaceArtifactKind>();
  const [error, setError] = useState<string>();
  const stem = image.fileName.replace(/\.[^.]+$/, "");
  const cells = useMemo(() => filterCellsByRois(image), [image]);
  const provenance = useMemo(() => ({
    appVersion: "0.1.0", appBuild: "web", exportedAt: new Date().toISOString(), coordinateSpace: "source-image pixels",
    calibration: { pxPerUm: image.pxPerUm, source: image.calibrationSource ?? "default", confidence: image.calibrationConfidence ?? "low" },
    originalSource: image.analysis?.originalSource ?? (image.sourceSha256 ? { fileName: image.fileName, mediaType: image.sourceMediaType, byteLength: image.sourceByteLength, sha256: image.sourceSha256 } : null),
    analysisRaster: image.analysis?.image ?? null, model: image.analysis?.model ?? null, parameters: image.analysis?.parameters ?? null,
    correctionLog: image.analysis?.correctionLog ?? [], rois: image.rois, note: image.note,
  }), [image]);
  const regions = image.rois.map((roi) => ({ id: roi.id, mode: roi.kind, points: [{ x: roi.x, y: roi.y }, { x: roi.x + roi.width, y: roi.y }, { x: roi.x + roi.width, y: roi.y + roi.height }, { x: roi.x, y: roi.y + roi.height }] }));

  const artifact = async (kind: WorkspaceArtifactKind) => {
    setBusy(kind); setError(undefined);
    try {
      const result = await buildWorkspaceArtifact(kind, { source: kind === "annotated-png" ? image.file : undefined, cells, width: image.width, height: image.height, title: `CellCounter · ${image.fileName}`, provenance });
      const spec = artifactTypes[kind]; save(`${stem}-${spec.extension}`, result.bytes, spec.type);
      if (result.sidecar) save(`${stem}-labels-metadata.json`, result.sidecar, "application/json");
    } catch (cause) { setError(cause instanceof Error ? cause.message : String(cause)); }
    finally { setBusy(undefined); }
  };

  return <div className="dialog-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}><section className="export-dialog" role="dialog" aria-modal="true" aria-labelledby="export-heading">
    <header><div><span className="eyebrow">Local artifacts</span><h2 id="export-heading">Export study result</h2><p>Every format is generated on this device from source-coordinate geometry.</p></div><button className="icon-button" onClick={onClose} aria-label="Close export"><X size={17} /></button></header>
    <div className="export-grid">
      <button onClick={() => save(`${stem}-cells.csv`, exportCellsCsv(cells, provenance), "text/csv;charset=utf-8")}><Table2 /><span><strong>Cells CSV</strong><small>Stable columns + provenance</small></span><Download /></button>
      <button onClick={() => save(`${stem}-provenance.json`, exportProvenance(provenance), "application/json")}><Braces /><span><strong>Analysis JSON</strong><small>Source, raster, model, calibration</small></span><Download /></button>
      <button onClick={() => void artifact("imagej-roi")} disabled={Boolean(busy)}><FileArchive /><span><strong>ImageJ ROI ZIP</strong><small>Polygon RoiSet.zip</small></span><Download /></button>
      <button onClick={() => void artifact("geojson")} disabled={Boolean(busy)}><Map /><span><strong>GeoJSON contours</strong><small>Pixel-coordinate RFC 7946 polygons</small></span><Download /></button>
      <button onClick={() => void artifact("annotated-png")} disabled={Boolean(busy) || !image.sourceLoaded}><FileImage /><span><strong>Annotated PNG</strong><small>Full-resolution local overlay</small></span><Download /></button>
      <button onClick={() => void artifact("mask-png")} disabled={Boolean(busy)}><FileImage /><span><strong>Label mask PNG</strong><small>Deterministic corrected labels</small></span><Download /></button>
      <button onClick={() => void artifact("pdf")} disabled={Boolean(busy)}><FileText /><span><strong>PDF lab report</strong><small>Paginated reproducibility report</small></span><Download /></button>
      <button onClick={() => void artifact("bare-npy")} disabled={Boolean(busy)}><Braces /><span><strong>Bare uint32 NPY</strong><small>Safe label map; not Cellpose GUI session</small></span><Download /></button>
      <button onClick={() => save(`${stem}-regions.json`, exportRoiData(regions), "application/json")}><Map /><span><strong>ROI JSON</strong><small>Include/exclude source polygons</small></span><Download /></button>
    </div>
    {busy && <p className="export-status">Building {artifactTypes[busy].extension} in a disposable Worker…</p>}
    {error && <p className="export-error" role="alert">{error}</p>}
  </section></div>;
}
