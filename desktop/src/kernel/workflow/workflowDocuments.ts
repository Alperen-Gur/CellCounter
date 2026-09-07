import { invoke } from "@tauri-apps/api/core";
import type { DetectionParams } from "../types";
import type { AnalysisTask } from "./AnalysisQueue";

export interface SavedRun {
  version: 1;
  detectionId: string;
  runToken: string;
  params: DetectionParams;
  task: AnalysisTask;
  calibrationSource: string;
  ranAt: string;
}
export function loadWorkflowDocument<T>(key: string): Promise<T | null> {
  return invoke("load_workflow_document", { key });
}
export function saveWorkflowDocument(key: string, document: unknown): Promise<void> {
  return invoke("save_workflow_document", { key, document });
}
export function deleteWorkflowDocument(key: string): Promise<void> {
  return invoke("delete_workflow_document", { key });
}
