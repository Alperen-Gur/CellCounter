/**
 * pages/home/importFlow.ts — the import + detect orchestration (feat-home-import).
 *
 * Direct port of `Shared/AppState.swift` → `importAndAnalyze` / `proceedWithImport`
 * (the real drop flow of the macOS app). Pure orchestration over the two frozen
 * ports + the store — no React, so it stays testable and the HomePage component
 * only wires gestures to it.
 *
 * The pipeline for a drop / pick of N files:
 *   1. filter to supported extensions
 *   2. availability gate — if the active model isn't runnable, surface the error
 *      and abort (no batch is created)
 *   3. import each file via `import_image` (Rust: decode + whole-file SHA-256 +
 *      thumbnail + EXIF probe). Import is what produces `fileHash`.
 *   4. dedup check — for each freshly-imported image, ask the store whether an
 *      *earlier* record shares its hash (`imageMatchingHash(hash, name,
 *      excludingId=newId)`). Any hit becomes a DuplicateCandidate; the caller
 *      decides Skip / Import-anyway before the batch is finalized.
 *   5. create the batch (`createBatch`), attach the kept images, run `detect()`
 *      per image with progress into the ProcessingSlice, and `saveDetection`.
 *   6. navigate to /results (or back to / if nothing imported), cleaning up an
 *      empty batch.
 *
 * Coordinate space is irrelevant here — this module never touches geometry; it
 * only shuttles DTOs between the ports.
 *
 * Boundaries (docs/tasks.json feat-home-import):
 *   - owns pages/home/ only; routes by the store + the shell's `navigate`.
 *   - does NOT render the Processing screen (feat-processing) — it only drives
 *     ProcessingSlice (progress / stageLine / device) that Processing reads.
 */

import { getPort } from "../../kernel/persistence";
import type { ImportResult } from "../../kernel/persistence";
import { getTransport } from "../../kernel/transport";
import {
  isDetectionError,
  type DetectionParams,
  type DetectionProgress,
} from "../../kernel/transport";
import type { AppStore } from "../../kernel/store/store";
import type { ImageDTO, CalibrationDTO } from "../../kernel/types";

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
    useGpu: store.useGpu,
  };
}

/**
 * The persisted `detectorId` for a run (DTO comment: "cellpose/cp-cyto3").
 * Mirrors `"\(type(of: svc))/\(modelId)"` in Swift — our single desktop
 * transport is the cellpose sidecar.
 */
