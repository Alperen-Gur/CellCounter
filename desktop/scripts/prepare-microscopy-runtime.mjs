// Explicit packaging step. Installed application requests never download Node.
import { createHash } from "node:crypto";
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const args = process.argv.slice(2);
function option(name, fallback) {
  const index = args.indexOf(name);
  if (index < 0) return fallback;
  if (!args[index + 1] || args[index + 1].startsWith("--")) throw new Error(`Missing ${name} value`);
  return args[index + 1];
}
const platform = option("--platform", `${process.platform}-${process.arch}`);
const output = resolve(option("--output", join(root, "desktop/microscopy-runtime")));
const python = option("--python", process.platform === "win32" ? "python" : "python3");
const pins = JSON.parse(readFileSync(join(root, "shared/microscopy-worker/node-runtime.json"), "utf8"));
const artifact = pins.artifacts[platform];
if (!artifact) throw new Error(`No pinned microscopy runtime for ${platform}`);
function assertDestination() {
  if (!existsSync(output)) return;
  if (lstatSync(output).isSymbolicLink() || !lstatSync(output).isDirectory()) throw new Error("Runtime output must be a regular directory");
  // A clean checkout intentionally retains these source instructions. Never
  // remove them or silently overwrite a previous generated runtime.
  for (const name of readdirSync(output)) {
    if (!["README.md", ".gitignore"].includes(name) || !lstatSync(join(output, name)).isFile())
      throw new Error(`Runtime output contains retained/generated content: ${output}. Choose a new staging directory.`);
  }
}
assertDestination();
const work = mkdtempSync(join(tmpdir(), "cellcounter-microscopy-package-"));
const archive = join(work, artifact.file);
const response = await fetch(`https://nodejs.org/download/release/v${pins.version}/${artifact.file}`);
if (!response.ok || !response.body) throw new Error(`Node archive download failed: HTTP ${response.status}`);
const chunks = []; let size = 0;
for await (const chunk of response.body) {
  size += chunk.byteLength;
  if (size > 256 * 1024 * 1024) throw new Error("Node archive exceeds the packaging size bound");
  chunks.push(Buffer.from(chunk));
}
const bytes = Buffer.concat(chunks);
if (createHash("sha256").update(bytes).digest("hex") !== artifact.sha256) throw new Error("Official Node archive SHA-256 mismatch");
writeFileSync(archive, bytes, { flag: "wx" });
function run(command, values) {
  const result = spawnSync(command, values, { cwd: root, stdio: "inherit", shell: false });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Packaging command failed (${result.status}): ${command}`);
}
const assets = join(work, "assets");
run(process.execPath, ["shared/microscopy-worker/build.mjs", "--output", assets]);
const staged = join(work, "runtime");
run(python, ["shared/microscopy-worker/stage-runtime.py", "--platform", platform, "--archive", archive, "--assets", assets, "--output", staged]);
assertDestination();
mkdirSync(output, { recursive: true });
for (const name of readdirSync(staged).filter(name => name !== "microscopy-runtime.json"))
  cpSync(join(staged, name), join(output, name), { recursive: true, force: false, errorOnExist: true });
// Publish the validated manifest last so partial staging cannot pass build.rs.
const manifestTemporary = join(output, ".microscopy-runtime-staging.json");
writeFileSync(manifestTemporary, readFileSync(join(staged, "microscopy-runtime.json")), { flag: "wx" });
renameSync(manifestTemporary, join(output, "microscopy-runtime.json"));
console.log(`Staged pinned Node ${pins.version} and shared microscopy assets at ${output}`);
