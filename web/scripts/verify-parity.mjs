import { access, readFile } from "node:fs/promises";
import { resolve } from "node:path";

const expectedIds = [
  "input-standard", "input-folder", "input-vendor", "input-dedup", "input-calibration-meta", "input-calibration-manual", "input-calibration-persist",
  "model-cpsam", "model-cyto3", "model-stardist", "detection-batch", "detection-cancel", "detection-preprocess", "detection-watershed", "detection-provenance",
  "analysis-measure", "analysis-bins", "analysis-qc", "analysis-colony", "analysis-intensity", "analysis-area", "analysis-puncta", "analysis-spatial", "analysis-tracking", "analysis-neurite", "analysis-line-profile",
  "edit-overlay", "edit-cells", "edit-ground-truth", "edit-roi", "edit-notes",
  "workflow-library", "workflow-batches", "workflow-review", "workflow-compare", "workflow-protocol", "workflow-finetune",
  "export-cells", "export-roi", "export-segnpy", "export-provenance", "export-pdf", "export-overlay", "export-geojson",
  "system-storage", "system-accessibility", "system-support",
];
const allowedAreas = new Set(["Input", "Detection", "Analysis", "Editing", "Workflow", "Export", "System"]);
const allowedStates = new Set(["available", "buildRequired", "unsupported"]);
const catalogPath = resolve("src/parity/capabilities.json");
const catalog = JSON.parse(await readFile(catalogPath, "utf8"));
const failures = [];

if (catalog.length !== 47) failures.push(`expected 47 capabilities, received ${catalog.length}`);
const ids = catalog.map((capability) => capability.id);
if (new Set(ids).size !== ids.length) failures.push("capability IDs are not unique");
for (const id of expectedIds) if (!ids.includes(id)) failures.push(`missing frozen capability ${id}`);
for (const id of ids) if (!expectedIds.includes(id)) failures.push(`unexpected capability ${id}`);

for (const capability of catalog) {
  if (!allowedAreas.has(capability.area)) failures.push(`${capability.id}: invalid area ${capability.area}`);
  if (!allowedStates.has(capability.state)) failures.push(`${capability.id}: invalid state ${capability.state}`);
  if (typeof capability.note !== "string" || capability.note.length < 48) failures.push(`${capability.id}: note is not actionable`);
  if (!capability.webSurface) failures.push(`${capability.id}: missing web surface`);
  if (!Array.isArray(capability.sourceEvidence) || !capability.sourceEvidence.length) failures.push(`${capability.id}: missing source evidence`);
  for (const sourcePath of capability.sourceEvidence ?? []) {
    if (!sourcePath.startsWith("CellCounting/")) failures.push(`${capability.id}: source is outside macOS tree: ${sourcePath}`);
    try { await access(resolve("..", sourcePath)); }
    catch { failures.push(`${capability.id}: source evidence does not exist: ${sourcePath}`); }
  }
  if (capability.state !== "available" && !/(require|need|convert|export|package|build|disabled|absent|missing|unsafe|validat)/i.test(capability.note)) {
    failures.push(`${capability.id}: unavailable note has no actionable path`);
  }
}

const rendered = await readFile(resolve("src/views/CapabilitiesView.tsx"), "utf8");
if (!rendered.includes("WEB_PARITY_CAPABILITIES") || !rendered.includes("sourceEvidence")) failures.push("capability inventory is not rendered with evidence");
const privacy = await readFile(resolve("index.html"), "utf8");
if (!privacy.includes("connect-src 'self'")) failures.push("same-origin privacy boundary is absent");

const uiContracts = [
  ["src/App.tsx", ["onRoi={addRoi}", "onRedo={redo}", "ReviewView", "AnalysisLabView", "ExportDialog"]],
  ["src/components/ImageStage.tsx", ["roi-include", "onCellPointer", "requestAnimationFrame", "Zoom in", "Fit image"]],
  ["src/components/Inspector.tsx", ["truthMetrics", "Review confidence", "Image notes", "Clear truth", "Clear regions"]],
  ["src/views/ReviewView.tsx", ["Review queue", "onAccept", "onReject", "onResize"]],
  ["src/views/AnalysisLabView.tsx", ["runAssay", "Tracking sequence order", "Protocols", "Open .ccproto.json"]],
  ["src/components/ExportDialog.tsx", ["buildWorkspaceArtifact", "ImageJ ROI ZIP", "GeoJSON contours", "Annotated PNG", "Bare uint32 NPY"]],
  ["src/import/tiff.ts", ["decodeTiff", "parseOmeCalibration", "parseImageJCalibration"]],
];
for (const [path, tokens] of uiContracts) {
  const source = await readFile(resolve(path), "utf8");
  for (const token of tokens) if (!source.includes(token)) failures.push(`${path}: browser surface evidence missing: ${token}`);
}

const states = new Map(catalog.map((capability) => [capability.id, capability.state]));
for (const id of ["edit-cells", "edit-ground-truth", "edit-roi", "edit-notes", "workflow-review", "analysis-tracking", "analysis-neurite", "workflow-protocol", "export-roi", "export-pdf", "export-overlay", "export-geojson"]) {
  if (states.get(id) !== "available") failures.push(`${id}: implemented browser surface must remain available`);
}
for (const id of ["model-cpsam", "model-cyto3", "model-stardist", "export-segnpy"]) {
  if (states.get(id) !== "buildRequired") failures.push(`${id}: artifact/codec-gated capability must remain buildRequired`);
}
for (const id of ["input-vendor", "workflow-finetune"]) {
  if (states.get(id) !== "unsupported") failures.push(`${id}: impossible browser capability must remain visibly unsupported`);
}

if (failures.length) {
  console.error("Web parity verification failed:\n" + failures.map((failure) => `- ${failure}`).join("\n"));
  process.exit(1);
}

const counts = catalog.reduce((result, capability) => ({ ...result, [capability.state]: (result[capability.state] ?? 0) + 1 }), {});
console.log(`Web parity verification passed: 47/47 inventoried (${counts.available ?? 0} available, ${counts.buildRequired ?? 0} build required, ${counts.unsupported ?? 0} unsupported); all source evidence resolves.`);
