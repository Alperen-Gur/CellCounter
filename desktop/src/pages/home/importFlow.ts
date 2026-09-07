/**
 * Import source images, resolve duplicates, and create a saved analysis setup.
 * Model readiness is checked when the user previews or processes the job.
 * Import and inspection do not start inference or overwrite prior detections.
 */

import { getPort } from "../../kernel/persistence";
import type { ImportResult } from "../../kernel/persistence";
import { analysisQueue } from "../../kernel/workflow/desktopQueue";
import type { DetectionParams } from "../../kernel/transport";
import type { AppStore } from "../../kernel/store/store";
import type { ImageDTO, BatchDTO, CalibrationDTO } from "../../kernel/types";

// ---------------------------------------------------------------------------
// Supported inputs (mirror ImageLoader.supported)
// ---------------------------------------------------------------------------

/** Lowercased extensions the Rust importer decodes (ARCHITECTURE.md §3.8). */
export const SUPPORTED_EXTENSIONS = [
  "jpg",
  "jpeg",
  "png",
  "tif",
  "tiff",
  "bmp",
  // Recognized microscopy containers are intentionally allowed through the
  // UI filter so the Rust importer can return a precise, visible platform
  // status instead of silently dropping them.
  "nd2",
  "czi",
  "lif",
  "oir",
  "vsi",
] as const;

/** Lowercased extension of a path (no dot), or "" if none. */
function extensionOf(path: string): string {
  const base = path.split(/[\\/]/).pop() ?? path;
  const dot = base.lastIndexOf(".");
  if (dot <= 0 || dot === base.length - 1) return "";
  return base.slice(dot + 1).toLowerCase();
}

/** Keep only paths whose extension the importer can decode. */
export function filterSupportedPaths(paths: string[]): string[] {
  return paths.filter((p) =>
    (SUPPORTED_EXTENSIONS as readonly string[]).includes(extensionOf(p)),
  );
}

// ---------------------------------------------------------------------------
// Duplicate-session types (mirror DuplicateImportSheet.swift)
// ---------------------------------------------------------------------------

/**
 * One dropped file whose freshly-imported record matches an *existing* library
 * record by whole-file SHA-256. `imported` is the row `import_image` just wrote;
 * `existing` is the earlier record it collides with.
 */
export interface DuplicateCandidate {
  sourcePath: string;
  imported: ImageDTO;
  existing: ImageDTO;
}

/** How the user resolved a single duplicate (mirrors DuplicateDecision). */
export type DuplicateDecision = "skip" | "importAnyway";

/**
 * The full context of a drop that contained ≥1 duplicate. Held by HomePage
 * while the DuplicatePrompt is open; `resolve` is invoked once the user decides.
 */
export interface DuplicateSession {
  /** Every freshly-imported image from this drop (dupes + new). */
  imported: PreparedImage[];
  duplicates: DuplicateCandidate[];
  condition?: string;
  /** Batch calibration derived from EXIF (applied when all images agree). */
  calibration: CalibrationDTO | null;
}

/** An imported image plus the calibration `import_image` probed for it. */
export interface PreparedImage {
  image: ImageDTO;
  calibration: CalibrationDTO | null;
  sourcePath: string;
}

// ---------------------------------------------------------------------------
// Callbacks the UI supplies so this module stays free of routing/React.
// ---------------------------------------------------------------------------

export interface ImportFlowHooks {
  /** Navigate to a route ("processing" | "results" | "home"). */
  navigate: (id: "processing" | "results" | "home") => void;
  /**
   * A drop contained duplicates: pause and let the user decide. Resolves with
   * the per-candidate decisions (keyed by `imported.id`). Returning `null`
   * cancels the whole import (the freshly-imported rows are rolled back).
   */
  onDuplicates: (
    session: DuplicateSession,
  ) => Promise<Record<string, DuplicateDecision> | null>;
  /**
   * A per-file import failure occurred (unsupported/undecodable). Non-fatal —
   * the flow continues with the files that did import. Optional.
   */
  onImportError?: (sourcePath: string, message: string) => void;
}

// ---------------------------------------------------------------------------
// DetectionParams derivation (mirror the DetectionInput built in proceedWithImport)
// ---------------------------------------------------------------------------

/**
 * Build the frozen `DetectionParams` from the store's analysis slice. Mirrors
 * the `DetectionInput(...)` snapshot in `proceedWithImport`:
 *   - modelId ← activeModelId
 *   - confidenceThreshold ← confidence (analysis filter; never destructive)
 *   - small/largeThresholdUm ← thresholds.first / thresholds.last
 *   - expectedDiameterUm ← expectedDiameterUm (0 = Auto; >0 decouples segmentation from bins)
 */
