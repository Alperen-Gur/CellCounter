import { constants } from "node:fs";
import { lstat, mkdir, open, realpath } from "node:fs/promises";
import { createHash } from "node:crypto";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { safeRelativePath, fail, integer, checkAbort } from "../microscopy/guards";
import type { LocalByteStore } from "../microscopy/types";
import { WORKER_LIMITS, type InputFile, type OutputFile, type ReadRecord, type StoreGrant, type WorkerRequest } from "./protocol";

export const hash = (data: Uint8Array | string) => createHash("sha256").update(data).digest("hex");
export function contained(root: string, path: string): string {
  if (!isAbsolute(path)) fail("unsafe-path", "Worker files require absolute scoped paths.");
  const child = relative(root, resolve(path));
  if (!child || child === ".." || child.startsWith(`..${sep}`) || isAbsolute(child)) fail("unsafe-path", "Worker file leaves its granted directory.");
  return resolve(path);
}
async function noLinks(root: string, path: string) {
  const child = relative(root, contained(root, path)); let current = root;
  for (const part of child.split(sep)) {
    current = resolve(current, part);
    const info = await lstat(current);
    if (info.isSymbolicLink()) fail("unsafe-path", "Symbolic links are not accepted in worker inputs or Zarr directories.");
  }
}
export async function readFileBounded(path: string, maxBytes: number, root?: string): Promise<Uint8Array> {
  if (root) await noLinks(root, path);
  else if ((await lstat(path)).isSymbolicLink()) fail("unsafe-path", "Worker input cannot be a symbolic link.");
  const file = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
  try {
    const before = await file.stat();
    if (!before.isFile() || before.size > maxBytes) fail("resource-limit", "Worker input is not a bounded regular file.");
    const data = new Uint8Array(before.size); let offset = 0;
    while (offset < data.length) {
      const chunk = await file.read(data, offset, data.length - offset, offset);
      if (!chunk.bytesRead) fail("changed-input", "An input changed while it was being read.");
      offset += chunk.bytesRead;
    }
    const after = await file.stat();
    if (after.size !== before.size || after.mtimeMs !== before.mtimeMs || after.ino !== before.ino)
      fail("changed-input", "An input changed while it was being read.");
    return data;
  } finally { await file.close(); }
}
export async function canonicalDirectory(path: string): Promise<string> {
  if (!isAbsolute(path) || resolve(path) !== await realpath(path) || !(await lstat(path)).isDirectory())
    fail("unsafe-path", "Worker directories must be existing canonical local directories, without symbolic links.");
  return resolve(path);
}
export class WorkerIO {
  readonly outputs: OutputFile[] = [];
  readonly readSet: ReadRecord[] = [];
  private readonly inputs = new Map<string, InputFile>();
  private readonly grants = new Map<string, StoreGrant>();
  private readonly reads = new Map<string, ReadRecord>();
  private outputBytes = 0;
  private storeBytes = 0;
  constructor(readonly request: WorkerRequest, readonly requestRoot: string, readonly outputRoot: string) {}
  async initialize() {
    if (!Array.isArray(this.request.inputs) || this.request.inputs.length > WORKER_LIMITS.inputFiles) fail("resource-limit", "Too many worker input files.");
    let total = 0;
    for (const input of this.request.inputs) {
      if (!input || typeof input.id !== "string" || !input.id || input.id.length > 1024 || this.inputs.has(input.id)
        || !/^[0-9a-f]{64}$/.test(input.sha256)) fail("invalid-input", "Input IDs and SHA-256 hashes must be valid and unique.");
      integer(input.bytes, "Input byte length", 0, WORKER_LIMITS.inputBytes); total += input.bytes;
      if (total > WORKER_LIMITS.inputBytes) fail("resource-limit", "Worker inputs exceed the total byte budget.");
      contained(this.requestRoot, input.path); await noLinks(this.requestRoot, input.path);
      if (input.path === this.outputRoot || input.path.startsWith(this.outputRoot + sep)) fail("unsafe-path", "Worker output files cannot be input grants.");
      this.inputs.set(input.id, input);
    }
    const stores = this.request.stores ?? [];
    if (!Array.isArray(stores) || stores.length > WORKER_LIMITS.stores) fail("resource-limit", "Too many source-directory grants.");
    for (const grant of stores) {
      if (!grant || typeof grant.id !== "string" || !grant.id || typeof grant.name !== "string" || !grant.name
        || this.grants.has(grant.id) || (grant.metadataSha256 !== undefined && !/^[0-9a-f]{64}$/.test(grant.metadataSha256)))
        fail("invalid-store", "Source-directory grants need unique IDs, names and optional exact metadata hashes.");
      await canonicalDirectory(grant.root); this.grants.set(grant.id, grant);
    }
  }
  async input(id: string, maxBytes = WORKER_LIMITS.inputBytes) {
    const descriptor = this.inputs.get(id);
    if (!descriptor) fail("missing-input", "The requested input ID has no immutable file grant.");
    const data = await readFileBounded(descriptor.path, Math.min(maxBytes, descriptor.bytes), this.requestRoot);
    if (data.byteLength !== descriptor.bytes || hash(data) !== descriptor.sha256) fail("changed-input", "A worker input no longer matches its retained bytes.");
    return data;
  }
  async json<T>(id: string): Promise<T> {
    const data = await this.input(id, WORKER_LIMITS.jsonBytes);
    try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(data)); }
    catch { fail("invalid-json", "A retained worker JSON input is malformed."); }
  }
  grant(id: string) { const grant = this.grants.get(id); if (!grant) fail("missing-store", "The requested local dataset has no directory grant."); return grant; }
  store(id: string): LocalByteStore {
    const grant = this.grant(id);
    return { id: grant.id, name: grant.name, read: async (path, maxBytes = 64 * 1024 ** 2, signal) => {
      checkAbort(signal); safeRelativePath(path);
      const key = `${id}\0${path}`; const previous = this.reads.get(key);
      if (!previous && this.readSet.length >= WORKER_LIMITS.readFiles) fail("resource-limit", "The Zarr read set exceeds its file budget.");
      let data: Uint8Array;
      try { data = await readFileBounded(resolve(grant.root, path), Math.min(maxBytes, 64 * 1024 ** 2), grant.root); }
      catch (cause) {
        if ((cause as NodeJS.ErrnoException)?.code !== "ENOENT") throw cause;
        if (previous && !previous.missing) fail("changed-input", "A local Zarr file disappeared during this operation.");
        if (!previous) { const missing: ReadRecord = { storeId: id, path, sha256: null, bytes: 0, missing: true }; this.reads.set(key, missing); this.readSet.push(missing); }
        return null;
      }
      checkAbort(signal);
      const entry = { storeId: id, path, sha256: hash(data), bytes: data.byteLength };
      if (previous && (previous.sha256 !== entry.sha256 || previous.bytes !== entry.bytes)) fail("changed-input", "A local Zarr file changed during this operation.");
      if (!previous) {
        this.storeBytes += data.byteLength;
        if (this.storeBytes > WORKER_LIMITS.inputBytes) fail("resource-limit", "Selected Zarr reads exceed the operation byte budget.");
        this.reads.set(key, entry); this.readSet.push(entry);
      }
      return data;
    } };
  }
  async write(id: string, data: Uint8Array | string, kind: string, extra: Pick<OutputFile, "dtype" | "shape"> = {}) {
    if (!/^[a-z0-9][a-z0-9._-]{0,100}$/.test(id) || this.outputs.some((item) => item.id === id)) fail("invalid-output", "Output IDs must be unique safe names.");
    const bytes = typeof data === "string" ? Buffer.from(data, "utf8") : data;
    if (bytes.byteLength + this.outputBytes > WORKER_LIMITS.outputBytes) fail("resource-limit", "Worker outputs exceed their total byte budget.");
    const path = `${id}`; const destination = contained(this.outputRoot, resolve(this.outputRoot, path));
    const file = await open(destination, "wx", 0o600);
    try { await file.writeFile(bytes); await file.sync(); } finally { await file.close(); }
    const output = { id, path, sha256: hash(bytes), bytes: bytes.byteLength, kind, ...extra };
    this.outputs.push(output); this.outputBytes += bytes.byteLength; return id;
  }
  async writeJSON(id: string, value: unknown, kind: string) {
    const encoded = JSON.stringify(value);
    if (Buffer.byteLength(encoded) > WORKER_LIMITS.jsonBytes) fail("resource-limit", "Worker JSON output exceeds 32 MiB.");
    return this.write(id, encoded, kind);
  }
}

export async function prepareOutput(requestRoot: string, outputDirectory: string) {
  contained(requestRoot, outputDirectory);
  await mkdir(outputDirectory, { mode: 0o700 });
  return canonicalDirectory(outputDirectory);
}
export function requestDirectory(path: string) { return dirname(resolve(path)); }
