import { readFile } from "node:fs/promises";

const required = {
  "src/domain/types.ts": ["BrowserImageSource", "SourcePointPx", "AnalysisProvenance", "DetectionResultDTO"],
  "src/domain/analysis.ts": ["measureCell", "applyCorrection", "compareBatches"],
  "src/domain/export.ts": ["deterministicJson", "exportCellsCsv"],
  "src/workers/InferenceWorkerClient.ts": ["AbortSignal", "CancelledInferenceError", "postMessage"],
  "src/workers/inference.worker.ts": ["WebGpuInference", "BrowserRepository"],
  "src/storage/BrowserRepository.ts": ["indexedDB", "getDirectory", "modelArtifactCache"],
};

for (const [path, tokens] of Object.entries(required)) {
  const contents = await readFile(new URL(`../${path}`, import.meta.url), "utf8");
  for (const token of tokens) if (!contents.includes(token)) throw new Error(`${path}: missing ${token}`);
}
console.log("Web core verification passed (browser DTOs, analysis, worker cancellation, IndexedDB/OPFS, model cache)");
