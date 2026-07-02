/**
 * components/appInit.ts — launch-time app-data initialisation.
 *
 * Runs once when the shell mounts. It exercises BOTH backend init surfaces the
 * kernel exposes:
 *
 *   1. Persistence init — `refreshLibraryStats()` on the store reads the counts
 *      (images / batches / review queue) through the PersistencePort, which
 *      forces the Rust side to have opened `store.sqlite`. The DB itself is
 *      created/opened by the Rust `setup()` hook (db::repo::open_and_manage);
 *      this is the frontend's first read against that fresh store.
 *
 *   2. Environment init — `env_availability` probes whether the uv Python venv
 *      + cyto3 are installed, so the shell knows on launch whether detection can
 *      run. (No frontend `env_init` command exists — availability is the launch
 *      probe; the Models page drives the actual install.)
 *
 * Everything is defensive: in a plain `vite build` preview or the future browser
 * build there is no Tauri IPC, so failures are swallowed to a console warning
 * and the shell still renders. Guarded by a module-level flag so React 18/19
 * StrictMode's double-effect doesn't run it twice.
 */

import { useAppStore } from "../kernel/store/store";

/** Result of the launch-time environment probe (mirrors Rust `Availability`). */
export interface EnvAvailability {
  installed: boolean;
  reason?: string;
}

let started = false;

/** Is the app running inside a Tauri webview (vs. a plain browser preview)? */
function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/** Probe the Python/cyto3 environment. Returns null when IPC is unavailable. */
export async function probeEnvAvailability(): Promise<EnvAvailability | null> {
  if (!isTauri()) return null;
  try {
    // Imported lazily so the browser build never bundles the Tauri core eagerly.
    const { invoke } = await import("@tauri-apps/api/core");
    return await invoke<EnvAvailability>("env_availability");
  } catch (err) {
    console.warn("[appInit] env_availability probe failed:", err);
    return null;
  }
}

/**
 * Perform launch-time init exactly once. Safe to call from a mount effect under
 * StrictMode. Returns the resolved env availability (or null if unavailable).
 */
export async function initAppData(): Promise<EnvAvailability | null> {
  if (started) return null;
  started = true;

  // 1) Persistence init: first read against the freshly-opened store.sqlite.
  try {
    await useAppStore.getState().refreshLibraryStats();
  } catch (err) {
    console.warn("[appInit] refreshLibraryStats failed:", err);
  }

  // 2) Environment init: probe cyto3 availability for the launch state.
  const env = await probeEnvAvailability();
  if (env && !env.installed) {
    console.info(
      "[appInit] Python environment not ready:",
      env.reason ?? "unknown",
    );
  }
  return env;
}
