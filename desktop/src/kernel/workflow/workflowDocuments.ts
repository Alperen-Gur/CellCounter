import { timeLocalOperation } from "../../../../shared/diagnostics/performance";
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
  runtimeIdentity?: Record<string, unknown>;
}
export function loadWorkflowDocument<T>(key: string): Promise<T | null> {
  return timeLocalOperation(key === "jobs" ? "queue.load" : "storage.read", () => invoke("load_workflow_document", { key }));
}
export function saveWorkflowDocument(key: string, document: unknown): Promise<void> {
  return timeLocalOperation(key === "jobs" ? "queue.save" : "storage.write", () => invoke("save_workflow_document", { key, document }));
}
export function deleteWorkflowDocument(key: string): Promise<void> {
  return invoke("delete_workflow_document", { key });
}
