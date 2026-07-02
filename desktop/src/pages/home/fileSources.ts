/**
 * pages/home/fileSources.ts — how Home obtains file paths to import.
 *
 * Two sources, both yielding absolute filesystem paths the Rust `import_image`
 * command decodes:
 *
 *   1. Drag-and-drop — Tauri v2 delivers dropped paths through the webview's
 *      `onDragDropEvent` (no extra plugin needed). We expose a subscribe helper
 *      that reports enter/leave (for the drop-zone highlight) and drop paths.
 *
 *   2. "Choose images…" / "Choose folder…" — the native open panel. Tauri's
 *      file dialog lives in `@tauri-apps/plugin-dialog`, which is NOT part of
 *      the v1 dependency set (see kernelGaps). We therefore load it *lazily* and
 *      degrade gracefully: if it isn't present the picker returns `null` and the
 *      caller can fall back to drag-and-drop. When the plugin is later added,
 *      the buttons light up with no code change here.
 *
 * Folder handling: a chosen/dropped directory is walked (via the same dialog /
 * an `fs`-backed enumerate command when available) to collect supported images.
 * Extension filtering is deferred to `importFlow.filterSupportedPaths`.
 */

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

/** Is the app running inside a Tauri webview (vs. a plain browser preview)? */
export function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

// ---------------------------------------------------------------------------
// Drag & drop (webview onDragDropEvent)
// ---------------------------------------------------------------------------

export interface DropSubscriptionHandlers {
  /** Cursor entered the window with a drag payload — highlight the zone. */
  onEnter?: () => void;
  /** Cursor left / drop finished — clear the highlight. */
  onLeave?: () => void;
  /** Files were dropped. `paths` are absolute; may include directories. */
  onDrop: (paths: string[]) => void;
}

/**
 * Subscribe to native file drops. Returns an unsubscribe function. A no-op
 * (returns an empty unsubscribe) outside Tauri so the component still mounts in
 * a browser preview.
 */
export function subscribeFileDrop(
  handlers: DropSubscriptionHandlers,
): () => void {
  if (!isTauri()) return () => {};

  let unlisten: (() => void) | undefined;
  let disposed = false;

  void (async () => {
    try {
      const { getCurrentWebview } = await import("@tauri-apps/api/webview");
      const un = await getCurrentWebview().onDragDropEvent((event) => {
        const payload = event.payload as {
          type: string;
          paths?: string[];
        };
        switch (payload.type) {
          case "enter":
          case "over":
            handlers.onEnter?.();
            break;
          case "leave":
            handlers.onLeave?.();
            break;
          case "drop":
            handlers.onLeave?.();
            if (payload.paths && payload.paths.length > 0) {
              handlers.onDrop(payload.paths);
            }
            break;
          default:
            break;
        }
      });
      if (disposed) {
        un();
      } else {
        unlisten = un;
      }
    } catch (err) {
      console.warn("[home] file-drop subscription unavailable:", err);
    }
  })();

  return () => {
    disposed = true;
    unlisten?.();
  };
}

// ---------------------------------------------------------------------------
// Open panel ("Choose images…" / "Choose folder…") — lazy, degrades gracefully
// ---------------------------------------------------------------------------

/** Extensions offered in the native open panel filter. */
const IMAGE_EXT_FILTER = ["jpg", "jpeg", "png", "tif", "tiff", "bmp"];

/**
 * Shape of the dialog plugin's `open` we depend on. Declared locally so this
 * file type-checks even though `@tauri-apps/plugin-dialog` is not installed.
 */
interface DialogModule {
  open(options: {
    multiple?: boolean;
    directory?: boolean;
    title?: string;
    filters?: { name: string; extensions: string[] }[];
  }): Promise<string | string[] | null>;
}

/** Load the dialog plugin if present; null when it isn't part of the build. */
async function loadDialog(): Promise<DialogModule | null> {
  if (!isTauri()) return null;
  try {
    // LITERAL specifier so Vite bundles the plugin. (A variable specifier with
    // `@vite-ignore` leaves a bare `import()` that can't resolve at runtime —
    // that was the bug that left the picker buttons dead.) The dialog plugin is
    // a hard dependency of the app now.
    const mod = (await import("@tauri-apps/plugin-dialog")) as unknown as DialogModule;
    return typeof mod.open === "function" ? mod : null;
  } catch (err) {
    console.warn("[home] dialog plugin unavailable:", err);
    return null;
  }
}

/** Whether the native file picker is available in this build. */
export async function isPickerAvailable(): Promise<boolean> {
  return (await loadDialog()) !== null;
}

/**
 * Present the "Choose images…" panel. Returns the selected absolute paths, `[]`
 * if the user cancelled, or `null` if no picker is available (caller should
 * then hint the user to drag-and-drop).
 */
export async function chooseImages(): Promise<string[] | null> {
  const dialog = await loadDialog();
  if (!dialog) return null;
  const picked = await dialog.open({
    multiple: true,
    directory: false,
    title: "Choose images",
    filters: [{ name: "Images", extensions: IMAGE_EXT_FILTER }],
  });
  return normalizePicked(picked);
}

/**
 * Present the "Choose folder…" panel and enumerate the supported images inside
 * it. Returns the collected paths, `[]` on cancel, or `null` when no picker is
 * available.
 */
export async function chooseFolder(): Promise<string[] | null> {
  const dialog = await loadDialog();
  if (!dialog) return null;
  const picked = await dialog.open({
    multiple: false,
    directory: true,
    title: "Choose a folder of images",
  });
  const dirs = normalizePicked(picked);
  if (dirs.length === 0) return dirs; // user cancelled
  const collected: string[] = [];
  for (const dir of dirs) {
    collected.push(...(await enumerateImages(dir)));
  }
  return collected;
}

/** Normalise the dialog's `string | string[] | null` into a path array. */
function normalizePicked(picked: string | string[] | null): string[] {
  if (picked === null) return [];
  return Array.isArray(picked) ? picked : [picked];
}

/**
 * Recursively list supported image files under a directory. Uses the `fs`
 * plugin's `readDir` when present; returns `[]` if directory walking isn't
 * available (the importer still handles individually-picked files).
 */
async function enumerateImages(dir: string): Promise<string[]> {
  try {
    // Walk the chosen directory in Rust (reliable; not subject to the fs
    // plugin's path scoping). Returns absolute paths to supported images.
    const { invoke } = await import("@tauri-apps/api/core");
    return await invoke<string[]>("list_images_in_dir", { dir });
  } catch (err) {
    console.warn("[home] folder enumeration failed:", err);
    return [];
  }
}
