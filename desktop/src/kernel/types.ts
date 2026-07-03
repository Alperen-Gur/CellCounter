/**
 * kernel/types.ts — Shared TypeScript domain types (ARCHITECTURE.md §3.2)
 *
 * Ported from `CellCounting/CellCounting/Domain/*.swift` +
 * `Detection/SidecarSchema.swift`. These DTOs are the vocabulary of the whole
 * UI, both ports (InferenceTransport, PersistencePort), and the SQLite layer.
 *
 * FROZEN CONTRACT (§6.2): every page, port, and kernel module imports from
 * here. A field rename ripples everywhere — do not edit without re-freezing.
 *
 * Coordinate space: ALL cell / annotation geometry (cx, cy, contourPx, …) is
 * in SOURCE-PIXEL space. The Viewport (§3.4) supplies the view transform;
 * nothing here is pre-scaled to the canvas.
 *
 * This module is pure type declarations only — no runtime code, no imports.
 * `CellDTO`, `DetectionResultDTO`, `DetectionParams`, `DetectionProgress`, and
 * `DetectionError` are the canonical domain definitions; `kernel/transport/
 * InferenceTransport.ts` (§3.1) re-exports them so the transport seam and the
 * persistence/domain layer never diverge.
 */

// ---------------------------------------------------------------------------
// Detection input params (mirror Detection/SidecarSchema.swift, §3.1)
// ---------------------------------------------------------------------------

export interface DetectionParams {
  modelId: string; // v1: always "cp-cyto3"
  pxPerUm: number;
  confidenceThreshold: number; // analysis filter; cells below are hidden, never deleted
  channels: [number, number]; // [cyto, nuclei]; 0=gray,1=r,2=g,3=b. default [0,0]
  backgroundSubtract: boolean;
  rollingBallRadius: number; // px, default 50
  watershedSplit: boolean;
  watershedMinDistanceUm: number; // default 8
  smallThresholdUm: number; // default 20
  largeThresholdUm: number; // default 30
  useGpu: boolean; // false ⇒ --no-gpu
}

// ---------------------------------------------------------------------------
// Cell (mirror Domain/Cell.swift + SidecarSchema.swift, §3.1)
// ---------------------------------------------------------------------------

export interface CellDTO {
  id: string; // uuid
  cx: number;
  cy: number; // SOURCE-PIXEL space
  diameterUm: number;
  diameterPx: number;
  confidence: number; // [0,1]
  // optional per-cell measurements (absent on manual markers / legacy)
  areaUm2?: number;
  perimeterUm?: number;
  circularity?: number;
  eccentricity?: number;
  meanIntensity?: number;
  integratedDensity?: number;
  centroidUmX?: number;
  centroidUmY?: number;
  aspectRatio?: number;
  solidity?: number;
  edgeTouching?: boolean;
  likelyClump?: boolean;
  likelyDebris?: boolean;
  sizeClass?: "small" | "intermediate" | "large" | "";
  isManual?: boolean;
  contourPx?: Array<[number, number]>; // polygon in source-px; undefined ⇒ render bbox/circle
}

export interface DetectionResultDTO {
  imageWidth: number;
  imageHeight: number;
  cells: CellDTO[];
  imageStats?: Record<string, number>; // focus_score, illumination_residual, n_colonies, confluency_pct, …
}

// ---------------------------------------------------------------------------
// Detection progress + error unions (§3.1) — the events every transport emits
// ---------------------------------------------------------------------------

export type DetectionProgress =
  | { kind: "stage"; runId: string; line: string } // human-readable stderr line
  | { kind: "device"; runId: string; device: string } // "MPS" | "CPU" | "CUDA:0"
  | { kind: "weights"; runId: string; doneMB: number; totalMB: number }; // future SAM download

export type DetectionError =
  | { kind: "modelNotInstalled"; modelId: string }
  | { kind: "sidecarFailed"; exitCode: number; stderr: string }
  | { kind: "imageDecodeFailed" }
  | { kind: "cancelled" };

