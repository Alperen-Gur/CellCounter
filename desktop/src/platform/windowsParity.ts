/** Auditable macOS v1.0.13 → Windows v1.1.0 capability inventory.
 * Pending rows point to the native implementation that remains to be ported;
 * source-symbol checks establish traceability, not end-to-end feature proof.
 *
 * This is rendered by SupportPage and consumed by the portable parity check.
 * A capability may never disappear from the Windows plan merely because its
 * implementation is not ready. `pending` items are deliberately user-visible.
 */

export type ParityState = "ready" | "adapted" | "pending";
export type ParityArea =
  | "Input"
  | "Detection"
  | "Analysis"
  | "Editing"
  | "Workflow"
  | "Export"
  | "System";

export interface WindowsParityCapability {
  id: string;
  area: ParityArea;
  name: string;
  state: ParityState;
  windowsSurface: string;
  note: string;
  /** `relative/path#literal symbol` references checked by verify:parity. */
  evidence: readonly string[];
}

const EVIDENCE: Record<string, readonly string[]> = {
  "input-standard": ["src-tauri/src/images/importer.rs#fn prepare_standard_image"],
  "input-folder": ["src-tauri/src/images/importer.rs#pub fn list_images_in_dir"],
  "input-vendor": ["src-tauri/src/images/importer.rs#async fn import_vendor_image", "python/_imageio.py#VENDOR_PACKAGES"],
  "input-dedup": ["src/pages/home/DuplicatePrompt.tsx#DuplicatePrompt"],
  "input-calibration-meta": ["src-tauri/src/images/importer.rs#pub fn probe_calibration"],
  "input-calibration-manual": ["src/pages/onboarding/CalibrationModal.tsx#CalibrationModal"],
  "input-calibration-persist": ["src-tauri/src/db/repo.rs#pub fn calibration_presets"],
  "model-cpsam": ["src/pages/models/catalog.ts#cpsam_v2", "src-tauri/src/detection/sidecar.rs#Some(\"cpsam\")"],
  "model-cyto3": ["src/pages/models/catalog.ts#cp-cyto3", "src-tauri/src/detection/sidecar.rs#Some(\"cyto3\")"],
  "model-stardist": ["src/pages/models/catalog.ts#sd-fluo", "python/stardist_detect.py#2D_versatile_fluo"],
  "detection-batch": ["src-tauri/src/detection/sidecar.rs#pub struct SidecarManager"],
  "detection-cancel": ["src-tauri/src/detection/sidecar.rs#pub async fn cancel_detection"],
  "detection-preprocess": ["src/pages/settings/SettingsPage.tsx#GPU acceleration", "src-tauri/src/detection/sidecar.rs#enforce_windows_runtime_contract"],
  "detection-watershed": ["python/_cellpose_common.py#def apply_watershed_if_requested"],
  "detection-provenance": ["src-tauri/src/export/provenance.rs#fn run_model_from_detector"],
  "analysis-measure": ["python/_cellpose_common.py#def measure_cells"],
  "analysis-bins": ["src/pages/results/AnalysisSidebar.tsx#function SizeBinsPanel"],
  "analysis-qc": ["src/pages/results/QCBadges.tsx#export function QCBadges"],
  "analysis-colony": ["python/_cellpose_common.py#def compute_colony_stats"],
  "analysis-intensity": ["src/pages/results/AdvancedAssaysPanel.tsx#value=\"intensity\"", "python/intensity_assays.py#def run_assays"],
  "analysis-area": ["src/pages/results/AdvancedAssaysPanel.tsx#scratch-wound", "python/area_assays_detect.py#def main"],
  "analysis-puncta": ["src/pages/results/AdvancedAssaysPanel.tsx#value=\"puncta\"", "python/puncta_detect.py#def main"],
  "analysis-spatial": ["src/kernel/stats/spatial.ts#export function spatialSummary"],
  "analysis-tracking": ["src/pages/results/AdvancedAssaysPanel.tsx#value=\"tracking\"", "python/track_cells.py#def main"],
  "analysis-neurite": ["src/pages/results/AdvancedAssaysPanel.tsx#value=\"neurite\"", "python/neurite_outgrowth.py#def main"],
  "analysis-line-profile": ["src/pages/results/LineProfilePanel.tsx#export function LineProfilePanel", "src-tauri/src/analysis/runner.rs#pub async fn line_profile"],
  "edit-overlay": ["src/pages/results/OverlayControls.tsx#export function OverlayControls"],
  "edit-cells": ["src/pages/results/editing/useMaskEditor.ts#export function useMaskEditor"],
  "edit-ground-truth": ["src/kernel/stats/stats.ts#export function evaluateF1"],
  "edit-roi": ["src/pages/results/roiFilter.ts#export function applyRoiFilter"],
  "edit-notes": ["src/pages/results/AnalysisSidebar.tsx#function NotesPanel"],
  "workflow-library": ["src/pages/library/LibraryPage.tsx#LibraryPage"],
  "workflow-batches": ["src/pages/batch/BatchPage.tsx#BatchPage"],
  "workflow-review": ["src/pages/review/ReviewCard.tsx#ReviewCard"],
  "workflow-compare": ["src/pages/compare/ComparePage.tsx#ComparePage"],
  "workflow-protocol": ["src/pages/settings/analysisProtocol.ts#export function applyAnalysisProtocol"],
  "workflow-finetune": ["src/pages/finetune/FineTunePage.tsx#Fine-tune cyto3", "src-tauri/src/analysis/training.rs#pub async fn run_fine_tune"],
  "export-cells": ["src-tauri/src/export/csv.rs#pub async fn export_cells_csv"],
  "export-roi": ["src-tauri/src/export/roi.rs#pub async fn export_imagej_roi"],
  "export-segnpy": ["src/pages/results/segnpy/SegNpyPanel.tsx#export default function SegNpyPanel"],
  "export-provenance": ["src-tauri/src/export/provenance.rs#pub async fn export_provenance"],
  "export-pdf": ["src-tauri/src/export/report.rs#pub async fn export_pdf_report"],
  "export-overlay": ["src-tauri/src/export/annotated.rs#pub async fn export_annotated_png"],
  "export-geojson": ["src-tauri/src/export/geojson.rs#pub async fn export_geojson"],
  "system-storage": ["src-tauri/src/db/repo.rs#pub fn wipe_all_user_data"],
  "system-accessibility": ["src/kernel/shortcuts/keymap.ts#export const keymap"],
  "system-support": ["src/pages/system/SupportPage.tsx#WINDOWS_PARITY_CAPABILITIES"],
  "workflow-inspect": ["src/pages/processing/ProcessingPage.tsx#export default function ProcessingPage"],
  "workflow-recovery": ["src/kernel/workflow/AnalysisQueue.ts#export class AnalysisQueue"],
  "analysis-linked": ["src/pages/results/LinkedMeasurements.tsx#export function LinkedMeasurements"],
  "edit-variants": ["src/pages/results/MaskVersionsPanel.tsx#export function MaskVersionsPanel"],
  "input-source-selection": ["src-tauri/src/images/projection.rs#pub(crate) async fn prepare"],
  "input-selected-preview": ["../CellCounting/Services/ImageLoader.swift#ImageLoader"],
  "model-native-extras": ["../CellCounting/Domain/DetectionModel.swift#cp-nuclei"],
  "workspace-omezarr": ["../CellCounting/Services/OMEZarrService.swift#actor OMEZarrService"],
  "workspace-navigation": ["../CellCounting/Domain/MicroscopyWorkspace.swift#struct MicroscopyWorkspace"],
  "workspace-registration": ["../CellCounting/Services/ImageRegistrationService.swift#registerSequence"],
  "workspace-animation": ["../CellCounting/Services/WorkspaceAnimationService.swift#WorkspaceAnimationService"],
  "workspace-replay": ["../CellCounting/Services/WorkspaceWorkflowService.swift#actor WorkspaceWorkflowService"],
  "workspace-lineage": ["../CellCounting/Services/WorkspaceLineageService.swift#WorkspaceLineage"],
  "workspace-paint": ["../CellCounting/Domain/MicroscopyWorkspace.swift#struct WorkspacePaintDocument"],
  "analysis-prompt": ["../CellCounting/Services/PromptRefinementService.swift#enum PromptRefinementService"],
  "analysis-propagation": ["../CellCounting/Services/SequenceWorkflowService.swift#driftCorrected"],
  "analysis-preprocess-extra": ["../CellCounting/Views/Results/AdvancedWorkflowsPanel.swift#preprocessingSection"],
  "analysis-curation-grid": ["../CellCounting/Views/Results/AdvancedWorkflowsPanel.swift#curationSection"],
  "workflow-reviewed-training": ["../CellCounting/Services/TrainingDatasetService.swift#enum TrainingDatasetService"],
  "analysis-channel-measurements": ["../CellCounting/Views/Results/ChannelStackPanel.swift#ChannelStackPanel"],

};

