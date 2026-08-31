import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, relative, resolve, sep } from "node:path";
import { tmpdir } from "node:os";
import { assert, reportFailure } from "./lib/verify-utils.mjs";

function filesUnder(root) {
  const files = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) files.push(...filesUnder(path));
    if (entry.isFile()) files.push(path);
  }
  return files;
}

function discoverArtifacts(bundleRoot) {
  const files = filesUnder(bundleRoot);
  const msi = files.filter((file) => /[\\/]msi[\\/].+\.msi$/i.test(file));
  const nsis = files.filter((file) => /[\\/]nsis[\\/].+-setup\.exe$/i.test(file));
  assert(msi.length === 1, `expected exactly one MSI, found ${msi.length}`);
  assert(nsis.length === 1, `expected exactly one NSIS setup EXE, found ${nsis.length}`);
  for (const file of [...msi, ...nsis]) {
    assert(statSync(file).size > 0, `installer is empty: ${file}`);
  }
  return [msi[0], nsis[0]];
}

function sha256(file) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

function writeChecksums(bundleRoot, files) {
  const lines = files
    .map((file) => `${sha256(file)}  ${relative(bundleRoot, file).split(sep).join("/")}`)
    .sort();
  writeFileSync(join(bundleRoot, "SHA256SUMS.txt"), `${lines.join("\n")}\n`, "utf8");
}

function validateArtifacts(bundleRoot) {
  const files = discoverArtifacts(bundleRoot);
  const manifestPath = join(bundleRoot, "SHA256SUMS.txt");
  const entries = new Map(
    readFileSync(manifestPath, "utf8")
      .trim()
      .split(/\r?\n/)
      .map((line) => {
        const match = line.match(/^([a-f0-9]{64})  (.+)$/);
        assert(match, `invalid checksum line: ${line}`);
        return [match[2], match[1]];
      }),
  );
  assert(entries.size === 2, `expected two checksum entries, found ${entries.size}`);
  for (const file of files) {
    const name = relative(bundleRoot, file).split(sep).join("/");
    assert(entries.get(name) === sha256(file), `checksum mismatch for ${name}`);
  }
  return files;
}

function selfTest() {
  const root = mkdtempSync(join(tmpdir(), "cellcounter-windows-artifacts-"));
  try {
    mkdirSync(join(root, "msi"));
    mkdirSync(join(root, "nsis"));
    writeFileSync(join(root, "msi", "CellCounter_1.0.8_x64_en-US.msi"), "fixture");
    writeFileSync(join(root, "nsis", "CellCounter_1.0.8_x64-setup.exe"), "fixture");
    writeChecksums(root, discoverArtifacts(root));
    validateArtifacts(root);
    writeFileSync(join(root, "nsis", "unexpected-setup.exe"), "fixture");
    let rejected = false;
    try {
      validateArtifacts(root);
    } catch {
      rejected = true;
    }
    assert(rejected, "duplicate-installer negative control did not fail");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

try {
  if (process.argv.includes("--self-test")) {
    selfTest();
  } else {
    const pathArgument = process.argv.find((argument) => !argument.startsWith("--") && argument !== process.argv[0] && argument !== process.argv[1]);
    const bundleRoot = resolve(pathArgument ?? "src-tauri/target/release/bundle");
    if (process.argv.includes("--write-checksums")) {
      writeChecksums(bundleRoot, discoverArtifacts(bundleRoot));
    }
    validateArtifacts(bundleRoot);
  }
  console.log("Windows installer artifact verification passed");
} catch (error) {
  reportFailure(error);
}
