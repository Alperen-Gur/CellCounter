import { Braces, Download, FileArchive, FileImage, FileText, Map, Table2, X } from "lucide-react";
import { useDialogFocus } from "../hooks/useDialogFocus";
import { useEffect, useMemo, useRef, useState } from "react";
import type { WorkspaceImage } from "../app/types";
import { exportGroundTruthCsv, exportMarkdownReport } from "../export/bundles";
import { filterCellsByRois } from "../app/roi";
import { exportCellsCsv, exportProvenance, exportRoiData } from "../export";
import { buildWorkspaceArtifact, type WorkspaceArtifactKind } from "../workers/WorkspaceExportClient";

function downloadFile(name: string, value: BlobPart, type: string) {
  const url = URL.createObjectURL(new Blob([value], { type })); const anchor = document.createElement("a");
  anchor.href = url; anchor.download = name; anchor.click(); setTimeout(() => URL.revokeObjectURL(url), 0);
}

const artifactTypes: Record<WorkspaceArtifactKind, { extension: string; type: string }> = {
  "annotated-png": { extension: "annotated.png", type: "image/png" }, "mask-png": { extension: "mask.png", type: "image/png" },
  "bare-npy": { extension: "labels.npy", type: "application/octet-stream" }, "imagej-roi": { extension: "RoiSet.zip", type: "application/zip" },
  "sample-bundle": { extension: "sample.zip", type: "application/zip" },
  geojson: { extension: "cells.geojson", type: "application/geo+json" }, pdf: { extension: "report.pdf", type: "application/pdf" },
};

