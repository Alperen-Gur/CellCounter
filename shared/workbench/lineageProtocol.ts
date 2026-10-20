export interface LineageNode {
  id: string; timeIndex: number; labelId: number; cx: number; cy: number; cz: number;
  voxelCount: number; volumeUm3: number | null; meanIntensity: number;
}
export interface LineageTrack {
  id: string; lineageId: string; parentTrackId: string | null; daughterTrackIds: string[];
  observations: LineageNode[];
  summary: { observationCount: number; startTimeIndex: number; endTimeIndex: number;
    elapsedFrames: number; elapsedSeconds: number | null; pathLengthVoxels: number;
    pathLengthUm: number | null; meanSpeedUmPerSecond: number | null; meanVolumeUm3: number | null };
}
export interface LineageGraph {
  imageId: string; channel: number; status: "none" | "current" | "stale";
  graphRevision?: number; snapshotId?: string; undoAvailable: boolean;
  nodes: LineageNode[];
  edges: { sourceNodeId: string; targetNodeId: string; kind: "continuation" | "division"; divisionId?: string }[];
  divisions: { id: string; parent: { timeIndex: number; labelId: number };
    daughters: { timeIndex: number; labelId: number }[]; reason: string; at: string }[];
  tracks: LineageTrack[]; lineages: { id: string; rootTrackId: string; trackIds: string[];
    divisionCount: number; terminalTrackIds: string[]; observationCount: number }[];
  history: { id: string; revision: number; operation: string; reason: string; at: string }[];
  summary: Record<string, unknown>;
}
export type LineageExportFormatId = "graph-json" | "observations-csv" | "tracks-csv" | "edges-csv";
export interface LineageExportFormat {
  id: LineageExportFormatId; name: string; extension: string; mediaType: string; description: string;
}
export interface LineageExportArguments { imageId: string; channel: number; format: LineageExportFormatId }
export interface LineageExportResult {
  exportId: string; destination: string; sha256: string; format: LineageExportFormatId;
  mediaType: string; bytes: number; imageId: string; channel: number; graphRevision: number;
  provenance: Record<string, unknown>; provenanceSha256: string;
}
