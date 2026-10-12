/// <reference lib="webworker" />
import { buildReviewedDataset, type ReviewedTrainingSample } from "../export/bundles";
self.onmessage = async (event: MessageEvent<{ id: string; samples: ReviewedTrainingSample[] }>) => {
  try {
    const bytes = await buildReviewedDataset(event.data.samples);
    self.postMessage({ id: event.data.id, ok: true, bytes }, [bytes.buffer]);
  } catch (error) { self.postMessage({ id: event.data.id, ok: false, error: error instanceof Error ? error.message : String(error) }); }
};
export {};
