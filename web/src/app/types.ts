import type { CalibrationSource, ImageAnalysis } from "../domain/types";

export type RouteId = "workspace" | "microscopy" | "processing" | "help" | "library" | "review" | "lab" | "compare" | "models" | "capabilities" | "settings";
export type EditTool = "inspect" | "add" | "remove" | "resize" | "merge" | "split" | "ground-truth" | "roi-include" | "roi-exclude" | "freehand" | "prompt-point" | "prompt-box";
export type RunState = "idle" | "preparing" | "running" | "complete" | "error";

export interface WorkspaceCell {
  id: string;
  cx: number;
  cy: number;
  diameterPx: number;
  diameterUm: number;
  areaUm2?: number;
  areaPx2?: number;
  perimeterUm?: number;
  perimeterPx?: number;
  circularity?: number;
  aspectRatio?: number;
  solidity?: number;
  eccentricity?: number;
  edgeTouching?: boolean;
  sizeClass?: string;
  confidence: number;
  isManual?: boolean;
  reviewed?: boolean;
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
  /** False while this session owns the only copy; such rasters cannot be evicted. */
  sourcePersisted?: boolean;
  width: number;
  height: number;
  importedAt: string;
  cells: WorkspaceCell[];
  condition: string;
  pxPerUm: number;
  editRevision?: number;
  sourceSha256?: string;
  sourceByteLength?: number;
  sourceMediaType?: string;
  calibrationSource?: CalibrationSource;
  calibrationConfidence?: "high" | "medium" | "low";
  sourceDimensions?: { t: number; z: number; c: number };
  channelNames?: string[];
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
  detail?: string;
}
