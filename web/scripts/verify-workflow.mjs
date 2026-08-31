import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";

const requiredFiles = [
  "src/app/imageFiles.ts",
  "src/components/ImageStage.tsx",
  "src/components/Inspector.tsx",
  "src/views/LibraryView.tsx",
  "src/views/CompareView.tsx",
  "src/views/AnalysisLabView.tsx",
  "src/components/ExportDialog.tsx",
  "src/models/WebGpuInference.ts",
  "src/workers/InferenceWorkerClient.ts",
  "src/storage/BrowserRepository.ts",
  "src/domain/export.ts",
  "tests/workflow.test.ts",
];
for (const path of requiredFiles) if (!existsSync(new URL(`../${path}`, import.meta.url))) throw new Error(`Workflow surface missing: ${path}`);

const app = `${await readFile(new URL("../src/App.tsx", import.meta.url), "utf8")}\n${await readFile(new URL("../src/views/CompareView.tsx", import.meta.url), "utf8")}\n${await readFile(new URL("../src/views/AnalysisLabView.tsx", import.meta.url), "utf8")}\n${await readFile(new URL("../src/components/ExportDialog.tsx", import.meta.url), "utf8")}`;
for (const token of ["decodeImageFiles", "InferenceWorkerClient", "BrowserRepository", "applyCorrection", "compareBatches", "runAssay", "buildWorkspaceArtifact", "AbortController"]) {
  if (!app.includes(token)) throw new Error(`Application is not integrated with ${token}`);
}

const test = spawnSync(process.execPath, ["./node_modules/vitest/vitest.mjs", "run", "tests/workflow.test.ts"], {
  cwd: new URL("../", import.meta.url),
  encoding: "utf8",
  env: { ...process.env, FORCE_COLOR: "0" },
});
if (test.status !== 0) throw new Error(`Workflow test failed:\n${test.stdout}\n${test.stderr}`);
if (!/passed/.test(`${test.stdout}\n${test.stderr}`)) throw new Error("Workflow test did not report passing assertions");

console.log("Web workflow verification passed (import, segmentation adapter, measurement, correction, comparison, persistence, cancellation, provenance, export)");