export function detectorIdFor(modelId: string): string {
  return `cellpose/${modelId}`;
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
export function batchDisplayName(imageNames: string[]): string {
  if (imageNames.length === 1) {
    const name = imageNames[0];
    const dot = name.lastIndexOf(".");
    return dot > 0 ? name.slice(0, dot) : name;
  }
  return `Batch · ${imageNames.length} images · ${shortDateStamp()}`;
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

let activeController: AbortController | null = null;

/**
 * Abort the in-flight import/detect run, if any. The Processing screen's Cancel
 * routes here (see kernelGaps: the transport-generated runId is not surfaced, so
 * an AbortController is the cross-page cancel primitive). Aborting makes each
 * pending `detect()` reject with `{ kind: "cancelled" }`, which the flow
 * swallows exactly like the Swift host.
 */
export function abortActiveImport(): void {
  activeController?.abort();
}

/** Is an import/detect run currently in flight? */
export function isImporting(): boolean {
  return activeController !== null;
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
 * imported / the run was aborted / the model was unavailable.
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
  const transport = getTransport();

  const supported = filterSupportedPaths(paths);
  if (supported.length === 0) return null;

  const s0 = storeAccess.getState();

  // --- availability gate (mirror the detectorRegistry.detector guard) --------
  try {
    const avail = await transport.availability(s0.activeModelId);
    if (!avail.installed) {
      s0.setDetectionError(
        avail.reason ??
          `The model "${s0.activeModelId}" isn't installed. Open Models to install it.`,
      );
      return null;
    }
  } catch (err) {
    // If the probe itself fails, treat as not-runnable rather than silently
    // stranding the user in an empty Results screen.
    s0.setDetectionError(
      err instanceof Error
        ? err.message
        : "Couldn't check whether the model is installed.",
    );
    return null;
  }

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
 * Create the batch, attach the kept images, run detection per image with
 * progress into the store, save each detection, then navigate. Mirrors the
 * second half of `proceedWithImport`.
 */
async function runDetection(
  keep: PreparedImage[],
  condition: string | undefined,
  batchCalibration: CalibrationDTO | null,
  hooks: ImportFlowHooks,
  storeAccess: StoreAccess,
): Promise<string | null> {
  const port = getPort();
  const transport = getTransport();
  const store = storeAccess.getState();

  const names = keep.map((p) => p.image.fileName);
  const displayName = batchDisplayName(names);

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

  // Enter the processing view with a clean slate.
  store.openBatch(batch.id);
  store.resetProcessing();
  store.setDetectionError(undefined);
  if (batchCalibration) {
    store.setCalibrationNote(
      `Calibrated from image metadata: ${batchCalibration.pxPerUm.toFixed(2)} px/µm.`,
    );
  }
  hooks.navigate("processing");

  // Detection params snapshot — matches the batch's calibration, not
  // necessarily the live global (so a mid-run slider change can't skew it).
  const params: DetectionParams = {
    ...detectionParamsFromStore(store),
    pxPerUm: batchPxPerUm,
  };
  const detectorId = detectorIdFor(store.activeModelId);

  const controller = new AbortController();
  activeController = controller;

  const total = keep.length;
  let finished = 0;
  let anyImported = false;
  let lastError: string | undefined;
  let cancelled = false;

  const onProgress = (p: DetectionProgress) => {
    const st = storeAccess.getState();
    switch (p.kind) {
      case "stage":
        st.setStageLine(p.line);
        break;
      case "device":
        st.setDevice(p.device);
        break;
      case "weights":
        // Surfaced as a stage line so the Processing screen shows download
        // progress for the future SAM weights without a new slice field.
        st.setStageLine(
          `Downloading weights… ${Math.round(p.doneMB)}/${Math.round(p.totalMB)} MB`,
        );
        break;
    }
  };

  // Concurrency mirrors Settings → maxParallel (default 1 — CPU cellpose is
  // CPU-bound). A tiny worker pool over the kept images.
  const parallelism = Math.max(1, store.maxParallel);

  const queue = [...keep];
  const runOne = async (prep: PreparedImage): Promise<void> => {
    // Attach happens regardless of detection outcome (Swift attaches on import
    // success, then records the detection result separately).
    try {
      await port.attachImageToBatch(prep.image.id, batch.id);
      anyImported = true;
    } catch (err) {
      lastError = err instanceof Error ? err.message : String(err);
    }

    try {
      const result = await transport.detect(
        prep.image.storedPath,
        params,
        onProgress,
        controller.signal,
      );
      await port.saveDetection(
        prep.image.id,
        detectorId,
        result.cells,
        result.imageStats,
      );
    } catch (err) {
      // User-initiated cancels are swallowed (Swift Pass-13). Everything else
      // is remembered and surfaced after the batch settles.
      if (isDetectionError(err) && err.detail.kind === "cancelled") {
        cancelled = true;
      } else {
        lastError = isDetectionError(err) ? err.message : String(err);
      }
    }

    finished += 1;
    storeAccess.getState().setProgress(finished / total);
    // Live-refresh sidebar counts / recents / review badge as each finishes.
    void storeAccess.getState().refreshLibraryStats();
  };

  const worker = async (): Promise<void> => {
    for (;;) {
      if (controller.signal.aborted) return;
      const next = queue.shift();
      if (!next) return;
      await runOne(next);
    }
  };

  const workers = Array.from({ length: Math.min(parallelism, total) }, () =>
    worker(),
  );
  await Promise.all(workers);

  activeController = null;

  if (lastError) {
    storeAccess.getState().setDetectionError(lastError);
  }

  // Route: to Results when at least one image imported, else back Home.
  if (anyImported && !(cancelled && finished === 0)) {
    hooks.navigate("results");
  } else {
    hooks.navigate("home");
  }

  // Never leave an empty batch behind (every import failed / all cancelled
  // before attach). Mirrors the Swift empty-batch cleanup. NOTE: the frozen
  // store exposes no nil-setter for `currentBatchId` (openBatch always sets a
  // value), so a deleted batch id may briefly remain the "current" one — but
  // we always navigate Home in this branch, so Results never renders it. See
  // kernelGaps: a `clearBatch()`/nullable openBatch would tidy this.
  try {
    const fresh = await port.batch(batch.id);
    if (!fresh || fresh.imageIds.length === 0) {
      await port.deleteBatch(batch.id);
    }
  } catch {
    /* cleanup is best-effort */
  }
  await storeAccess.getState().refreshLibraryStats();

  return anyImported ? batch.id : null;
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