export function detectionParamsFromStore(store: AppStore): DetectionParams {
  const smallThresholdUm = store.thresholds[0] ?? 20;
  const largeThresholdUm =
    store.thresholds.length > 0
      ? store.thresholds[store.thresholds.length - 1]
      : 30;
  return {
    modelId: store.activeModelId,
    pxPerUm: store.pxPerUm,
    confidenceThreshold: store.confidence,
    channels: store.channels,
    backgroundSubtract: store.backgroundSubtract,
    rollingBallRadius: store.rollingBallRadius,
    watershedSplit: store.watershedSplit,
    watershedMinDistanceUm: store.watershedMinDistanceUm,
    smallThresholdUm,
    largeThresholdUm,
    expectedDiameterUm: store.expectedDiameterUm,
    useGpu: store.useGpu,
  };
}

/**
 * The persisted `detectorId` for a run (DTO comment: "cellpose/cp-cyto3").
 * The family prefix identifies the actual selected model family.
 */
export function detectorIdFor(modelId: string): string {
  return `${modelId.startsWith("sd-") ? "stardist" : "cellpose"}/${modelId}`;
}

// ---------------------------------------------------------------------------
// Display name (mirror proceedWithImport)
// ---------------------------------------------------------------------------

/** "MMM d, HH:mm"-ish short stamp used in multi-image batch names. */
function shortDateStamp(d = new Date()): string {
  const months = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
  ];
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  return `${months[d.getMonth()]} ${d.getDate()}, ${hh}:${mm}`;
}

/** Batch display name: single image → its base name; else "Batch · N images · <date>". */
export function batchDisplayName(imageNames: string[], sourcePaths?: string[]): string {
  if (imageNames.length === 1) {
    const name = imageNames[0];
    const dot = name.lastIndexOf(".");
    return dot > 0 ? name.slice(0, dot) : name;
  }
  const folder = sourcePaths ? commonFolderName(sourcePaths) : null;
  if (folder) return folder;
  return `Batch · ${imageNames.length} images · ${shortDateStamp()}`;
}

/**
 * Shared parent-folder name of a set of source paths, or null when they don't
 * share one. Handles both `/` and `\` separators so a Windows import is titled
 * by its folder too.
 */
function commonFolderName(paths: string[]): string | null {
  if (paths.length === 0) return null;
  const dirs = paths.map((p) => {
    const norm = p.replace(/\\/g, "/");
    const slash = norm.lastIndexOf("/");
    return slash >= 0 ? norm.slice(0, slash) : "";
  });
  let common = dirs[0];
  for (let i = 1; i < dirs.length && common; i++) {
    const d = dirs[i];
    while (common && d !== common && !d.startsWith(common + "/")) {
      const slash = common.lastIndexOf("/");
      common = slash >= 0 ? common.slice(0, slash) : "";
    }
  }
  if (!common) return null;
  const seg = common.slice(common.lastIndexOf("/") + 1);
  return seg || null;
}

// ---------------------------------------------------------------------------
// EXIF batch calibration (mirror proceedWithImport Lane C)
// ---------------------------------------------------------------------------

/**
 * When every imported image reports the SAME EXIF px/µm (within 0.1%) and that
 * differs from the current global by > 5%, that value calibrates the batch.
 * Mirrors the Swift Lane-C logic. Returns null when no agreement / no change.
 */
export function batchCalibrationFrom(
  prepared: PreparedImage[],
  globalPxPerUm: number,
): CalibrationDTO | null {
  const cals = prepared
    .map((p) => p.calibration)
    .filter((c): c is CalibrationDTO => c != null && c.pxPerUm > 0);
  if (cals.length === 0 || cals.length !== prepared.length) return null;
  const first = cals[0].pxPerUm;
  const allSame = cals.every((c) => Math.abs(c.pxPerUm - first) / first < 0.001);
  if (!allSame) return null;
  const diffFraction = Math.abs(first - globalPxPerUm) / Math.max(globalPxPerUm, 0.001);
  if (diffFraction <= 0.05) return null;
  return cals[0];
}

// ---------------------------------------------------------------------------
// The active run — a shared cancel handle for the Processing screen's seam.
// ---------------------------------------------------------------------------



/**
 * Abort the in-flight import/detect run, if any. The Processing screen's Cancel
 * routes here (see kernelGaps: the transport-generated runId is not surfaced, so
 * an AbortController is the cross-page cancel primitive). Aborting makes each
 * pending `detect()` reject with `{ kind: "cancelled" }`, which the flow
 * swallows exactly like the Swift host.
 */
