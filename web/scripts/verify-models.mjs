import { readFile } from "node:fs/promises";

const catalog = await readFile(new URL("../src/models/catalog.ts", import.meta.url), "utf8");
const runtime = await readFile(new URL("../src/models/WebGpuInference.ts", import.meta.url), "utf8");
const errors = await readFile(new URL("../src/models/errors.ts", import.meta.url), "utf8");
const buildContract = await readFile(new URL("../src/models/BUILD-CONTRACT.md", import.meta.url), "utf8");
const app = await readFile(new URL("../src/App.tsx", import.meta.url), "utf8");

const ids = [...catalog.matchAll(/\n\s*id:\s*"([^"]+)"/g)].map((match) => match[1]);
const expected = ["cpsam_v2", "cp-cyto3", "sd-fluo"];
if (JSON.stringify(ids) !== JSON.stringify(expected)) throw new Error(`Catalog ids must be exactly ${expected.join(", ")}; received ${ids.join(", ")}`);
for (const id of expected) {
  const section = catalog.slice(catalog.indexOf(`id: "${id}"`), catalog.indexOf(`id: "${id}"`) + 1300);
  if (!/manifestVersion:\s*"\d+\.\d+\.\d+"/.test(section)) throw new Error(`${id}: versioned manifest missing`);
  if (!/sha256:\s*"[a-f0-9]{64}"/.test(section)) throw new Error(`${id}: pinned SHA-256 missing`);
  if (!/availability:\s*"(?:buildRequired|ready)"/.test(section)) throw new Error(`${id}: explicit artifact availability missing`);
  const buildRequired = /availability:\s*"buildRequired"/.test(section);
  if (buildRequired && !/sha256:\s*"0{64}"/.test(section)) throw new Error(`${id}: build-required checksum must be a visible all-zero sentinel`);
  if (buildRequired && !/byteLength:\s*0\b/.test(section)) throw new Error(`${id}: build-required byte length must be zero`);
  if (!buildRequired && /sha256:\s*"0{64}"/.test(section)) throw new Error(`${id}: ready artifact cannot use a sentinel checksum`);
}
if (!runtime.includes('executionProviders: ["webgpu"]')) throw new Error("Runtime is not pinned to WebGPU");
if (/executionProviders:[^\n]*(?:wasm|cpu)/i.test(runtime)) throw new Error("Runtime contains a CPU/WASM substitution");
for (const token of ["NoWebGpuError", "ModelArtifactUnavailableError", "verifySha256", "UnsupportedOperatorError", "CancelledInferenceError"]) {
  if (!runtime.includes(token) && !errors.includes(token)) throw new Error(`Explicit failure path missing: ${token}`);
}
if (!buildContract.includes("Current live-artifact blocker") || !buildContract.includes("Fixture inference must never")) throw new Error("Build contract does not disclose artifact/fixture boundary");
if (!/const defaultSettings:[\s\S]{0,160}modelId:\s*"classical"/.test(app)) throw new Error("Browser default must be the explicitly named built-in classical detector until learned artifacts are available");

console.log("Web model catalog verification passed (exactly 3 models; WebGPU-only runtime; artifacts explicitly gated)");