// ---------------------------------------------------------------------------
// Image (mirror Domain/*.swift + Persistence/Records.swift)
// ---------------------------------------------------------------------------

export interface ImageDTO {
  id: string;
  fileName: string;
  widthPx: number;
  heightPx: number;
  importedAt: string; // ISO8601
  fileHash?: string; // sha256 hex
  confidenceOverride?: number; // per-image cutoff; overrides global
  notes?: string;
  storedPath: string; // resolved by backend (Images/<id>.<ext>)
  thumbPath: string; // Thumbnails/<id>.jpg
  /**
   * Number of cells in this image's saved detection (0 when none ran). Denormalized
   * onto the image row by the Rust `all_images` query so count-only reads
   * (Library / Batch / Review badges) don't need a per-image `getDetection`
   * round-trip. Per-cell data (diameters, corrections) still comes from
   * `getDetection` / `getDetections`.
   */
  cellCount: number;
}

// ---------------------------------------------------------------------------
// Detection record (persisted; mirror Persistence/Records.swift)
// ---------------------------------------------------------------------------

export interface DetectionDTO {
  id: string;
  imageId: string;
  detectorId: string; // e.g. "cellpose/cp-cyto3"
  ranAt: string;
  cells: CellDTO[];
  imageStats?: Record<string, number>;
}

// ---------------------------------------------------------------------------
// Calibration (mirror Services/EXIFCalibration.swift, §3.6)
// ---------------------------------------------------------------------------

export interface CalibrationDTO {
  pxPerUm: number;
  source:
    | "omeXML"
    | "tiffBaseline"
    | "olympus"
    | "zeiss"
    | "imagej"
    | "preset"
    | "manual"
    | "default";
  confidence?: "high" | "medium" | "low";
}

// ---------------------------------------------------------------------------
// Size binning (mirror Domain/SizeBin.swift, §3.6)
// ---------------------------------------------------------------------------

export interface SizeBin {
  min: number;
  max: number;
  label: string;
} // max=Infinity for open top bin

// ---------------------------------------------------------------------------
// Comparison (mirror Services/Statistics.swift + CompareView, §3.7)
// ---------------------------------------------------------------------------

export interface CompareGroup {
  condition: string;
  cells: CellDTO[]; // pooled across all batches with this condition
  n: number;
  meanUm: number;
  sdUm: number;
  binCounts: number[]; // aligned to the active SizeBin[]
}

export interface CompareResult {
  // populated only for exactly 2 groups
  u: number;
  z: number;
  pValue: number;
  n1: number;
  n2: number;
  median1: number;
  median2: number;
  medianDifference: number;
  rankBiserial: number; // effect size
  significanceLabel: string; // "p < 0.001" | "p = 0.03" | "p = 0.42 (n.s.)"
  effectSizeLabel: "negligible" | "small" | "medium" | "large";
}

// ---------------------------------------------------------------------------
// Ground truth + F1 (mirror Detection/AnnotationMatcher.swift, §3.7)
// ---------------------------------------------------------------------------

export interface GroundTruthDTO {
  id: string;
  imageId: string;
  cx: number;
  cy: number;
  diameterUm?: number;
  note?: string;
  createdAt: string;
}

export interface F1Score {
  tp: number;
  fp: number;
  fn: number;
  precision: number | null;
  recall: number | null;
  f1: number | null;
  matchRadiusFactor: number;
}

// ---------------------------------------------------------------------------
// Batch (mirror Persistence/Records.swift)
// ---------------------------------------------------------------------------

export interface BatchDTO {
  id: string;
  displayName: string;
  createdAt: string;
  modelId: string;
  pxPerUm: number;
  thresholds: number[];
  condition?: string;
  pxPerUmSource?: string;
  imageIds: string[];
}

// ---------------------------------------------------------------------------
// Editor / overlay modes (mirror Views/Results/EditableOverlay.swift, §3.5)
// ---------------------------------------------------------------------------

export type EditorMode =
  | "view"
  | "add"
  | "remove"
  | "merge"
  | "split"
  | "manualCount"
  | "annotate";

export type OverlayMode = "outline" | "bbox";