export function ExportDialog({ image, onClose }: { image: WorkspaceImage; onClose: () => void }) {
  const dialog = useDialogFocus(true);
  const abort = useRef<AbortController | undefined>(undefined);
  useEffect(() => () => abort.current?.abort(), []);
  const [status, setStatus] = useState<string>();
  const save = (name: string, value: BlobPart, type: string) => { downloadFile(name, value, type); setStatus("Download prepared. Check your browser downloads."); };
  const [busy, setBusy] = useState<WorkspaceArtifactKind>();
  const [error, setError] = useState<string>();
  const stem = image.fileName.replace(/\.[^.]+$/, "");
  const cells = useMemo(() => filterCellsByRois(image), [image]);
  const provenance = useMemo(() => ({
    appVersion: "0.3.0", appBuild: "web", exportedAt: new Date().toISOString(), coordinateSpace: "source-image pixels",
    calibration: { pxPerUm: image.pxPerUm, source: image.calibrationSource ?? "default", confidence: image.calibrationConfidence ?? "low" },
    originalSource: image.analysis?.originalSource ?? (image.sourceSha256 ? { fileName: image.fileName, mediaType: image.sourceMediaType, byteLength: image.sourceByteLength, sha256: image.sourceSha256 } : null),
    analysisRaster: image.analysis?.image ?? null, model: image.analysis?.model ?? null, parameters: image.analysis?.parameters ?? null,
    workflow: image.analysis?.workflow ?? null,
    correctionLog: image.analysis?.correctionLog ?? [], groundTruth: image.groundTruth, rois: image.rois, note: image.note, reviewConfidence: image.reviewConfidence, channelNames: image.channelNames, reviewRevision: image.editRevision ?? 0, imageProvenance: image.provenance,
  }), [image]);
  const sourceIsTiff = /\.tiff?$/i.test(image.fileName) || /tiff/i.test([image.sourceMediaType, image.originalFile?.type, image.file.type, image.analysis?.originalSource?.mediaType].join(" "));
  const planeExportBlocked = Boolean((image.analysisId || image.analysis) && sourceIsTiff && !image.analysis?.displayPlane);
  const regions = image.rois.map((roi) => ({ id: roi.id, mode: roi.kind, points: [{ x: roi.x, y: roi.y }, { x: roi.x + roi.width, y: roi.y }, { x: roi.x + roi.width, y: roi.y + roi.height }, { x: roi.x, y: roi.y + roi.height }] }));

  const artifact = async (kind: WorkspaceArtifactKind) => {
    const controller = new AbortController(); abort.current = controller;
    setBusy(kind); setError(undefined); setStatus(undefined);
    try {
      if (planeExportBlocked && (kind === "sample-bundle" || kind === "annotated-png")) throw new Error("This historical TIFF analysis has no captured source plane. Rerun the saved setup before exporting a source-aligned overlay or sample bundle.");
      const result = await buildWorkspaceArtifact(kind, { source: kind === "annotated-png" || kind === "sample-bundle" ? image.file : undefined, originalSource: kind === "sample-bundle" ? image.originalFile ?? image.file : undefined, originalFileName: image.fileName, groundTruth: image.groundTruth, cells, width: image.width, height: image.height, title: `CellCounter · ${image.fileName}`, provenance }, controller.signal);
      if (controller.signal.aborted) return;
      const spec = artifactTypes[kind]; save(`${stem}-${spec.extension}`, result.bytes, spec.type);
      if (result.sidecar) save(`${stem}-labels-metadata.json`, result.sidecar, "application/json");
    } catch (cause) { setError(cause instanceof Error ? cause.message : String(cause)); }
    finally { if (abort.current === controller) { setBusy(undefined); abort.current = undefined; } }
  };

  return <div className="dialog-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}><section ref={dialog} tabIndex={-1} className="export-dialog" role="dialog" aria-modal="true" aria-labelledby="export-heading">
    <header><div><span className="eyebrow">Current image</span><h2 id="export-heading">Export measurements</h2><p>{image.fileName} · {cells.length} included objects · {image.cells.length - cells.length} excluded by regions</p></div><button className="icon-button" onClick={onClose} aria-label="Close export"><X size={17} /></button></header>
    <div className="export-grid">
      <button disabled={Boolean(busy) || !image.sourceLoaded || planeExportBlocked} onClick={() => void artifact("sample-bundle")}><FileArchive /><span><strong>Complete sample ZIP</strong><small>Original source, plane, overlay, tables, reports and ROIs</small></span><Download /></button>
      <button disabled={Boolean(busy)} onClick={() => save(`${stem}-report.md`, exportMarkdownReport({ title: `CellCounter · ${image.fileName}`, width: image.width, height: image.height, cells, groundTruth: image.groundTruth, provenance }), "text/markdown;charset=utf-8")}><FileText /><span><strong>Markdown report</strong><small>Summary, review and reproducibility</small></span><Download /></button>
      <button disabled={Boolean(busy)} onClick={() => save(`${stem}-ground-truth.json`, JSON.stringify({ schemaVersion: 1, coordinateSpace: "source-pixels", groundTruth: image.groundTruth, calibration: provenance.calibration, source: provenance.originalSource }, null, 2), "application/json")}><Braces /><span><strong>Ground-truth JSON</strong><small>Source-coordinate annotation marks</small></span><Download /></button>
      <button disabled={Boolean(busy)} onClick={() => save(`${stem}-ground-truth.csv`, exportGroundTruthCsv(image.groundTruth), "text/csv;charset=utf-8")}><Table2 /><span><strong>Ground-truth CSV</strong><small>Gold annotation coordinates and sizes</small></span><Download /></button>
      <button onClick={() => save(`${stem}-cells.csv`, exportCellsCsv(cells, provenance), "text/csv;charset=utf-8")}><Table2 /><span><strong>Cells CSV</strong><small>Measurements and recorded settings</small></span><Download /></button>
      <button onClick={() => save(`${stem}-provenance.json`, exportProvenance(provenance), "application/json")}><Braces /><span><strong>Analysis JSON</strong><small>Source, method, settings, and calibration</small></span><Download /></button>
      <button onClick={() => void artifact("imagej-roi")} disabled={Boolean(busy)}><FileArchive /><span><strong>ImageJ ROI ZIP</strong><small>Polygon RoiSet.zip</small></span><Download /></button>
      <button onClick={() => void artifact("geojson")} disabled={Boolean(busy)}><Map /><span><strong>GeoJSON contours</strong><small>Object outlines in image pixels</small></span><Download /></button>
      <button onClick={() => void artifact("annotated-png")} disabled={Boolean(busy) || !image.sourceLoaded || planeExportBlocked}><FileImage /><span><strong>Annotated PNG</strong><small>Full-resolution local overlay</small></span><Download /></button>
      <button onClick={() => void artifact("mask-png")} disabled={Boolean(busy)}><FileImage /><span><strong>Label mask PNG</strong><small>Corrected objects as numbered labels</small></span><Download /></button>
      <button onClick={() => void artifact("pdf")} disabled={Boolean(busy)}><FileText /><span><strong>PDF lab report</strong><small>Measurements and analysis details</small></span><Download /></button>
      <button onClick={() => void artifact("bare-npy")} disabled={Boolean(busy)}><Braces /><span><strong>Bare uint32 NPY</strong><small>Safe label map; not Cellpose GUI session</small></span><Download /></button>
      <button onClick={() => save(`${stem}-regions.json`, exportRoiData(regions), "application/json")}><Map /><span><strong>ROI JSON</strong><small>Include/exclude source polygons</small></span><Download /></button>
    </div>
    {planeExportBlocked && <p className="export-error">This historical TIFF analysis has no saved source plane. Rerun its saved setup to export an aligned overlay or sample ZIP.</p>}
    {busy && <button onClick={() => abort.current?.abort()}>Cancel export</button>}
    {busy && <p className="export-status">Preparing {artifactTypes[busy].extension} on this device…</p>}
    {status && <p className="export-status" role="status">{status}</p>}
    {error && <p className="export-error" role="alert">{error}</p>}
  </section></div>;
}
