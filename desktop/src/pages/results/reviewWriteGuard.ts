import { useSyncExternalStore } from "react";
import { analysisQueue } from "../../kernel/workflow/desktopQueue";
import { blocksImageWrites } from "./reviewMath";

export function isReviewImageBusy(imageID?: string): boolean {
  return blocksImageWrites(imageID, analysisQueue.isActive(), analysisQueue.getSnapshot());
}
export function assertReviewImageWritable(imageID: string): void {
  if (isReviewImageBusy(imageID)) throw new Error("This image is being processed. View a completed image or pause processing before changing its result.");
}
export function useReviewImageBusy(imageID?: string): boolean {
  useSyncExternalStore(analysisQueue.subscribe, analysisQueue.getSnapshot, analysisQueue.getSnapshot);
  return isReviewImageBusy(imageID);
}
