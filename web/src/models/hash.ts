import { ArtifactHashMismatchError } from "./errors";
import type { ModelId } from "../domain/types";

export async function sha256Hex(data: BufferSource): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function verifySha256(modelId: ModelId, bytes: ArrayBuffer, expected: string): Promise<void> {
  const actual = await sha256Hex(bytes);
  if (actual !== expected.toLowerCase()) throw new ArtifactHashMismatchError(modelId, expected, actual);
}
