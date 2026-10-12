/** Installable detector entries. Exact runtime/checkpoint readiness is probed
 * separately; a catalog entry does not imply its weights are already installed.
 * App IDs are mapped explicitly by the native sidecar without substitutions. */

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
  /** Whether this detector has a supported install/activation route. */
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
    name: "Cellpose-SAM",
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
  { id: 'cp4-cpsam_v2', name: 'Cellpose-SAM v2', description: 'Exact cpsam_v2 checkpoint; requires a runtime that provides this checkpoint.', glyph: "scope", available: true, backend: 'Cellpose 4', sizeLabel: "local runtime" },
  { id: 'cp4-cpdino', name: 'Cellpose-DINO ViT-L', description: 'Exact cpdino checkpoint; no substitution if absent from the runtime.', glyph: "scope", available: true, backend: 'Cellpose 4', sizeLabel: "local runtime" },
  { id: 'cp4-cpdino-vitb', name: 'Cellpose-DINO ViT-B', description: 'Exact cpdino-vitb checkpoint.', glyph: "scope", available: true, backend: 'Cellpose 4', sizeLabel: "local runtime" },
  { id: 'cp-cyto3-r', name: 'Cellpose cyto3 + restore', description: 'Restoration followed by cyto3 segmentation.', glyph: "scope", available: true, backend: 'Cellpose 3 restoration', sizeLabel: "local runtime" },
  { id: 'cp-cyto2', name: 'Cellpose cyto2', description: 'Cellpose 3 cytoplasm checkpoint.', glyph: "scope", available: true, backend: 'Cellpose 3', sizeLabel: "local runtime" },
  { id: 'cp-nuclei', name: 'Cellpose nuclei', description: 'Cellpose 3 nuclear checkpoint.', glyph: "scope", available: true, backend: 'Cellpose 3', sizeLabel: "local runtime" },
  { id: 'sd-he', name: 'StarDist H&E', description: 'RGB H&E nuclear segmentation.', glyph: "scope", available: true, backend: 'StarDist', sizeLabel: "local runtime" },
  { id: 'sd-dsb2018', name: 'StarDist DSB2018', description: 'Exact 2D_paper_dsb2018 checkpoint.', glyph: "scope", available: true, backend: 'StarDist', sizeLabel: "local runtime" },
  { id: 'omni-bact-phase', name: 'Omnipose bacteria phase', description: 'bact_phase_omni checkpoint in an isolated runtime.', glyph: "scope", available: true, backend: 'Omnipose', sizeLabel: "local runtime" },
  { id: 'omni-bact-fluor', name: 'Omnipose bacteria fluorescence', description: 'bact_fluor_omni checkpoint in an isolated runtime.', glyph: "scope", available: true, backend: 'Omnipose', sizeLabel: "local runtime" },
  { id: 'omni-cyto2', name: 'Omnipose cyto2', description: 'cyto2_omni checkpoint in an isolated runtime.', glyph: "scope", available: true, backend: 'Omnipose', sizeLabel: "local runtime" },
  { id: 'cw-otsu', name: 'Classical Otsu', description: 'Deterministic threshold and watershed; confidence expresses contrast.', glyph: "scope", available: true, backend: 'scikit-image CPU', sizeLabel: "local runtime" },
  { id: 'cw-triangle', name: 'Classical triangle', description: 'Triangle threshold and watershed.', glyph: "scope", available: true, backend: 'scikit-image CPU', sizeLabel: "local runtime" },
  { id: 'cw-adaptive', name: 'Classical adaptive', description: 'Local threshold and watershed.', glyph: "scope", available: true, backend: 'scikit-image CPU', sizeLabel: "local runtime" },
  { id: 'cw-manual', name: 'Classical manual', description: 'Explicit intensity threshold and watershed.', glyph: "scope", available: true, backend: 'scikit-image CPU', sizeLabel: "local runtime" },
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
