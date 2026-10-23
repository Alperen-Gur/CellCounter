import type { WorkbenchTaskId } from "./navigation";

export interface SessionSelection {
  task?: WorkbenchTaskId;
  imageId?: string; workspaceId?: string; target?: "plane" | "volume"; channel?: number; timeIndex?: number;
  plane?: "xy" | "xz" | "yz"; index?: number;
}
export interface SessionNavigation {
  id: string; status: "pending" | "deferred" | "applied" | "refused"; selection: SessionSelection;
  observedProjectRevision: number; requestedAt: string; actor: { kind: string; name: string }; reason?: string;
}
export interface WorkbenchSession {
  id: string; name: string; clientKind: string; sessionRevision: number; observedProjectRevision: number;
  projectRevision?: number; selection: SessionSelection; selectionCurrent: boolean; selectionAvailable: boolean | null;
  closed: boolean; updatedAt: string; actor: { kind: string; name: string }; navigation?: SessionNavigation;
}
export interface ProjectChanges {
  projectRevision: number; nextRevision: number; hasMore: boolean; resetRequired: boolean;
  events: { revision: number; operation: string; requestId: string; actor: { kind: string; name: string }; at: string;
    imageEffects: { imageId: string; sourceChanged: boolean; labelsChanged: boolean; calibrationChanged: boolean; metadataChanged: boolean }[];
    domains: string[] }[];
}
