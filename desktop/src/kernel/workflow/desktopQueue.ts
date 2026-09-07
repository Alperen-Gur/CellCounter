import { getPort } from "../persistence";
import { getTransport } from "../transport";
import { useAppStore } from "../store/store";
import { AnalysisQueue, type AnalysisJob } from "./AnalysisQueue";

import { loadWorkflowDocument, saveWorkflowDocument, deleteWorkflowDocument, type SavedRun } from "./workflowDocuments";

export const analysisQueue = new AnalysisQueue({
  load: () => loadWorkflowDocument<AnalysisJob[]>("jobs"),
  save: jobs => saveWorkflowDocument("jobs", jobs),
  available: model => getTransport().availability(model),
  detect: (item, params, signal) => getTransport().detect(item.path, params, progress => {
    const store = useAppStore.getState();
    if (progress.kind === "stage") store.setStageLine(progress.line);
    else if (progress.kind === "device") store.setDevice(progress.device);
    else store.setStageLine(`Downloading weights: ${progress.doneMB.toFixed(1)} / ${progress.totalMB.toFixed(1)} MB`);
  }, signal),
  commit: async (item, result, job) => {
    const port = getPort();
    await deleteWorkflowDocument(`run-${item.imageId}`);
    const runToken = crypto.randomUUID();
    const family = job.params.modelId.startsWith("sd-") ? "stardist" : "cellpose";
    const saved = await port.saveDetection(item.imageId, `${family}/${job.params.modelId}`, result.cells, result.imageStats);
    await saveWorkflowDocument(`run-${item.imageId}`, {
      version: 1, detectionId: saved.id, runToken, params: job.params, task: job.task,
      calibrationSource: job.calibrationSource, ranAt: saved.ranAt,
    });
    void useAppStore.getState().refreshLibraryStats().catch(() => {});
    window.dispatchEvent(new CustomEvent("cc:detection-updated", { detail: { imageId: item.imageId } }));
    return `${saved.id}:${runToken}`;
  },
  resultExists: async item => {
    const [result, run] = await Promise.all([getPort().getDetection(item.imageId), loadWorkflowDocument<SavedRun>(`run-${item.imageId}`)]);
    return !!result && !!run && `${result.id}:${run.runToken}` === item.detectionId;
  },
});
