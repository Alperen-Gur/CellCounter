import { sha256Hex } from "../models/hash";
export async function assertSourceIdentity(source: Blob, expected: string | undefined, signal?: AbortSignal): Promise<void> {
  if (!expected || !/^[a-f0-9]{64}$/i.test(expected)) throw new Error("The preserved source has no recorded SHA-256 identity. Reimport it before this workflow.");
  if (source.size > 64 * 1024 * 1024) throw new Error("Source identity verification is bounded to 64 MiB. Open a smaller source or local Zarr field.");
  if (signal?.aborted) throw new DOMException("Cancelled", "AbortError");
  const actual = await sha256Hex(await source.arrayBuffer());
  if (signal?.aborted) throw new DOMException("Cancelled", "AbortError");
  if (actual !== expected.toLowerCase()) throw new Error("Preserved source bytes differ from their recorded SHA-256 identity. Reimport the source.");
}
