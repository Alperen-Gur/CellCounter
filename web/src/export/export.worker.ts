/// <reference lib="webworker" />
import { exportAnnotatedPng, exportSegmentationMaskPng } from "./png";
import type { ExportWorkerRequest, ExportWorkerResponse } from "./workerProtocol";

const workerScope = self as unknown as DedicatedWorkerGlobalScope;
workerScope.onmessage = (event: MessageEvent<ExportWorkerRequest>) => {
  const request = event.data;
  try {
    const bytes = request.kind === "annotated-png"
      ? exportAnnotatedPng(request.source, request.cells, request.options)
      : exportSegmentationMaskPng(request.labels, request.width, request.height);
    const response: ExportWorkerResponse = { id: request.id, ok: true, bytes };
    workerScope.postMessage(response, [bytes.buffer]);
  } catch (error) {
    const response: ExportWorkerResponse = { id: request.id, ok: false, error: error instanceof Error ? error.message : String(error) };
    workerScope.postMessage(response);
  }
};