export function abortActiveImport(): void {
  const active = analysisQueue.getSnapshot().find(job => job.status === "running");
  if (active) analysisQueue.cancel(active.id);
}

/** Is an import/detect run currently in flight? */
export function isImporting(): boolean {
  return false; // Import and inspection remain available while a saved job runs.
}

// ---------------------------------------------------------------------------
// Store adapter — the subset of the frozen store this flow reads/writes.
// ---------------------------------------------------------------------------

/**
 * The store setters/getters used by the flow. HomePage passes
 * `useAppStore.getState` so we always read live values (params can change mid
 * session) and write processing/session/error state through the frozen setters.
 */
export interface StoreAccess {
  getState(): AppStore;
}

// ---------------------------------------------------------------------------
// The orchestrator
// ---------------------------------------------------------------------------

/**
 * The real drop flow. Returns the created batch id, or null if nothing was
 * imported / duplicate review was cancelled.
 *
 * Mirrors `AppState.importAndAnalyze` + `proceedWithImport`, adapted to the port
 * boundary: because `import_image` (Rust) is what computes the SHA-256, we
 * import first, then dedup against *earlier* records via `excludingId`. Skipped
 * duplicates have their just-imported row deleted so no phantom data persists.
 */
export async function importAndAnalyze(
  paths: string[],
  hooks: ImportFlowHooks,
  storeAccess: StoreAccess,
  condition?: string,
): Promise<string | null> {
  const port = getPort();

  const supported = filterSupportedPaths(paths);
  if (supported.length === 0) return null;

  const s0 = storeAccess.getState();

  // Images can be inspected before installing a detector. Model readiness is
  // checked only when the saved job is actually previewed or processed.

  // --- import every file (this is what produces fileHash) --------------------
  const prepared: PreparedImage[] = [];
  for (const sourcePath of supported) {
    try {
      const res = await importOne(sourcePath);
      prepared.push({
        image: res.image,
        calibration: res.calibration,
        sourcePath,
      });
    } catch (err) {
      const message =
        err instanceof Error ? err.message : String(err ?? "Import failed.");
      hooks.onImportError?.(sourcePath, message);
    }
  }
  if (prepared.length === 0) {
    // Everything failed to import.
    s0.setDetectionError("None of the selected files could be imported.");
    return null;
  }

  // --- dedup check against EARLIER records -----------------------------------
  // Because `import_image` (Rust) is what computes the SHA-256, every dropped
  // file is already a row by now — including this drop's own siblings. A match
  // therefore only counts as a "duplicate" when it points at a record that is
  // NOT part of this very drop; two identical files dropped together must not
  // flag each other. `imageMatchingHash`'s single `excludingId` can't exclude
  // the whole batch, so we additionally filter matches against `freshIds`.
  const freshIds = new Set(prepared.map((p) => p.image.id));
  const duplicates: DuplicateCandidate[] = [];
  for (const p of prepared) {
    const hash = p.image.fileHash;
    if (!hash) continue;
    const existing = await port.imageMatchingHash(
      hash,
      p.image.fileName,
      p.image.id, // exclude the row we just created
    );
    if (existing && !freshIds.has(existing.id)) {
      duplicates.push({
        sourcePath: p.sourcePath,
        imported: p.image,
        existing,
      });
    }
  }

  const batchCalibration = batchCalibrationFrom(prepared, s0.pxPerUm);

  // Decide which imported rows to keep. Default (no duplicates) keeps all.
  let keep: PreparedImage[] = prepared;
  if (duplicates.length > 0) {
    const decisions = await hooks.onDuplicates({
      imported: prepared,
      duplicates,
      condition,
      calibration: batchCalibration,
    });
    if (decisions === null) {
      // User cancelled the whole import — roll back every freshly-imported row.
      await rollback(prepared.map((p) => p.image.id));
      return null;
    }
    const dupIds = new Set(duplicates.map((d) => d.imported.id));
    const toDelete: string[] = [];
    keep = prepared.filter((p) => {
      if (!dupIds.has(p.image.id)) return true; // non-duplicate: always keep
      const decision = decisions[p.image.id] ?? "skip";
      if (decision === "importAnyway") return true;
      toDelete.push(p.image.id); // skipped duplicate: drop the new row
      return false;
    });
    await rollback(toDelete);
  }

  if (keep.length === 0) {
    // Every file was a skipped duplicate. Route the user to the existing
    // batch of the first collision so the drop still "does something".
    const firstExistingId = duplicates[0]?.existing.id;
    if (firstExistingId) {
      await openBatchOfImage(firstExistingId, storeAccess, hooks);
    }
    await port.cleanupEmptyBatches();
    return null;
  }

  return runDetection(keep, condition, batchCalibration, hooks, storeAccess);
}

