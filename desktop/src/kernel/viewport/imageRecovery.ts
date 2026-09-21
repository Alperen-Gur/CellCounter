/** Decode only Tauri asset URLs. The backend separately validates the exact
 * path against an existing library record before it creates a derivative. */
export function assetPath(src: string): string | null {
  try {
    const url = new URL(src);
    const isAsset = url.protocol === "asset:" && url.hostname === "localhost";
    const isWindowsAsset = (url.protocol === "http:" || url.protocol === "https:")
      && url.hostname === "asset.localhost";
    if (!isAsset && !isWindowsAsset) return null;
    return decodeURIComponent(url.pathname.slice(1));
  } catch { return null; }
}

const pending = new Map<string, Promise<string>>();

/** Coalesce the same failed image across Library, Results and review cards. */
export function recoverImageSource(src: string): Promise<string> {
  const path = assetPath(src);
  if (!path) return Promise.reject(new Error("The image preview could not be loaded."));
  const existing = pending.get(path);
  if (existing) return existing;
  const request = (async () => {
    const { invoke, convertFileSrc } = await import("@tauri-apps/api/core");
    const preview = await invoke<string>("repair_image_preview", { path });
    return convertFileSrc(preview);
  })().finally(() => { pending.delete(path); });
  pending.set(path, request);
  return request;
}