const INVENTORY = [
  { id: "input-standard", area: "Input", name: "PNG, JPEG, TIFF and BMP import", state: "ready", windowsSurface: "Home", note: "Native Rust decoder, hashing and local copy." },
  { id: "input-folder", area: "Input", name: "Recursive folder and batch import", state: "ready", windowsSurface: "Home", note: "Windows-safe directory walk with loop protection." },
  { id: "input-vendor", area: "Input", name: "ND2, CZI, LIF, OIR and VSI import", state: "ready", windowsSurface: "Home", note: "App-owned originals plus bounded, lossless projected analysis TIFFs with explicit reader diagnostics." },
  { id: "input-dedup", area: "Input", name: "SHA-256 duplicate review", state: "ready", windowsSurface: "Home / Images", note: "Per-file skip or keep decisions." },
  { id: "input-calibration-meta", area: "Input", name: "Microscope metadata calibration", state: "adapted", windowsSurface: "Import / Calibration", note: "OME-TIFF, baseline TIFF, ImageJ and Olympus metadata are supported; proprietary container metadata follows vendor import." },
  { id: "input-calibration-manual", area: "Input", name: "Manual and scale-bar calibration", state: "ready", windowsSurface: "Calibration", note: "Source-pixel geometry and px/µm are preserved." },
  { id: "input-calibration-persist", area: "Input", name: "Calibration presets and persistence", state: "ready", windowsSurface: "Settings", note: "Stored in SQLite and analysis settings." },

  { id: "model-cpsam", area: "Detection", name: "Cellpose-SAM", state: "ready", windowsSurface: "Models", note: "Exact cpsam checkpoint in isolated Cellpose 4 runtime; cpsam_v2 is retained only as a legacy application ID." },
  { id: "model-cyto3", area: "Detection", name: "Cellpose cyto3", state: "ready", windowsSurface: "Models", note: "Compact generalist in isolated Cellpose 3 runtime." },
  { id: "model-stardist", area: "Detection", name: "StarDist versatile fluorescence", state: "ready", windowsSurface: "Models", note: "Exact 2D_versatile_fluo checkpoint in isolated TensorFlow runtime." },
  { id: "detection-batch", area: "Detection", name: "Batch detection and live progress", state: "ready", windowsSurface: "Processing", note: "Persistent Cellpose workers and cancellable StarDist one-shot runs." },
  { id: "detection-cancel", area: "Detection", name: "Cancellation and orphan cleanup", state: "adapted", windowsSurface: "Processing", note: "TerminateProcess via Tokio and scoped process sweep on Windows." },
  { id: "detection-preprocess", area: "Detection", name: "Preprocessing, channels and compute device", state: "adapted", windowsSurface: "Settings", note: "Background, channel and projection settings are available; Windows uses CPU-only runtimes. Selected-plane preparation and source preview are separate capabilities." },
  { id: "detection-watershed", area: "Detection", name: "Touching-cell watershed split", state: "ready", windowsSurface: "Settings / Results", note: "Calibration-aware minimum distance." },
  { id: "detection-provenance", area: "Detection", name: "Exact detector identity and failure reporting", state: "ready", windowsSurface: "Models / Results", note: "Closed model allowlist; unknown IDs fail without substitution." },

  { id: "analysis-measure", area: "Analysis", name: "Cell morphology and intensity measurements", state: "ready", windowsSurface: "Results", note: "Diameter, area, perimeter, shape, intensity and QC flags." },
  { id: "analysis-bins", area: "Analysis", name: "Configurable size bins and histograms", state: "ready", windowsSurface: "Results / Settings", note: "Consistent colors and source-unit conversion." },
  { id: "analysis-qc", area: "Analysis", name: "Focus and illumination QC", state: "ready", windowsSurface: "Results", note: "Computed during detection and shown as badges." },
  { id: "analysis-colony", area: "Analysis", name: "Colony and confluency statistics", state: "ready", windowsSurface: "Results", note: "Uses the shared colony implementation." },
  { id: "analysis-intensity", area: "Analysis", name: "Multi-channel intensity assays", state: "ready", windowsSurface: "Results → Advanced assays", note: "Marker-positive, N:C, colocalization, viability, transfection, and cell-cycle modes run locally against reconstructed cell masks." },
  { id: "analysis-area", area: "Analysis", name: "Scratch, spheroid and colony-area assays", state: "ready", windowsSurface: "Results → Advanced assays", note: "Confluence, ordered wound series, and spheroid analysis use the portable Python kernels." },
  { id: "analysis-puncta", area: "Analysis", name: "Puncta and foci analysis", state: "ready", windowsSurface: "Results → Advanced assays", note: "Local channel-selectable LoG/DoG workflow assigns foci to measured cell polygons." },
  { id: "analysis-spatial", area: "Analysis", name: "Spatial statistics", state: "adapted", windowsSurface: "Results", note: "Exact nearest-neighbour, local density and Clark–Evans statistics run in the portable TypeScript kernel." },
  { id: "analysis-tracking", area: "Analysis", name: "Sequence tracking and migration", state: "ready", windowsSurface: "Results → Advanced assays", note: "Ordered batch detections use calibrated Hungarian linking with frame interval and displacement controls." },
  { id: "analysis-neurite", area: "Analysis", name: "Neurite outgrowth", state: "ready", windowsSurface: "Results → Advanced assays", note: "User-selected neurite masks are skeletonized and attributed to detected soma centroids." },
  { id: "analysis-line-profile", area: "Analysis", name: "Line profile tool", state: "ready", windowsSurface: "Results", note: "Interactive source-pixel endpoints use calibrated bilinear RGB/luma sampling with bounded output." },

  { id: "edit-overlay", area: "Editing", name: "Mask fills, contours, boxes and markers", state: "ready", windowsSurface: "Results", note: "Canvas renderer uses source-pixel transforms." },
  { id: "edit-cells", area: "Editing", name: "Add, remove, resize, merge and split", state: "ready", windowsSurface: "Results", note: "Undo/redo and correction log included." },
  { id: "edit-ground-truth", area: "Editing", name: "Ground truth and live precision/recall/F1", state: "ready", windowsSurface: "Results", note: "Annotations persist in SQLite." },
  { id: "edit-roi", area: "Editing", name: "Include and exclude ROIs", state: "ready", windowsSurface: "Results", note: "All filters operate in source-pixel coordinates." },
  { id: "edit-notes", area: "Editing", name: "Notes and per-image confidence", state: "ready", windowsSurface: "Results", note: "Saved without deleting filtered cells." },

  { id: "workflow-library", area: "Workflow", name: "Image library and duplicate groups", state: "ready", windowsSurface: "Images", note: "Virtualized local library." },
  { id: "workflow-batches", area: "Workflow", name: "Batch summaries and conditions", state: "ready", windowsSurface: "Batches", note: "Aggregate counts and size distributions." },
  { id: "workflow-review", area: "Workflow", name: "Low-confidence review queue", state: "ready", windowsSurface: "Queue", note: "Keyboard accept/reject/resize workflow." },
  { id: "workflow-compare", area: "Workflow", name: "Condition comparison and Mann–Whitney U", state: "ready", windowsSurface: "Compare", note: "Pooled histograms, effect size and CSV." },
  { id: "workflow-protocol", area: "Workflow", name: "Analysis protocol save/apply", state: "ready", windowsSurface: "Settings → Analysis protocols", note: "Versioned .ccproto.json files capture, validate, preview, and atomically apply the complete analysis setup." },
  { id: "workflow-finetune", area: "Workflow", name: "Fine-tuning and checkpoint lineage", state: "ready", windowsSurface: "Fine-tune", note: "Local cyto3 image/mask-pair training requires three specimen groups, rejects duplicate sources, measures held-out quality and activates confined checkpoints. Native reviewed-library dataset creation is listed separately." },

  { id: "export-cells", area: "Export", name: "Cells and batch CSV", state: "ready", windowsSurface: "Export", note: "Native save dialog and deterministic columns." },
  { id: "export-roi", area: "Export", name: "ImageJ ROI ZIP", state: "ready", windowsSurface: "Export", note: "Runs through a local helper environment." },
  { id: "export-segnpy", area: "Export", name: "Cellpose _seg.npy round-trip", state: "ready", windowsSurface: "Results", note: "Corrected contours can round-trip with the Cellpose GUI." },
  { id: "export-provenance", area: "Export", name: "Reproducibility provenance", state: "ready", windowsSurface: "Export", note: "Model, calibration, thresholds and run metadata." },
  { id: "export-pdf", area: "Export", name: "PDF lab report", state: "ready", windowsSurface: "Export", note: "Generated locally by the Rust backend." },
  { id: "export-overlay", area: "Export", name: "Annotated PNG and mirrored folder export", state: "ready", windowsSurface: "Export", note: "Full-resolution single-image output and collision-safe whole-batch folders honor confidence and the active outline/box mode." },
  { id: "export-geojson", area: "Export", name: "GeoJSON contours", state: "ready", windowsSurface: "Export", note: "RFC 7946 polygons retain measured-versus-approximated contour provenance and source-pixel coordinates." },

  { id: "system-storage", area: "System", name: "Local-only storage and reset", state: "ready", windowsSurface: "Settings", note: "Images, SQLite, models and exports remain on this computer." },
  { id: "system-accessibility", area: "System", name: "Keyboard and accessible interaction", state: "adapted", windowsSurface: "Application-wide", note: "ARIA labels, focus traps, native window controls and Windows-friendly shortcuts." },
  { id: "system-support", area: "System", name: "Support and parity disclosure", state: "ready", windowsSurface: "Support", note: "This live inventory prevents silent platform omissions." },
  { id: "workflow-inspect", area: "Workflow", name: "Import, inspect and preview before processing", state: "adapted", windowsSurface: "Processing", note: "Import creates a saved setup without requiring a model. Preview processes a representative image; the viewer shows the imported display image." },
  { id: "workflow-recovery", area: "Workflow", name: "Saved jobs, pause, resume and retry", state: "ready", windowsSurface: "Processing", note: "SQLite-backed settings and per-image status survive restart. Completed matching previews are reused; interrupted work reopens paused." },
  { id: "analysis-linked", area: "Analysis", name: "Linked measurements and scatter selection", state: "ready", windowsSurface: "Results → Measurements", note: "Paged measurements and a sampled scatter plot share selected cell IDs with the viewer; selection operates across all measured cells." },
  { id: "edit-variants", area: "Editing", name: "Saved mask comparison and restoration", state: "ready", windowsSurface: "Results → Mask versions", note: "Saved masks compare at synchronized pan/zoom. Restoration preserves the current mask and separates recorded run settings from review settings." },
  { id: "input-source-selection", area: "Input", name: "Explicit source channel and Z projection", state: "adapted", windowsSurface: "Processing → Setup", note: "Detection can use a selected original channel and max/mean/sum/middle projection. The import display preview is not a preview of every selected source plane." },
  { id: "input-selected-preview", area: "Input", name: "Exact selected source-plane preview", state: "pending", windowsSurface: "macOS Analysis setup", note: "Windows detection routing preserves source selection, but the setup display still uses the imported preview. Exact channel/plane display needs a separate preparation path." },
  { id: "model-native-extras", area: "Detection", name: "Additional native model catalog entries", state: "pending", windowsSurface: "macOS Models", note: "Nuclei, cyto2, restoration and other StarDist variants are not in the three-model Windows release. Each requires exact runtime/input validation; no substitute is advertised." },
  { id: "workspace-omezarr", area: "Input", name: "OME-Zarr multiscale and chunk loading", state: "pending", windowsSurface: "macOS Workspace", note: "Windows import has no equivalent local OME-Zarr workspace reader or bounded multiscale chunk viewer. Use the macOS workspace for this workflow." },
  { id: "workspace-navigation", area: "Workflow", name: "Layered multidimensional workspace", state: "pending", windowsSurface: "macOS Workspace", note: "Windows image batches do not yet implement native layers, dimension navigation, plate/field structure or workspace document editing." },
  { id: "workspace-registration", area: "Analysis", name: "Layer transforms, registration and stitching", state: "pending", windowsSurface: "macOS Workspace", note: "Registration and stitched workspace layers remain native-only; ordinary image import is not an equivalent transform workflow." },
  { id: "workspace-animation", area: "Export", name: "Workspace animation export", state: "pending", windowsSurface: "macOS Workspace", note: "Windows has no equivalent workspace keyframe and rendered animation export workflow." },
  { id: "workspace-replay", area: "Workflow", name: "Recorded workspace workflow replay", state: "pending", windowsSurface: "macOS Workspace", note: "Analysis setup protocols are available, but replayable layer operation sequences are not implemented on Windows." },
  { id: "workspace-lineage", area: "Workflow", name: "Workspace object lineage graph", state: "pending", windowsSurface: "macOS Workspace", note: "Checkpoint names and batch tracking do not implement the native workspace lineage graph and editing workflow." },
  { id: "workspace-paint", area: "Editing", name: "Pixel-class painting and label export", state: "pending", windowsSurface: "macOS Workspace", note: "Windows cell contour correction does not provide native pixel-class paint documents, brush classes or workspace training-label export." },
  { id: "analysis-prompt", area: "Editing", name: "Prompt-based mask refinement", state: "pending", windowsSurface: "macOS Results", note: "Point/box prompt refinement remains native-only; Windows add/remove/merge/split are direct geometry edits." },
  { id: "analysis-propagation", area: "Analysis", name: "Mask propagation and acquisition drift", state: "pending", windowsSurface: "macOS Results", note: "Windows supports ordered tracking, but native mask propagation and acquisition-drift correction are not yet exposed." },
  { id: "analysis-preprocess-extra", area: "Analysis", name: "Advanced preprocessing and optimizer", state: "pending", windowsSurface: "macOS Results", note: "Background subtraction and watershed do not cover the native preprocessing preset and optimizer workflows." },
  { id: "analysis-curation-grid", area: "Editing", name: "Bulk grid curation", state: "pending", windowsSurface: "macOS Results", note: "The Windows review queue handles one candidate at a time; native multi-candidate grid curation is a separate unported workflow." },
  { id: "workflow-reviewed-training", area: "Workflow", name: "Immutable reviewed-library training datasets", state: "pending", windowsSurface: "macOS Fine-tune", note: "Windows trains explicit image/mask pairs with specimen-isolated groups. Native reviewed-library snapshots, dataset manifests and rollback controls remain separate work." },
  { id: "analysis-channel-measurements", area: "Analysis", name: "Source channel stack and per-cell channels", state: "pending", windowsSurface: "macOS Results", note: "Existing multi-channel assays are available; the native source-channel stack and linked per-cell channel inspection panel are not implemented." },

] as const;

export const WINDOWS_PARITY_CAPABILITIES: readonly WindowsParityCapability[] = INVENTORY.map(
  (capability) => ({ ...capability, evidence: EVIDENCE[capability.id] ?? [] }),
);

export function parityCounts() {
  return WINDOWS_PARITY_CAPABILITIES.reduce(
    (counts, capability) => {
      counts[capability.state] += 1;
      return counts;
    },
    { ready: 0, adapted: 0, pending: 0 },
  );
}
