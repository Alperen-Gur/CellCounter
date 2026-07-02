/**
 * pages/models/catalog.ts — the v1 model catalog for the Models tab.
 *
 * Owned by feature task `feat-models`. In v1 exactly ONE model is active
 * (Cellpose `cyto3`); every other entry is shown "coming soon" and is
 * non-activatable (boundary: no non-cyto3 model runtimes in v1). The catalog is
 * intentionally data-only so the page body stays declarative and the "coming
 * soon" set can grow without touching render logic.
 *
 * `id` is the app-facing model id used everywhere else (store.activeModelId,
 * DetectionParams.modelId). The sidecar strips the `cp-` prefix (`cp-cyto3` →
 * `cyto3`) — that mapping lives in the Rust/transport layer, NOT here.
 */

export interface ModelCatalogEntry {
  /** App-facing model id (matches store.activeModelId / DetectionParams.modelId). */
  id: string;
  /** Display name. */
  name: string;
  /** One-line description of what the model is for. */
  description: string;
  /**
   * Name of the line-icon (see components/Icon.tsx `IconName`) used as a
   * lightweight per-model glyph. Kept a plain string so this data module stays
   * free of a render-layer import; the page renders it via `<Icon name={…} />`.
   */
  glyph: string;
  /**
   * Whether this model can be installed/activated in v1. Exactly one entry
   * (`cp-cyto3`) is `true`; the rest are `false` ("coming soon") and cannot be
   * activated or installed from the UI.
   */
  available: boolean;
  /** Runtime backing the model (informational). */
  backend: string;
  /** Approximate size class shown on the card (informational). */
  sizeLabel: string;
}

/**
 * The v1 catalog. Order matters — the active model renders first. Adding a
 * future model = flip `available` to `true` and wire its runtime; the render
 * layer does not change.
 */
export const MODEL_CATALOG: readonly ModelCatalogEntry[] = [
  {
    id: "cp-cyto3",
    name: "Cellpose cyto3",
    description:
      "General cytoplasm segmentation. The default detector for v1 — runs locally via the uv-managed Python sidecar on CPU (MPS on Apple silicon).",
    glyph: "scope",
    available: true,
    backend: "Cellpose · Python sidecar",
    sizeLabel: "~26 MB weights",
  },
  {
    id: "cp-cyto3-r",
    name: "Cellpose cyto3 (restore)",
    description:
      "cyto3 with the image-restoration pass for noisy / low-contrast fields. Planned for a later release.",
    glyph: "sliders",
    available: false,
    backend: "Cellpose · Python sidecar",
    sizeLabel: "coming soon",
  },
  {
    id: "cpsam",
    name: "Cellpose-SAM",
    description:
      "Promptable SAM-backed segmentation for the future WebGPU / in-browser build. Not part of the desktop v1 runtime.",
    glyph: "layers",
    available: false,
    backend: "onnxruntime-web · WebGPU",
    sizeLabel: "coming soon",
  },
] as const;

/** The single model that is runnable in v1. */
export const ACTIVE_MODEL_ID = "cp-cyto3";
