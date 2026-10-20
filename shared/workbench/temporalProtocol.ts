import type { LineageGraph } from "./lineageProtocol";
export interface TemporalOffset { timeIndex: number; x: number; y: number; z: number }
export interface TemporalTrackingPreview {
  previewFingerprint: string; imageId: string; channel: number; timeIndices: number[];
  counts: { observations: number; continuations: number; gaps: number; inferredDivisions: number; ambiguousDivisions: number };
  drift: { mode: string; offsets: TemporalOffset[]; convention: string; quality: unknown[]; notes: string[] };
  ambiguities: unknown[]; graph: Omit<LineageGraph, "status"> & { status: "preview" }; replacesGraph: boolean; notes: string[];
}
export interface PropagationTarget {
  timeIndex: number; labelId?: number; shiftVox?: { x: number; y: number; z: number };
  appliedShiftVox?: { x: number; y: number; z: number }; identity?: "explicit" | "lineage";
  status: "ready" | "blocked" | "skipped"; sourceVoxels?: number; placedVoxels?: number; clippedVoxels?: number;
  collisionLabelIds?: number[]; replacedLabelIds?: number[]; reasons: { code: string; message: string }[];
  warnings: string[]; overlayDataUrl?: string; previewIndex?: number;
}
export interface PropagationPreview {
  previewFingerprint: string; imageId: string; channel: number; source: { timeIndex: number; labelId: number };
  motion: string; targets: PropagationTarget[]; readyCount: number; blockedCount: number; notes: string[];
}
export interface TemporalPropagation {
  id: string; imageId: string; channel: number; status: "applied" | "undone"; source: { timeIndex: number; labelId: number };
  motion: string; reason: string; createdAt: string; createdRevision: number; targetCount: number; appliedCount: number;
  skippedCount: number; undoAvailable: boolean; outputsCurrent: boolean; targets?: PropagationTarget[]; notes: string[];
}
