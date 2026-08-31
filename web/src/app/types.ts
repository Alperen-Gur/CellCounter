import type { CalibrationSource, ImageAnalysis } from "../domain/types";

export type RouteId = "workspace" | "library" | "review" | "lab" | "compare" | "models" | "capabilities" | "settings";
export type EditTool = "inspect" | "add" | "remove" | "resize" | "merge" | "split" | "ground-truth" | "roi-include" | "roi-exclude";
export type RunState = "idle" | "preparing" | "running" | "complete" | "error";

export interface WorkspaceCell {
  id: string;
  cx: number;
  cy: number;
  diameterPx: number;
  diameterUm: number;
  areaUm2?: number;
  confidence: number;
  isManual?: boolean;
  contourPx?: Array<[number, number]>;
}

export interface GroundTruthMark { id: string; x: number; y: number; diameterPx: number; }
export interface WorkspaceRoi { id: string; kind: "include" | "exclude"; x: number; y: number; width: number; height: number; }

export interface WorkspaceImage {
  id: string;
  file: File;
  originalFile?: File;
  fileName: string;
  objectUrl: string;
  thumbnailUrl?: string;
  thumbnailBlob?: Blob;
  sourceLoaded?: boolean;
  width: number;
  height: number;
  importedAt: string;
  cells: WorkspaceCell[];
  condition: string;
  pxPerUm: number;
  sourceSha256?: string;
  sourceByteLength?: number;
  sourceMediaType?: string;
  calibrationSource?: CalibrationSource;
  calibrationConfidence?: "high" | "medium" | "low";
  planeCount?: number;
  samplesPerPixel?: number;
  bitsPerSample?: number;
  groundTruth: GroundTruthMark[];
  rois: WorkspaceRoi[];
  note: string;
  reviewConfidence: "high" | "medium" | "low";
  modelId?: string;
  analysisId?: string;
  provenance?: Record<string, unknown>;
  analysis?: ImageAnalysis;
}

export interface Notice {
  tone: "info" | "success" | "warning" | "error";
  title: string;
  detail: string;
}
