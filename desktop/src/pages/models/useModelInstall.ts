/**
 * pages/models/useModelInstall.ts — install + availability plumbing for the
 * Models tab. Owned by feature task `feat-models`.
 *
 * Thin React hook over the two kernel surfaces this feature is allowed to use:
 *
 *   • kernel-env (Rust `#[command]`s): `env_install` runs `uv sync` and streams
 *     each output line on the `env://install/log` Tauri event; `env_availability`
 *     reports whether the venv + cyto3 are importable. We do NOT re-implement the
 *     uv bootstrap here (that is kernel-env) — we only invoke it and render its
 *     progress.
 *   • kernel-transport (`InferenceTransport.availability`): the runnable check the
 *     Run flow gates on (`detection_availability` under the hood).
 *
 * All Tauri access is dynamically imported and guarded by `isTauri()` (mirrors
 * `components/appInit.ts`) so a plain `vite build` preview or the future browser
 * build never eagerly bundles `@tauri-apps` and never crashes when IPC is
 * absent. The `env://install/log` event name + `{ stream, line }` payload match
 * `INSTALL_LOG_EVENT` / `InstallLogLine` in `src-tauri/src/env/uv.rs`.
 */

import { useCallback, useEffect, useRef, useState } from "react";

import { getTransport } from "../../kernel/transport";

// ---------------------------------------------------------------------------
// Wire types (mirror Rust) + env constants
// ---------------------------------------------------------------------------

/** Tauri event the uv install log lines arrive on (mirrors `INSTALL_LOG_EVENT`). */
const INSTALL_LOG_EVENT = "env://install/log";

/** One streamed line of uv output (mirrors Rust `InstallLogLine`). */
interface InstallLogLine {
  stream: string; // "stdout" | "stderr"
  line: string;
}

/** Availability result (mirrors Rust `Availability` / transport availability). */
export interface Availability {
  installed: boolean;
  reason?: string;
}

/** Where an install currently stands, for the button + status label. */
export type InstallPhase = "idle" | "installing" | "done" | "error";

/** Is the app running inside a Tauri webview (vs. a plain browser preview)? */
function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

// ---------------------------------------------------------------------------
// Hook
// ---------------------------------------------------------------------------

export interface UseModelInstall {
  /** Latest availability probe result; null until the first probe resolves. */
  availability: Availability | null;
  /** Whether the `uv` toolchain itself is present (the install IS `uv sync`). */
  uv: Availability | null;
  /** True while an availability probe is in flight (initial or refresh). */
  probing: boolean;
  /** Install lifecycle phase. */
  phase: InstallPhase;
  /** Rolling log of streamed uv output lines (most recent last). */
  logLines: string[];
  /** Error message when `phase === "error"`, else undefined. */
  error?: string;
  /** Kick off `env_install`; streams progress into `logLines`, then re-probes. */
  install(): Promise<void>;
  /** Re-run the availability probe (env + transport) on demand. */
  refresh(): Promise<void>;
}

const MAX_LOG_LINES = 500;

/**
 * Drives the cyto3 install + availability lifecycle for the Models page.
 * `modelId` is the app-facing id whose runnability the transport is asked about
 * (defaults to the store's active model at the call site).
 */
export function useModelInstall(modelId: string): UseModelInstall {
  const [availability, setAvailability] = useState<Availability | null>(null);
  const [uv, setUv] = useState<Availability | null>(null);
  const [probing, setProbing] = useState(false);
  const [phase, setPhase] = useState<InstallPhase>("idle");
  const [logLines, setLogLines] = useState<string[]>([]);
  const [error, setError] = useState<string | undefined>(undefined);

  // Guards so a StrictMode double-mount / unmount doesn't setState after teardown.
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const appendLog = useCallback((line: string) => {
    if (!mountedRef.current) return;
    setLogLines((prev) => {
      const next = prev.length >= MAX_LOG_LINES ? prev.slice(1) : prev.slice();
      next.push(line);
      return next;
    });
  }, []);

  /**
   * Probe availability via BOTH surfaces the spec calls out and merge them:
   *  - env_availability (venv + `import cellpose`)
   *  - transport.availability(modelId) (the Run-flow gate; detection_availability)
   * The model is considered runnable only when both agree it is installed; the
   * first failure reason is surfaced.
   */
  const refresh = useCallback(async () => {
    if (!isTauri()) {
      // No IPC (browser preview): report a clear, non-crashing state.
      if (mountedRef.current) {
        setAvailability({
          installed: false,
          reason: "Detection is only available in the desktop app.",
        });
      }
      return;
    }
    if (mountedRef.current) setProbing(true);
    try {
      const { invoke } = await import("@tauri-apps/api/core");
      const [env, uvRes, transport] = await Promise.all([
        invoke<Availability>("env_availability").catch(
          (e): Availability => ({ installed: false, reason: String(e) }),
        ),
        invoke<Availability>("env_uv_available").catch(
          (e): Availability => ({ installed: false, reason: String(e) }),
        ),
        getTransport()
          .availability(modelId)
          .catch((e): Availability => ({ installed: false, reason: String(e) })),
      ]);
      const merged: Availability = {
        installed: env.installed && transport.installed,
        reason: !env.installed
          ? env.reason
          : !transport.installed
            ? transport.reason
            : undefined,
      };
      if (mountedRef.current) {
        setAvailability(merged);
        setUv(uvRes);
      }
    } finally {
      if (mountedRef.current) setProbing(false);
    }
  }, [modelId]);

  // Initial probe on mount.
  useEffect(() => {
    void refresh();
  }, [refresh]);

  const install = useCallback(async () => {
    if (!isTauri()) {
      setPhase("error");
      setError("Installation is only available in the desktop app.");
      return;
    }
    // Reset per-run state.
    setPhase("installing");
    setError(undefined);
    setLogLines([]);

    // Preflight: the whole install is `uv sync`, so a missing `uv` toolchain
    // would otherwise surface only as a raw spawn error. Probe it first and fail
    // with the actionable hint instead of a stack trace.
    try {
      const { invoke } = await import("@tauri-apps/api/core");
      const uvRes = await invoke<Availability>("env_uv_available").catch(
        (): Availability => ({ installed: false }),
      );
      if (!uvRes.installed) {
        if (mountedRef.current) {
          setUv(uvRes);
          setPhase("error");
          setError(
            uvRes.reason ??
              "The `uv` Python toolchain isn't installed. Install uv, then retry.",
          );
        }
        return;
      }
    } catch {
      /* if the probe itself throws, fall through and let env_install surface it */
    }

    let unlisten: (() => void) | undefined;
    try {
      const [{ invoke }, { listen }] = await Promise.all([
        import("@tauri-apps/api/core"),
        import("@tauri-apps/api/event"),
      ]);

      // Subscribe to the streamed uv log BEFORE invoking so no early line drops.
      unlisten = await listen<InstallLogLine>(INSTALL_LOG_EVENT, (event) => {
        appendLog(event.payload.line);
      });

      // `env_install` takes no args in this build (app handle is injected Rust-side).
      await invoke<void>("env_install");

      if (mountedRef.current) setPhase("done");
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      if (mountedRef.current) {
        setPhase("error");
        setError(message);
        appendLog(`error: ${message}`);
      }
    } finally {
      if (unlisten) unlisten();
      // Re-probe availability regardless of outcome so the UI reflects reality.
      await refresh();
    }
  }, [appendLog, refresh]);

  return { availability, uv, probing, phase, logLines, error, install, refresh };
}
