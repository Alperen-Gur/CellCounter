/**
 * pages/models/catalog.ts — the model catalog for the Models tab.
 *
 * Owned by feature task `feat-models`. Two entries are active and runnable —
 * Cellpose `cp-cyto3` (the default) and Cellpose-SAM `cpsam` — each installed,
 * probed, and activated independently; every other entry is shown "coming
 * soon" and is non-activatable. The catalog is intentionally data-only so the
 * page body stays declarative and the "coming soon" set can grow without
 * touching render logic.
 *
 * `id` is the app-facing model id used everywhere else (store.activeModelId,
 * DetectionParams.modelId) and is exactly what reaches the backend. The
 * sidecar strips a leading `cp-` prefix (`cp-cyto3` → `cyto3`); `cpsam` has no
 * such prefix and passes through unchanged — that mapping lives in the
 * Rust/transport layer, NOT here. The Rust side routes `cpsam` installs to
 * their own `cellpose>=4` venv, independent of the base venv the other
 * Cellpose models share.
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
   * Whether this model can be installed/activated. `cp-cyto3` and `cpsam` are
   * `true`; the rest are `false` ("coming soon") and cannot be activated or
   * installed from the UI.
   */
  available: boolean;
  /** Runtime backing the model (informational). */
  backend: string;
  /** Approximate size class shown on the card (informational). */
  sizeLabel: string;
}

/**
 * The catalog. Array order is display order. Adding a future model = flip
 * `available` to `true` and wire its runtime; the render layer does not
 * change.
 */
export const MODEL_CATALOG: readonly ModelCatalogEntry[] = [
  {
    id: "cpsam_v2",
    name: "Cellpose-SAM v2",
    description:
      "The strongest general-purpose detector for difficult, irregular, and crowded cells. Runs locally in its own Cellpose 4 environment.",
    glyph: "layers",
    available: true,
    backend: "Cellpose 4 · isolated Python sidecar",
    sizeLabel: "~1.15 GB weights",
  },
  {
    id: "cp-cyto3",
    name: "Cellpose cyto3",
    description:
      "Fast, compact general cytoplasm segmentation for routine brightfield and fluorescence work. Runs locally through the uv-managed Python sidecar.",
    glyph: "scope",
    available: true,
    backend: "Cellpose · Python sidecar",
    sizeLabel: "~26 MB weights",
  },
  {
    id: "sd-fluo",
    name: "StarDist versatile fluorescence",
    description:
      "Fast star-convex instance segmentation for fluorescent nuclei. Runs locally in an isolated TensorFlow environment with the exact 2D versatile fluorescence weights.",
    glyph: "scope",
    available: true,
    backend: "StarDist · isolated Python sidecar",
    sizeLabel: "pretrained fluorescence weights",
  },
] as const;

/** The default model a fresh install activates (see store `activeModelId`). */
export const ACTIVE_MODEL_ID = "cp-cyto3";

/**
 * Human-friendly display name for a model id, resolved from the catalog (the
 * single source of truth). Falls back to the raw id for an unknown model.
 */
export function modelLabel(id: string): string {
  return MODEL_CATALOG.find((m) => m.id === id)?.name ?? id;
}
