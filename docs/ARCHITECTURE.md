# CellCounter — Cross-Platform Port Architecture

**Status:** Design (v1). DESIGN ONLY — no application code exists yet beyond the default Tauri scaffold at `desktop/`.
**Stack:** Tauri v2 (Rust shell) · React 19 + TypeScript · Vite 7 · Python sidecar (Cellpose) bootstrapped with `uv` · SQLite persistence in the Rust backend.
**First target:** Windows. **Second target (design for, don't build):** WebGPU browser build reusing the same React UI via a swappable inference transport.

This document is the source of truth for the port. It is grounded in the existing native macOS app at `CellCounting/` (SwiftUI + SwiftData + Python sidecar). Every interface below mirrors real behavior in that app; file references point at the Swift originals so implementers can verify.

---

## 1. System Overview

The app is a three-tier desktop application:

- **React UI (`desktop/src/`)** — all screens, canvas rendering, the mask-editing engine, statistics, calibration math, and state. Written to be **backend-agnostic**: it talks to inference and persistence only through narrow TypeScript interfaces.
- **Rust backend (`desktop/src-tauri/`)** — owns the SQLite store, the filesystem layout under the OS app-data dir, image import/decoding + SHA-256 dedup, `uv`-based Python environment bootstrap, and the **Python sidecar process lifecycle** (spawn / stream progress / cancel). Exposed to the UI as Tauri `#[command]`s + events.
- **Python sidecar (`desktop/python/`)** — the existing Cellpose scripts reused as-is: `cellpose_detect.py`, `_cellpose_common.py`, `_preprocessing.py`, `_watershed.py`, `_colony.py`, `_export_imagej_roi.py`. Invoked per-image; emits a single JSON payload on stdout and progress lines on stderr.

### ASCII diagram — desktop (Tauri) topology

```
┌──────────────────────────────────────────────────────────────────────────┐
│  React UI  (desktop/src/)                                                  │
│                                                                            │
│  Pages ── Viewport(canvas) ── MaskEditEngine ── Store(zustand)             │
│    │            │                   │               │                      │
│    │            │                   │               │                      │
│    ▼            ▼                   ▼               ▼                       │
│  ┌───────────────────────┐   ┌──────────────────────────────┐             │
│  │ InferenceTransport (TS)│   │ PersistencePort (TS)         │             │
│  │  detect() / cancel()   │   │  batches/images/detections…  │             │
│  └───────────┬───────────┘   └──────────────┬───────────────┘             │
└──────────────┼──────────────────────────────┼─────────────────────────────┘
               │  @tauri-apps/api invoke()     │  invoke()
               │  + event listen()             │
┌──────────────▼──────────────────────────────▼─────────────────────────────┐
│  Rust backend  (desktop/src-tauri/)                                        │
│                                                                            │
│  commands::detection   commands::db     commands::images   commands::env   │
│        │                    │                 │                 │          │
│  SidecarManager        rusqlite pool    ImageImporter     UvBootstrap      │
│   spawn/stream/kill    (store.sqlite)   decode+sha256     `uv venv`/`sync` │
│        │                                                                   │
└────────┼───────────────────────────────────────────────────────────────────┘
         │  stdin args + stdout(JSON) + stderr(progress)   Command / kill
┌────────▼───────────────────────────────────────────────────────────────────┐
│  Python sidecar  (desktop/python/, run from uv venv)                       │
│    cellpose_detect.py → _cellpose_common.py → cellpose (cyto3)             │
│    _preprocessing.py · _watershed.py · _colony.py · _export_imagej_roi.py  │
└────────────────────────────────────────────────────────────────────────────┘
```

### The later WebGPU swap

The **only** thing that changes for the browser build is the concrete implementation behind two ports. The React UI, Store, Viewport, MaskEditEngine, Statistics, Calibration, and every Page are reused unchanged.

```
Desktop build:                         Browser / WebGPU build:
  InferenceTransport                     InferenceTransport
    → TauriSidecarTransport                → OnnxWebTransport
       invoke("run_detection")               onnxruntime-web (WebGPU EP)
       Rust → Python → Cellpose              cellpose(-SAM) ONNX in-browser
  PersistencePort                        PersistencePort
    → TauriSqlitePort (rusqlite)           → IndexedDbPort / wa-sqlite (OPFS)
```

Because both ports return the **same TypeScript domain types** (`DetectionResultDTO`, `CellDTO`, …) and emit the **same progress events**, no page or component branches on "am I in the browser". This is the key seam and the reason the interfaces below are frozen before feature work starts.

---

## 2. Directory Layout

The Tauri scaffold already exists at `desktop/` (default `create-tauri-app` React-TS output: `desktop/src/` with `App.tsx`/`main.tsx`, `desktop/src-tauri/` with `Cargo.toml`, `lib.rs`, `main.rs`, `tauri.conf.json`). We build **into** it — the layout below is what it grows into. New top-level dirs relative to `desktop/` are marked `NEW`.

```
desktop/
├── index.html
├── package.json                 (add: zustand, react-router, comlink; scripts unchanged)
├── vite.config.ts
├── tsconfig.json
│
├── python/                      NEW — sidecar scripts (copied/symlinked from ../CellCounting/python)
│   ├── cellpose_detect.py
│   ├── _cellpose_common.py
│   ├── _preprocessing.py
│   ├── _watershed.py
│   ├── _colony.py
│   ├── _export_imagej_roi.py
│   └── pyproject.toml           NEW — uv project (replaces install_python.sh); pins cellpose>=3,<4, numpy<2, …
│
├── src/                         React UI (backend-agnostic)
│   ├── main.tsx                 (existing) mounts <App/> + router
│   ├── App.tsx                  (existing→rewritten) shell: Sidebar + Toolbar + <Outlet/>
│   │
│   ├── kernel/                  NEW — the shared kernel every feature depends on (§3)
│   │   ├── types.ts             domain DTOs: Image, Detection, Cell, Calibration, SizeBin, CompareResult, GroundTruth…
│   │   ├── transport/
│   │   │   ├── InferenceTransport.ts     interface + DTOs + IPC message schema (§3.1)
│   │   │   ├── TauriSidecarTransport.ts  desktop impl (invoke + event)
│   │   │   └── index.ts                  transport singleton / provider
│   │   ├── persistence/
│   │   │   ├── PersistencePort.ts        data-access interface (§3.8)
│   │   │   └── TauriSqlitePort.ts        desktop impl (invoke)
│   │   ├── store/
│   │   │   └── store.ts          global zustand store (§3.3)
│   │   ├── viewport/
│   │   │   ├── Viewport.tsx      pan/zoom/render canvas (§3.4)
│   │   │   └── useViewportTransform.ts   source-px ⇄ view-px math
│   │   ├── overlay/
│   │   │   ├── MaskOverlay.tsx   read-only renderer: contours/bbox/markers/annotations (§3.5)
│   │   │   └── MaskEditEngine.ts add/delete/merge/split/undo/redo (pure, §3.5)
│   │   ├── calibration/
│   │   │   └── calibration.ts    px/µm derivation + size-binning (§3.6)
│   │   ├── stats/
│   │   │   └── stats.ts          Mann-Whitney U + F1 (pure, portable, §3.7)
│   │   └── shortcuts/
│   │       └── keymap.ts         the frozen keyboard scheme (§3, feature: directory-nav-keyboard)
│   │
│   ├── pages/                   NEW — one dir per screen (§4). Each feature task owns exactly one.
│   │   ├── home/                Home / drop target
│   │   ├── processing/          determinate progress + live stderr line
│   │   ├── results/             viewer + editing + analysis sidebar
│   │   ├── batch/               batch/folder table
│   │   ├── compare/             Mann-Whitney comparison
│   │   ├── models/              cyto3 install via uv
│   │   ├── library/             images library + dedup
│   │   ├── review/              low-confidence triage queue
│   │   ├── settings/            analysis params + reset
│   │   └── onboarding/          onboarding + calibration modals
│   │
│   ├── components/              NEW — cross-page shared widgets (Sidebar, Toolbar, chrome)
│   └── styles/                  NEW — design tokens (port of Theme/Tokens.swift)
│
└── src-tauri/                   Rust backend
    ├── Cargo.toml               (add: rusqlite, image, sha2, serde, thiserror, uuid, tokio)
    ├── tauri.conf.json          (add capabilities: dialog, fs scope, shell for sidecar)
    ├── capabilities/default.json
    └── src/
        ├── main.rs              (existing) bootstraps lib
        ├── lib.rs               (existing→rewritten) registers commands + manages state
        ├── db/                  NEW
        │   ├── schema.rs        DDL (§3.8) + migrations
        │   ├── models.rs        Rust row structs mirroring TS DTOs
        │   └── repo.rs          data-access impl behind #[command]s
        ├── detection/           NEW
        │   ├── sidecar.rs       SidecarManager: spawn/stream/cancel (§3.1)
        │   └── ipc.rs           request/response/progress wire structs (serde)
        ├── images/              NEW
        │   └── importer.rs      decode + sha256 + thumbnail + EXIF probe
        ├── env/                 NEW
        │   └── uv.rs            uv bootstrap (venv + sync), sidecar Python path resolution
        ├── export/              NEW
        │   └── roi.rs           invoke _export_imagej_roi.py; CSV/provenance writers
        └── paths.rs             NEW — FileStore analogue (app-data dir tree, §3.8)
```

**Storage root** (Rust `paths.rs`, mirrors `FileStore.swift`): the OS app-data dir (`%APPDATA%/CellCounter/` on Windows) containing `store.sqlite`, `Images/<uuid>.<ext>`, `Thumbnails/<uuid>.jpg`, `Models/`, `Exports/`, and `python/` (the `uv` venv + `.venv/` marker). On macOS this is the same `~/Library/Application Support/CellCounter/` the Swift app already uses — the SQLite schema (§3.8) is designed to be readable from the existing `store.sqlite`.

---

## 3. The Shared Kernel

The kernel is the set of modules the whole app depends on. **These interfaces must be frozen before parallel feature work begins** (§6). Every signature below is real TypeScript / Rust, not pseudocode.

### 3.1 Inference transport (frontend↔backend contract) + Rust↔Python IPC

**Frontend interface** (`kernel/transport/InferenceTransport.ts`). This is the seam that lets the browser build swap in `onnxruntime-web`. It is intentionally 1:1 with the Swift `DetectionInput` / `DetectionResult` / `DetectionError` in `Detection/DetectionService.swift`.

```ts
// ---- DTOs (mirror Detection/SidecarSchema.swift + Domain/Cell.swift) ----

export interface DetectionParams {
  modelId: string;              // v1: always "cp-cyto3"
  pxPerUm: number;
  confidenceThreshold: number;  // analysis filter; cells below are hidden, never deleted
  channels: [number, number];   // [cyto, nuclei]; 0=gray,1=r,2=g,3=b. default [0,0]
  backgroundSubtract: boolean;
  rollingBallRadius: number;    // px, default 50
  watershedSplit: boolean;
  watershedMinDistanceUm: number; // default 8
  smallThresholdUm: number;     // default 20
  largeThresholdUm: number;     // default 30
  useGpu: boolean;              // false ⇒ --no-gpu
}

export interface CellDTO {
  id: string;                   // uuid
  cx: number; cy: number;       // SOURCE-PIXEL space
  diameterUm: number; diameterPx: number;
  confidence: number;           // [0,1]
  // optional per-cell measurements (absent on manual markers / legacy)
  areaUm2?: number; perimeterUm?: number; circularity?: number; eccentricity?: number;
  meanIntensity?: number; integratedDensity?: number;
  centroidUmX?: number; centroidUmY?: number; aspectRatio?: number; solidity?: number;
  edgeTouching?: boolean; likelyClump?: boolean; likelyDebris?: boolean;
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

export type DetectionProgress =
  | { kind: "stage"; runId: string; line: string }      // human-readable stderr line
  | { kind: "device"; runId: string; device: string }   // "MPS" | "CPU" | "CUDA:0"
  | { kind: "weights"; runId: string; doneMB: number; totalMB: number }; // future SAM download

export type DetectionError =
  | { kind: "modelNotInstalled"; modelId: string }
  | { kind: "sidecarFailed"; exitCode: number; stderr: string }
  | { kind: "imageDecodeFailed" }
  | { kind: "cancelled" };

export interface InferenceTransport {
  /** Run detection on one image. Rejects with a DetectionError on failure. */
  detect(imagePath: string, params: DetectionParams,
         onProgress?: (p: DetectionProgress) => void,
         signal?: AbortSignal): Promise<DetectionResultDTO>;

  /** Cancel an in-flight run by its id (SIGTERM→SIGKILL on desktop). */
  cancel(runId: string): Promise<void>;

  /** Is the active model runnable right now? (venv present + importable). */
  availability(modelId: string): Promise<{ installed: boolean; reason?: string }>;
}
```

**Rust command surface** (`detection/sidecar.rs`, registered in `lib.rs`). `detect` streams progress via a Tauri channel/event keyed by `run_id`; the UI subscribes and forwards to `onProgress`.

```rust
#[tauri::command]
async fn run_detection(
    app: tauri::AppHandle,
    image_path: String,
    params: DetectionParams,        // serde: matches the TS DetectionParams (camelCase via #[serde(rename_all="camelCase")])
    run_id: String,                 // client-generated; used for progress events + cancel
) -> Result<DetectionResultDTO, DetectionErrorDTO>;

#[tauri::command]
async fn cancel_detection(run_id: String) -> Result<(), String>;

#[tauri::command]
async fn detection_availability(model_id: String) -> Result<Availability, String>;
```

**Rust↔Python IPC (the sidecar wire protocol).** Reused verbatim from the Swift host (`Detection/CellposeDetectionService.swift`). `SidecarManager` builds argv, spawns `<venv>/bin/python cellpose_detect.py`, drains stdout to a buffer and stderr line-by-line.

- **argv order** (exact, from `CellposeDetectionService`):
  `["cellpose_detect.py", "--image", <path>, "--model", "cyto3", "--pxPerUm", <f>, "--conf", <f>]`
  then conditionally `["--channels", "c,c"]` (omitted when `0,0`), `["--restore"]` (only `cp-cyto3-r`; not in v1),
  `["--bg-subtract", "--rolling-ball-radius", <n>]`, `["--watershed", "--watershed-min-distance", <n>]`,
  always `["--small-threshold", <f>, "--large-threshold", <f>]`, and `["--no-gpu"]` when `useGpu==false`.
  Model-id mapping: strip `cp-` prefix (`cp-cyto3`→`cyto3`).
- **stdout:** a single JSON object, drained concurrently (readability handler) to avoid a full-pipe deadlock on ~60 KB payloads. Shape = `SidecarPayload` in `SidecarSchema.swift`:
  ```jsonc
  { "width": int, "height": int,
    "cells": [ { "id","cx","cy","diameter_um","diameter_px","confidence",
                 "area_um2?","perimeter_um?","circularity?","eccentricity?",
                 "mean_intensity?","integrated_density?","centroid_um_x?","centroid_um_y?",
                 "aspect_ratio?","solidity?","edge_touching?","likely_clump?","likely_debris?",
                 "size_class?","is_manual?","contour_px?": [[x,y],…] } ],
    "image_stats": { "focus_score":f, "illumination_residual":f, "n_colonies":f, … } }
  ```
  Rust maps snake_case → camelCase `CellDTO` at the boundary.
- **stderr:** newline/`\r`-split, trimmed, non-empty lines emitted as `{kind:"stage"}` progress. The line `"[cellpose_detect] using device: <dev> (torch …)"` is parsed into `{kind:"device"}` (take token up to space/`(`, uppercase). tqdm bars (`%|…|`) are dropped.
- **structured error:** if stdout parses as `{ "error": string, "hint"?: string }` (`SidecarError`), map to `DetectionError.sidecarFailed`.
- **lifecycle:** no hard timeout (runs to completion or cancel). Cancel = SIGTERM, then SIGKILL after 300 ms. Exit codes `{15,-15,143,9,-9,137}` ⇒ `DetectionError.cancelled` (swallowed by UI). An orphan sweep at app launch kills stray `cellpose_detect.py` processes.

### 3.2 Shared TypeScript domain types (`kernel/types.ts`)

Ported from `Domain/*.swift`. These are the vocabulary of the whole UI and persistence layer.

```ts
export interface ImageDTO {
  id: string;
  fileName: string;
  widthPx: number; heightPx: number;
  importedAt: string;              // ISO8601
  fileHash?: string;               // sha256 hex
  confidenceOverride?: number;     // per-image cutoff; overrides global
  notes?: string;
  storedPath: string;              // resolved by backend (Images/<id>.<ext>)
  thumbPath: string;               // Thumbnails/<id>.jpg
}

export interface DetectionDTO {
  id: string;
  imageId: string;
  detectorId: string;              // e.g. "cellpose/cp-cyto3"
  ranAt: string;
  cells: CellDTO[];
  imageStats?: Record<string, number>;
}

export interface CalibrationDTO {
  pxPerUm: number;
  source: "omeXML" | "tiffBaseline" | "olympus" | "zeiss" | "imagej" | "preset" | "manual" | "default";
  confidence?: "high" | "medium" | "low";
}

export interface SizeBin { min: number; max: number; label: string; } // max=Infinity for open top bin

export interface CompareGroup {
  condition: string;
  cells: CellDTO[];                // pooled across all batches with this condition
  n: number; meanUm: number; sdUm: number;
  binCounts: number[];             // aligned to the active SizeBin[]
}

export interface CompareResult {          // populated only for exactly 2 groups
  u: number; z: number; pValue: number;
  n1: number; n2: number;
  median1: number; median2: number; medianDifference: number;
  rankBiserial: number;                   // effect size
  significanceLabel: string;              // "p < 0.001" | "p = 0.03" | "p = 0.42 (n.s.)"
  effectSizeLabel: "negligible" | "small" | "medium" | "large";
}

export interface GroundTruthDTO { id: string; imageId: string; cx: number; cy: number; diameterUm?: number; note?: string; createdAt: string; }

export interface F1Score {
  tp: number; fp: number; fn: number;
  precision: number | null; recall: number | null; f1: number | null;
  matchRadiusFactor: number;
}

export interface BatchDTO {
  id: string; displayName: string; createdAt: string;
  modelId: string; pxPerUm: number; thresholds: number[];
  condition?: string; pxPerUmSource?: string;
  imageIds: string[];
}

export type EditorMode = "view" | "add" | "remove" | "merge" | "split" | "manualCount" | "annotate";
export type OverlayMode = "outline" | "bbox";
```

### 3.3 Global state store (`kernel/store/store.ts`)

Ported from `Shared/AppState.swift`. Zustand store; slices below. Analysis params persist to `localStorage` (the Swift app uses UserDefaults). Library/session state derives from the persistence port.

```ts
interface AnalysisParamsSlice {
  thresholds: number[];        // default [20,30]
  pxPerUm: number;             // default 2.6 (10× preset)
  confidence: number;          // default 0.50 — analysis filter, not destructive
  activeModelId: string;       // default "cp-cyto3"
  channels: [number, number];  // default [0,0]
  manualMarkerDiameterUm: number; // default 20
  backgroundSubtract: boolean; rollingBallRadius: number; // 50
  watershedSplit: boolean; watershedMinDistanceUm: number; // 8
  useGpu: boolean;             // default true
  maxParallel: number;         // default 1 (CPU cellpose is CPU-bound)
  setThresholds(t: number[]): void; setPxPerUm(v: number): void; /* … setters … */
}

interface SessionSlice {
  currentBatchId?: string;
  currentImageIdx: number;
  overlayMode: OverlayMode;        // outline | bbox
  showMaskFills: boolean; showOutlines: boolean; // Space/X/Z toggles
  maskOpacity: number;            // 0..1
  editorMode: EditorMode;
  selectedCellIds: Set<string>;
  zoom: number; pan: { x: number; y: number };
  openBatch(id: string): void; nextImage(): void; prevImage(): void;
}

interface LibrarySlice {          // cached, refreshed on mutations (mirrors refreshLibraryStats)
  libraryImageCount: number; libraryBatchCount: number; reviewQueueCount: number;
  recentBatchIds: string[];
  refreshLibraryStats(): Promise<void>;
}

interface ProcessingSlice {
  progress: number; stageLine: string; device: string; lastStageUpdateAt: number;
}

interface ErrorSlice {
  lastDetectionError?: string; showDetectionError: boolean;
  lastCalibrationNote?: string;
}

export type AppStore = AnalysisParamsSlice & SessionSlice & LibrarySlice & ProcessingSlice & ErrorSlice;

/** effective confidence for an image: override wins over global (mirrors AppState.effectiveConfidence) */
export function effectiveConfidence(store: AppStore, image: ImageDTO): number;
```

### 3.4 Viewport / canvas component (`kernel/viewport/Viewport.tsx`)

Pan/zoom + image render. Operates entirely in **source-pixel space**; hands children a `viewScale`/`viewOffset` exactly like the Swift `EditableOverlay`. Overlay + edit layers are children so they share one coordinate transform.

```ts
export interface ViewportProps {
  imageSrc: string;               // decoded image (blob URL or convertFileSrc path)
  sourceWidth: number; sourceHeight: number;
  zoom: number; pan: { x: number; y: number };
  minZoom?: number;               // default 0.4
  maxZoom?: number;               // default 4.0
  onZoomChange(z: number): void;
  onPanChange(p: { x: number; y: number }): void;
  onFit(): void;                  // ⌘0
  children?: React.ReactNode;     // overlay + edit layers, rendered in source-px via context
}

/** Provided to children so all hit-testing/render uses one transform. */
export interface ViewportTransform {
  viewScale: number;              // source-px → view-px
  viewOffset: { x: number; y: number };
  sourceToView(p: Pt): Pt; viewToSource(p: Pt): Pt;
}
export const ViewportTransformContext: React.Context<ViewportTransform>;
export type Pt = { x: number; y: number };
```

### 3.5 Mask-overlay renderer + mask-editing engine

**Renderer** (`kernel/overlay/MaskOverlay.tsx`) — read-only. Ported from the render half of `EditableOverlay.swift`. Draws, per cell: filled polygon from `contourPx` (bin-color fill at `maskOpacity`, outline stroke; dashed stroke when `confidence < effectiveConfidence`), else bbox/ellipse fallback by `overlayMode`; manual markers as fixed-radius numbered pins; ground-truth points as crosshairs.

```ts
export interface MaskOverlayProps {
  cells: CellDTO[];
  annotations?: GroundTruthDTO[];
  thresholds: number[];           // for bin coloring
  overlayMode: OverlayMode;
  confidenceCutoff: number;       // cells below render dashed/uncertain
  showMaskFills: boolean; showOutlines: boolean; maskOpacity: number;
  selectedCellIds: ReadonlySet<string>;
  mergeStagedId?: string; splitStagedId?: string;
}
```

**Editing engine** (`kernel/overlay/MaskEditEngine.ts`) — **pure** state machine (no React, no canvas), so it is unit-testable and reusable by the browser build. Ported from the mutating half of `EditableOverlay.swift` (modes, `EditEvent`, 50-deep undo/redo, merge geometry, bulk-delete). The `split` op is elevated to a first-class edit (backed today by watershed re-detection; here it splits one mask into two along a user stroke).

```ts
export type EditEvent =
  | { kind: "added"; cell: CellDTO }
  | { kind: "removed"; cells: CellDTO[] }                    // supports bulk-delete-by-rect
  | { kind: "merged"; removed: CellDTO[]; added: CellDTO }
  | { kind: "split"; removed: CellDTO; added: [CellDTO, CellDTO] }
  | { kind: "resized"; cell: CellDTO; oldDiameterUm: number };

export interface EditContext { pxPerUm: number; manualMarkerDiameterUm: number; }

export class MaskEditEngine {
  constructor(initial: CellDTO[], ctx: EditContext);
  get cells(): CellDTO[];
  get canUndo(): boolean; get canRedo(): boolean;

  hitTest(pt: Pt): CellDTO | undefined;                       // reverse order; polygon-in / bbox-in
  cellsInRect(rect: Rect): CellDTO[];
  cellsInPath(path: Pt[]): CellDTO[];

  addAt(pt: Pt): EditEvent;                                   // manual/added cell at source-px
  addFromContour(path: Pt[]): EditEvent;                      // freeform-drawn new mask (right-drag)
  remove(ids: string[]): EditEvent;                           // single or bulk
  merge(aId: string, bId: string): EditEvent;                 // center avg; d=√(da²+db²)/√2
  split(id: string, stroke: Pt[]): EditEvent;                 // cut one mask into two along stroke
  resize(id: string, newDiameterPx: number): EditEvent;

  undo(): EditEvent | undefined;                              // stacks capped at 50
  redo(): EditEvent | undefined;

  /** subscribe so the React layer + persistence can react to each committed edit */
  onCommit(cb: (e: EditEvent, cells: CellDTO[]) => void): () => void;
}
```

> **Future seam — train-from-GUI.** Corrections are already captured as discrete, replayable `EditEvent`s and persisted as `corrections` rows (§3.8, `kind ∈ {add,remove,move,resize,accept,manual}`). A later fine-tuning feature consumes `corrections` + `_seg.npy` masks to build a training set. Do **not** design this away: keep the correction log append-only and keep `_seg.npy` round-tripping (feature `seg-npy-io`) lossless. No task is created for training now.

### 3.6 Calibration + size-binning (`kernel/calibration/calibration.ts`)

Ported from `Services/EXIFCalibration.swift`, `Domain/SizeBin.swift`, `Domain/CalibrationPreset.swift`. The EXIF probe itself runs in Rust at import time (needs raw TIFF/OME bytes) and returns a `CalibrationDTO`; the TS module owns binning + preset/objective mapping + the priority contract.

```ts
/** Priority order the Rust importer follows (highest→lowest confidence):
 *  1. OME-XML in TIFF ImageDescription (tag 270): PhysicalSizeX + PhysicalSizeXUnit (default µm)
 *  2. TIFF baseline XResolution + ResolutionUnit (2=inch÷25400, 3=cm÷10000); reject 72/96/300 dpi defaults; valid 0.001<px/µm<1000
 *  3. ImageJ ImageDescription ("ImageJ=" prefix): pixelWidth + unit
 *  4. Olympus vendor: "Calibration Value" + "Calibration Unit"
 *  Returns null when nothing recognized. */
export const CALIBRATION_PRIORITY: readonly CalibrationDTO["source"][];

export function unitToUm(value: number, unit: string): number | null; // µm/um/micron→×1, nm→÷1e3, mm→×1e3, cm→×1e4, m→×1e6

export const BUILTIN_PRESETS: { name: string; pxPerUm: number; isDefault?: boolean }[]; // Olympus IX73 10×/20×/40× etc.
export function objectiveLabel(pxPerUm: number): string; // 1.3/2.6/5.2/10.4 → 5×/10×/20×/40× (±25%) else "custom scale"

export function binsFromThresholds(thresholds: number[]): SizeBin[];   // [20,30] → <20, 20–30, >30
export function binIndex(diameterUm: number, thresholds: number[]): number;
export function sizeClass(diameterUm: number, smallT: number, largeT: number): "small" | "intermediate" | "large";
```

### 3.7 Statistics (`kernel/stats/stats.ts`) — pure, portable TS

Direct port of `Services/Statistics.swift` (Mann-Whitney U, normal approximation + continuity correction, rank-biserial) and `Detection/AnnotationMatcher.swift` (greedy F1). No platform deps — runs identically in desktop and browser. Includes the Swift `_selfTest` cases as unit tests.

```ts
export function mannWhitneyU(a: number[], b: number[]): CompareResult | null; // null when either n<3
export function median(xs: number[]): number;
export function normalCdf(x: number): number;      // 0.5*(1+erf(x/√2))
export function twoTailedNormalP(z: number): number;

/** Greedy nearest-neighbour F1. Distances in SOURCE-PIXEL space.
 *  A candidate links ann↔det iff dist ≤ matchRadiusFactor * max(det.diameterPx,1).
 *  Sort candidates ascending, claim each ann/det at most once. TP=pairs, FP=unmatched det, FN=unmatched ann. */
export function evaluateF1(
  annotations: GroundTruthDTO[],
  detections: CellDTO[],
  matchRadiusFactor?: number,      // default 1.0
): F1Score;
```

### 3.8 Persistence: SQLite schema + data-access API

**Schema** (`src-tauri/src/db/schema.rs`). The 10 SwiftData `@Model` records (`Persistence/Records.swift`) map 1:1 to tables. IDs are `TEXT` UUIDs; JSON blobs stored as `TEXT`; timestamps ISO8601 `TEXT`; booleans `INTEGER 0/1`. Designed to coexist with the Swift app's existing `store.sqlite` on macOS.

```sql
CREATE TABLE batches (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at TEXT NOT NULL,
  display_name TEXT NOT NULL, model_id TEXT NOT NULL, px_per_um REAL NOT NULL,
  thresholds_json TEXT NOT NULL,           -- JSON [Double]
  condition TEXT, px_per_um_source TEXT
);
CREATE TABLE images (
  id TEXT PRIMARY KEY, file_name TEXT NOT NULL, original_path TEXT NOT NULL,
  width_px INTEGER NOT NULL, height_px INTEGER NOT NULL, imported_at TEXT NOT NULL,
  confidence_override REAL, file_hash TEXT, notes TEXT,
  batch_id TEXT REFERENCES batches(id) ON DELETE CASCADE
);
CREATE INDEX idx_images_hash ON images(file_hash);
CREATE TABLE detections (
  id TEXT PRIMARY KEY,
  image_id TEXT NOT NULL REFERENCES images(id) ON DELETE CASCADE,   -- 1:1 (unique)
  detector_id TEXT NOT NULL, ran_at TEXT NOT NULL,
  cells_json TEXT NOT NULL,                -- JSON [CellPayload] (contour flattened)
  min_confidence REAL NOT NULL,
  image_stats_json TEXT                    -- JSON {focus_score, illumination_residual, colony keys…}
);
CREATE UNIQUE INDEX idx_detection_image ON detections(image_id);
CREATE TABLE corrections (
  id TEXT PRIMARY KEY,
  detection_id TEXT NOT NULL REFERENCES detections(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,                      -- add|remove|move|resize|accept|manual
  cell_id TEXT NOT NULL, cx REAL NOT NULL, cy REAL NOT NULL, diameter REAL NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_corrections_detection ON corrections(detection_id);
CREATE TABLE rois (
  id TEXT PRIMARY KEY, image_id TEXT NOT NULL REFERENCES images(id) ON DELETE CASCADE,
  kind TEXT NOT NULL, shape TEXT NOT NULL,  -- include|exclude ; rect|ellipse
  x REAL, y REAL, width REAL, height REAL, created_at TEXT NOT NULL, name TEXT
);
CREATE TABLE ground_truth_annotations (
  id TEXT PRIMARY KEY, image_id TEXT NOT NULL REFERENCES images(id) ON DELETE CASCADE,
  cx REAL NOT NULL, cy REAL NOT NULL, diameter REAL, created_at TEXT NOT NULL, note TEXT
);
CREATE INDEX idx_gt_image ON ground_truth_annotations(image_id);
CREATE TABLE conditions (
  id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, color TEXT NOT NULL,
  created_at TEXT NOT NULL, "order" INTEGER NOT NULL
);
CREATE TABLE calibration_presets (id TEXT PRIMARY KEY, name TEXT NOT NULL, px_per_um REAL NOT NULL, is_default INTEGER NOT NULL);
CREATE TABLE bin_presets (id TEXT PRIMARY KEY, name TEXT NOT NULL, thresholds_json TEXT NOT NULL);
CREATE TABLE model_versions (         -- future train-from-GUI seam; unused in v1 but created now
  id TEXT PRIMARY KEY, model_id TEXT NOT NULL, version INTEGER NOT NULL, created_at TEXT NOT NULL,
  trained_on_images INTEGER NOT NULL, trained_on_corrections INTEGER NOT NULL,
  checkpoint_path TEXT NOT NULL, metrics_json TEXT NOT NULL
);
```

`CellPayload` JSON (per cell, stored in `detections.cells_json`) mirrors `Records.swift`: `id, cx, cy, diameter, diameterPx, confidence`, optional measurements/flags, and `contourFlat: [x0,y0,x1,y1,…]` (flattened contour). The DTO↔payload mapping lives in `db/models.rs`.

**Data-access API** (`kernel/persistence/PersistencePort.ts`, backed by Rust `#[command]`s in `db/repo.rs`). Ported from `Persistence/Repositories.swift`. All methods async (they cross the IPC boundary).

```ts
export interface PersistencePort {
  // batches
  allBatches(): Promise<BatchDTO[]>;
  batch(id: string): Promise<BatchDTO | null>;
  createBatch(p: { displayName: string; modelId: string; pxPerUm: number; thresholds: number[]; condition?: string }): Promise<BatchDTO>;
  batchesMatching(condition: string): Promise<BatchDTO[]>;
  deleteBatch(id: string): Promise<void>;
  cleanupEmptyBatches(): Promise<void>;
  // images
  allImages(): Promise<ImageDTO[]>;
  imageMatchingHash(hash: string, fileName: string, excludingId?: string): Promise<ImageDTO | null>;
  duplicateGroups(): Promise<ImageDTO[][]>;
  deleteImage(id: string): Promise<void>;
  attachImageToBatch(imageId: string, batchId: string): Promise<void>;
  // detections & corrections
  saveDetection(imageId: string, detectorId: string, cells: CellDTO[], imageStats?: Record<string, number>): Promise<DetectionDTO>;
  getDetection(imageId: string): Promise<DetectionDTO | null>;
  recordCorrection(detectionId: string, c: { kind: string; cellId: string; cx: number; cy: number; diameter: number }): Promise<void>;
  // rois / annotations / conditions
  rois(imageId: string): Promise<RoiDTO[]>; saveRoi(imageId: string, roi: RoiDTO): Promise<void>; deleteRoi(id: string): Promise<void>;
  annotations(imageId: string): Promise<GroundTruthDTO[]>; addAnnotation(a: GroundTruthDTO): Promise<void>; deleteAnnotation(id: string): Promise<void>; deleteAllAnnotations(imageId: string): Promise<void>;
  conditions(): Promise<ConditionDTO[]>; createCondition(name: string, color: string): Promise<ConditionDTO>; renameCondition(id: string, name: string): Promise<void>; reorderConditions(orderedIds: string[]): Promise<void>; deleteCondition(id: string): Promise<void>;
  // presets & counts & review
  calibrationPresets(): Promise<CalibrationPresetDTO[]>; upsertCalibrationPreset(p: CalibrationPresetDTO): Promise<void>; deleteCalibrationPreset(id: string): Promise<void>;
  binPresets(): Promise<BinPresetDTO[]>;
  totalImageCount(): Promise<number>; totalBatchCount(): Promise<number>;
  uncorrectedCellCount(belowConfidence: number): Promise<number>; // review-queue badge
  wipeAllUserData(): Promise<void>;
}
```

Image import is a separate Rust command (needs raw bytes): `import_image(sourcePath) -> { image: ImageDTO, calibration: CalibrationDTO | null }` — decodes (`jpg/jpeg/png/tif/tiff/bmp`), computes **whole-file** SHA-256, copies to `Images/<id>.<ext>`, writes a 256px JPEG (q0.7) thumbnail, and probes EXIF per §3.6. Mirrors `Services/ImageLoader.swift`.

---

## 4. Page / Route Breakdown

Routes replace the Swift `AppView` enum (`Shared/AppState.swift`). Each page lives in its own `src/pages/<name>/` dir (§2) and is owned by exactly one feature task (§ tasks.json). All pages read/write the store and go through the two ports — none talk to Python or SQLite directly.

| Route | Screen | What it does | Kernel it uses |
|---|---|---|---|
| `/` | **Home** | Drop target for images/folders; recents; primary "Choose images" CTA; kicks import+detect | store, PersistencePort, InferenceTransport |
| `/processing` | **Processing** | Determinate progress + live stderr `stageLine` + resolved `device`; Cancel | store (ProcessingSlice), InferenceTransport.cancel |
| `/results` | **Results** | The core screen: `Viewport` + `MaskOverlay` + `MaskEditEngine` editing toolbar + right analysis sidebar (histogram, size bins, QC badges, colonies, F1 vs ground truth, notes, ROI). Directory next/prev, overlay/opacity toggles, export | Viewport, MaskOverlay, MaskEditEngine, calibration, stats(F1), keymap, both ports |
| `/batch` | **Batch** | Per-image table for the current batch (status, count, mean Ø, size-class mini-dist); aggregate stats; per-image summary CSV export | store, PersistencePort, calibration |
| `/compare` | **Compare** | Condition chips (1–4); pooled histograms sharing a Y-axis; Mann-Whitney panel when exactly 2 selected; comparison CSV | stats(mannWhitneyU), calibration(bins), PersistencePort |
| `/models` | **Models** | Catalog (v1: cyto3 only active; others "coming soon"); install cyto3 via `uv`; streamed install progress; availability | InferenceTransport.availability, `env` commands |
| `/library` | **Images Library** | All imported images grid; SHA-256 duplicate groups; open/delete | PersistencePort, store |
| `/review` | **Review Queue** | Triage cells with `confidence < 0.65` and no correction: Reject(R)/Keep(K)/Edit-Ø(E)/Skip(→); writes corrections | PersistencePort, store, keymap |
| `/settings` | **Settings** | Analysis params (thresholds, confidence, channels, bg-subtract, watershed, GPU, max-parallel), calibration presets, reset/wipe | store, PersistencePort |
| `/onboarding` (modal) | **Onboarding + Calibration** | First-run onboarding; calibration sheet (direct value / draw-on-scale-bar / preset tabs); manual diameter fallback when no EXIF | calibration, store, PersistencePort |

The app shell (`App.tsx` + `components/Sidebar`, `components/Toolbar`) reproduces the Swift `Sidebar.swift` groups: **top** (Home, Queue, Review), **Library** (Images, Batches, Compare), **System** (Models, Fine-tune*), **bottom** (Support, Settings). *Fine-tune is a disabled placeholder in v1 (the train-from-GUI seam).

---

## 5. Feature → Module Mapping

| Existing Swift feature | Source (Swift) | New module / page |
|---|---|---|
| Folder/batch detection | `AppState.importAndAnalyze`, `BatchView` | `pages/home`, `pages/batch`, InferenceTransport, PersistencePort |
| Per-image counts + size classes | `ResultsView`, `AnalysisPanel`, `SizeBin` | `pages/results`, `kernel/calibration` |
| µm size-binning | `Domain/SizeBin.swift` | `kernel/calibration` (`binsFromThresholds`, `binIndex`) |
| Auto calibration (OME/EXIF) + manual override | `Services/EXIFCalibration`, `CalibrationSheet` | Rust `images/importer`, `kernel/calibration`, `pages/onboarding` |
| Manual correction (add/delete) | `Views/Results/EditableOverlay` | `kernel/overlay/MaskEditEngine`, `pages/results` |
| **Mask editing (draw/delete/bulk/merge/split)** | `EditableOverlay` (+ `SplitTouchingButton` for split-by-watershed) | `kernel/overlay/MaskEditEngine`, `pages/results` |
| **Undo/redo** | `EditableOverlay` undo/redo stacks (cap 50) | `MaskEditEngine.undo/redo` |
| **Keyboard scheme** | `KeyboardShortcutsSheet` | `kernel/shortcuts/keymap`, per-page `useKeymap` |
| **Directory navigation** | Results ←/→ in `ResultsView` | `pages/results`, store `next/prevImage` |
| **Overlay/outline toggles + opacity** | Space/X/Z in Results | `MaskOverlay` props + store (SessionSlice) |
| **`_seg.npy` import/export** | (new) — round-trips with Cellpose GUI | feature `seg-npy-io` (Rust cmd + Python helper), `pages/results` |
| **Pan/zoom** | `EditableOverlay` viewScale/offset | `kernel/viewport/Viewport` |
| **Manual diameter fallback** | `manualMarkerDiameter`, cellpose fixed-diameter prior | store + `pages/onboarding` + params |
| Compare (Mann-Whitney + effect size) | `Services/Statistics`, `CompareView` | `kernel/stats`, `pages/compare` |
| F1 vs ground truth | `Detection/AnnotationMatcher`, ground-truth mode | `kernel/stats.evaluateF1`, `pages/results` (annotate mode) |
| PDF report | `Services/PDFReportGenerator` | feature `export` (`pages/results` action + Rust/print) |
| ImageJ ROI export | `python/_export_imagej_roi.py`, `ExportService` | feature `export` (Rust invokes existing Python helper) |
| CSV export (cells/summary/annotations) | `Services/ExportService` | feature `export` |
| SHA-256 dedup | `ImageLoader.sha256Hex`, `Repositories.imageRecord(matchingHash:)` | Rust `images/importer`, `pages/library` |
| Onboarding | `OnboardingSheet` | `pages/onboarding` |
| Persistence (SwiftData) | `Persistence/Records`, `Repositories`, `FileStore` | `src-tauri/src/db`, `PersistencePort`, `paths.rs` |
| Python env install (shell) | `install_python.sh`, `_lib_install.sh`, `CellposeInstaller` | Rust `env/uv` (`uv venv` + `uv sync`), `pages/models` |
| Detection subprocess pipe | `CellposeDetectionService`, `PythonRuntime`, `ChildProcessTracker` | Rust `detection/sidecar`, TauriSidecarTransport |
| ROI include/exclude filtering | `EditableROI`, `ROIFiltered` | `pages/results` (uses `rois` from port) |
| QC badges / colonies | `QCBadges`, `ColoniesPanel` | `pages/results` sidebar (reads `imageStats`) |
| Fine-tune (train-from-GUI) | `TrainingService`, `FineTuneView` | **seam only** — `model_versions` table + append-only corrections; no v1 task |

---

## 6. Interface-Freeze Note

Feature tasks run in parallel and must not collide. To make that safe, these **kernel interfaces must be frozen before any feature task starts** — they are the contracts every feature compiles against:

1. **`InferenceTransport.ts` + the Rust↔Python IPC structs** (§3.1) — argv order, `DetectionResultDTO`, `DetectionProgress`, `DetectionError`. Everything that runs detection depends on this; the browser build depends on it being implementation-free.
2. **`kernel/types.ts`** (§3.2) — the domain DTOs. Every page, port, and kernel module imports these. A late field rename ripples everywhere.
3. **`PersistencePort.ts` + the SQLite DDL** (§3.8) — method signatures and table shapes. Any feature that reads/writes data binds to this.
4. **`store.ts` slice shapes** (§3.3) — the store keys pages read/write. Freeze the slice interfaces (setters may be added later without breaking readers).
5. **`Viewport` props + `ViewportTransform` context** (§3.4) and **`MaskEditEngine` public API + `EditEvent`** (§3.5) — Results, Review, and any canvas feature build on these.
6. **`keymap.ts`** (§3, the frozen scheme in `KeyboardShortcutsSheet`) — pages register handlers against stable action ids.

Statistics (§3.7) and calibration (§3.6) are pure and additive; their **signatures** should be frozen too, but their internals can evolve without breaking callers. Everything not in this list (page internals, component styling, Rust command bodies) can change freely during feature work.

Recommended sequencing: land tasks `kernel-transport`, `kernel-types`, `kernel-persistence`, `kernel-store`, `kernel-viewport`, `kernel-overlay-engine`, `kernel-calibration`, `kernel-stats` first (they are mutually near-independent and own disjoint files), publish the frozen interfaces, then fan out the feature tasks.