/**
 * Create the batch, attach the kept images and save a draft analysis job.
 * The Processing screen lets the user inspect and preview before inference.
 */
async function runDetection(
  keep: PreparedImage[],
  condition: string | undefined,
  batchCalibration: CalibrationDTO | null,
  hooks: ImportFlowHooks,
  storeAccess: StoreAccess,
): Promise<string | null> {
  const port = getPort();
  const store = storeAccess.getState();

  const names = keep.map((p) => p.image.fileName);
  const displayName = batchDisplayName(names, keep.map((p) => p.sourcePath));

  // Batch px/µm: an agreeing EXIF calibration overrides the global for this
  // batch only (Swift Lane C); the global store.pxPerUm is untouched.
  const batchPxPerUm = batchCalibration?.pxPerUm ?? store.pxPerUm;

  const batch = await port.createBatch({
    displayName,
    modelId: store.activeModelId,
    pxPerUm: batchPxPerUm,
    thresholds: store.thresholds,
    condition,
  });

  const params: DetectionParams = { ...detectionParamsFromStore(store), pxPerUm: batchPxPerUm };
  for (const prepared of keep) await port.attachImageToBatch(prepared.image.id, batch.id);
  await analysisQueue.create({
    batchId: batch.id, name: batch.displayName, task: "countCells",
    calibrationSource: batchCalibration?.source ?? "manual", params,
    items: keep.map(prepared => ({ imageId: prepared.image.id, fileName: prepared.image.fileName,
      path: prepared.image.analysisPath ?? prepared.image.storedPath, status: "pending" as const })),
  });
  store.openBatch(batch.id);
  store.setDetectionError(undefined);
  await store.refreshLibraryStats();
  hooks.navigate("processing");
  return batch.id;
}

// ---------------------------------------------------------------------------
// Re-run detection on a single, already-imported image
// ---------------------------------------------------------------------------

/** Create a fresh saved setup for an existing image, preserving its previous
 * result until the user explicitly processes the new job. Batch calibration is
 * retained; other initial parameters come from the current application setup.
 */
export async function rerunDetection(
  image: ImageDTO,
  batch: BatchDTO,
  hooks: ImportFlowHooks,
  storeAccess: StoreAccess,
): Promise<void> {
  const store = storeAccess.getState();
  await analysisQueue.create({ batchId: batch.id, name: image.fileName, task: "countCells",
    calibrationSource: batch.pxPerUmSource ?? "manual",
    params: { ...detectionParamsFromStore(store), pxPerUm: batch.pxPerUm },
    items: [{ imageId: image.id, fileName: image.fileName, path: image.analysisPath ?? image.storedPath, status: "pending" }],
  });
  hooks.navigate("processing");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Import one file via the `import_image` command (decode + whole-file SHA-256 +
 * thumbnail + EXIF probe). NOTE: `import_image` is intentionally NOT on the
 * frozen `PersistencePort` (it needs raw bytes and returns a calibration — see
 * ARCHITECTURE.md §3.8), so the desktop `TauriSqlitePort` exposes it as an extra
 * `importImage` method. We reach it structurally and record the seam in
 * kernelGaps; the future browser build supplies its own importer.
 */
async function importOne(sourcePath: string): Promise<ImportResult> {
  const port = getPort() as unknown as {
    importImage?: (p: string) => Promise<ImportResult>;
  };
  if (typeof port.importImage !== "function") {
    throw new Error(
      "This build's persistence port does not provide image import.",
    );
  }
  return port.importImage(sourcePath);
}

/** Delete a set of freshly-imported image rows (skipped dupes / cancelled import). */
async function rollback(imageIds: string[]): Promise<void> {
  const port = getPort();
  await Promise.all(
    imageIds.map((id) =>
      port.deleteImage(id).catch(() => {
        /* best-effort rollback */
      }),
    ),
  );
}

/**
 * Open the batch that owns `imageId` and focus that image, then route to
 * Results. Used when the user skips a duplicate ("open existing analysis").
 */
async function openBatchOfImage(
  imageId: string,
  storeAccess: StoreAccess,
  hooks: ImportFlowHooks,
): Promise<void> {
  const port = getPort();
  const batches = await port.allBatches();
  const owner = batches.find((b) => b.imageIds.includes(imageId));
  if (!owner) return;
  const store = storeAccess.getState();
  store.openBatch(owner.id);
  const idx = owner.imageIds.indexOf(imageId);
  if (idx >= 0) store.setCurrentImageIdx(idx);
  hooks.navigate("results");
}
