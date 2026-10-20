import { invoke } from "@tauri-apps/api/core";
import type { OperationRequest, OperationResponse } from "../../../../shared/workbench/protocol";

/** All desktop callers use the GUI/CLI/MCP operation envelope and revision guard. */
export class WorkbenchOperationError extends Error {
  readonly operation: string;
  readonly code: string;
  readonly details?: Record<string, unknown>;
  constructor(operation: string, error: { code: string; message: string; details?: Record<string, unknown> }) {
    super(`${error.message} (${error.code})`);
    this.name = "WorkbenchOperationError";
    this.operation = operation;
    this.code = error.code;
    this.details = error.details;
  }
}

export async function requestResponse<T>(
  path: string, operation: string, args: Record<string, unknown> = {}, revision?: number,
): Promise<Extract<OperationResponse<T>, { ok: true }>> {
  const input: OperationRequest = {
    schemaVersion: 1, operation, requestId: crypto.randomUUID(),
    actor: { kind: "human", name: "Windows workbench" }, arguments: args,
    ...(path ? { projectPath: path } : {}),
    ...(revision === undefined ? {} : { expectedRevision: revision }),
  };
  const response = await invoke<OperationResponse<T>>("workbench_request", { request: input });
  if (response.schemaVersion !== 1 || response.requestId !== input.requestId || response.operation !== operation)
    throw new Error("The operation response does not match its request. Refresh the project before continuing.");
  if (!response.ok) throw new WorkbenchOperationError(operation, response.error);
  return response;
}

export async function request<T>(path: string, operation: string, args: Record<string, unknown> = {}, revision?: number): Promise<T> {
  return (await requestResponse<T>(path, operation, args, revision)).result;
}

/** OS path discovery only; archive capture/import use canonical operations. */
export function legacyLibraryLocations(): Promise<{ libraryRoot: string; databasePath: string; databaseExists: boolean; workspaceDocumentKey: string }> {
  return invoke("workbench_legacy_locations");
}
