import type { Calibration, MicroscopyWorkspace, WorkspaceLayer } from "../microscopy/types";
export interface WorkspaceDescriptor {
  id: string; name: string; version: number; layerCount: number; sourceBindingsCurrent: boolean | null; missingSourceCount: number; updatedAt: string; documentHash?: string; undoAvailable?: boolean;
}
export interface WorkspaceSelection { target: "plane" | "volume"; channel: number; timeIndex?: number; zProjection?: "max" | "mean" | "middle"; zIndex?: number }
export interface WorkspaceBinding { layerId: string; imageId?: string; role: string; selection?: WorkspaceSelection; sourceHash?: string; sourceKind?: "zarr"; sourceId?: string; arrayPath?: string; region?: { x: number; y: number; width: number; height: number }; inputFingerprint?: string; positionAxes?: Record<string, string> }
export interface WorkspaceDetail {
  workspace: WorkspaceDescriptor; document: MicroscopyWorkspace; layerBindings: WorkspaceBinding[]; missingSources: unknown[];
  generatedLayers?: { layerId: string; width: number; height: number; hasSupport: boolean; generated: boolean; materializable: boolean; calibration: Calibration | null }[];
}
export interface WorkspaceImportPreview { previewFingerprint: string; summary: Record<string, unknown>; missingSources: unknown[]; notes: string[] }
export interface WorkspacePreview { dataUrl: string; width: number; height: number; workspaceId: string; version: number; sourceBindings: WorkspaceBinding[] }
export type WorkspaceMutation = "workspace.create" | "workspace.layer.update" | "workspace.source.bind" | "workspace.layer.add" |
  "workspace.replay" | "semantic.render" | "pointlineage.build" | "animation.render" | "workspace.operation.run" | "workspace.document.update" | "workspace.document.set" | "workspace.undo" | "workspace.materialize.run" | "workspace.zarr.add" | "workspace.zarr.bind";
export interface WorkspaceSamples {
  workspaceId: string; version: number; layerId: string; width: number; height: number; dtype: "float32-le"; order: "yx";
  dataBase64: string; supportBase64: string | null; calibration: Calibration | null; position: Record<string, number>;
  sourceBinding: WorkspaceBinding; sourceCurrent: true; untransformed: true;
}
export interface WorkspaceOutput { id: string; workspaceId: string; workspaceVersion: number; operation: string; outputsCurrent: boolean | null; files: { id: string; kind: string; bytes: number; hash: string }[] }
export interface WorkspaceActions {
  commit: (operation: WorkspaceMutation, args: Record<string, unknown>, expectedRevision: number) => Promise<{ value: WorkspaceDetail; revision: number } | undefined>;
  export: (workspaceId: string, expectedRevision: number, render?: { kind: "semantic" | "animation"; id: string }) => Promise<void>;
  importGeometry: (expectedRevision: number) => Promise<Partial<WorkspaceLayer> | undefined>;
  mutate: <T>(operation: WorkspaceMutation, args: Record<string, unknown>, expectedRevision: number, accepted?: (value: T) => void) => Promise<void>;
  exportDraft: (workspace: MicroscopyWorkspace, expectedRevision: number) => Promise<void>;
  openExisting: (selected: (path: string) => void) => Promise<void>;
  exportOutput: (output: WorkspaceOutput, artifactId: string, expectedRevision: number) => Promise<void>;
  chooseImport: (selected: (path: string) => void) => Promise<void>;
  import: (args: { path: string; format: "portable" | "native"; previewFingerprint: string; name?: string }, expectedRevision: number, accepted: (workspace: WorkspaceDescriptor) => void) => Promise<void>;
  replaceDocument: (workspaceId: string, expectedRevision: number) => Promise<void>;
}
export type WorkspaceLayerDraft = Pick<WorkspaceLayer, "name" | "visible" | "opacity" | "blendMode" | "transform" | "display">;

export interface WorkspaceMaterializationPreview {
  workspaceId: string; workspaceVersion: number; layerId: string; name: string; width: number; height: number; dtype: string;
  calibration: Calibration | null; validSamples: number; totalSamples: number; pixelToWorkspace: Record<string, number>;
  coordinateIdentity: string; parents: WorkspaceBinding[]; notes: string[]; previewFingerprint: string;
}
