import {
  assert,
  assertEqual,
  readRepositoryText,
  reportFailure,
} from "./lib/verify-utils.mjs";

const NODE_VERSION = "22.18.0";
const RUST_VERSION = "1.88.0";
const UV_VERSION = "0.11.29";
const UV_SHA256 = "a047d55651bc3e0ca24595b25ec4cfcb10f9dca9fb56514e661269b37d4fae68";

function validateWorkflow(source) {
  const issues = [];
  const requireText = (fragment, message) => {
    if (!source.includes(fragment)) issues.push(message);
  };
  const reject = (pattern, message) => {
    if (pattern.test(source)) issues.push(message);
  };

  requireText("runs-on: windows-latest", "job is not on a native Windows runner");
  requireText("contents: read", "workflow permissions are not read-only");
  requireText("workflow_dispatch:", "manual packaging validation trigger is missing");
  requireText(`node-version: ${NODE_VERSION}`, "Node toolchain is not exactly pinned");
  requireText(`RUST_TOOLCHAIN: \"${RUST_VERSION}\"`, "Rust toolchain is not exactly pinned");
  requireText(`UV_VERSION: \"${UV_VERSION}\"`, "uv sidecar version is not exactly pinned");
  requireText(`UV_SHA256: \"${UV_SHA256}\"`, "uv archive checksum is not pinned");
  requireText("Get-FileHash -Path $archive -Algorithm SHA256", "uv download is not checksum-verified");
  requireText("releases/download/$env:UV_VERSION/uv-x86_64-pc-windows-msvc.zip", "uv download does not use the pinned version variable");
  requireText("npm ci", "locked frontend dependency install is missing");
  requireText("npm run verify:windows", "portable Windows contract checks are missing");
  requireText("npm run build", "frontend production build is missing");
  requireText("cargo test --manifest-path src-tauri/Cargo.toml --locked", "locked Rust tests are missing");
  requireText("npm run build:windows", "native installer build is missing");
  requireText("node scripts/verify-windows-artifacts.mjs --write-checksums", "installer artifact/checksum assertion is missing");
  requireText("src-tauri/target/release/bundle/msi/*.msi", "MSI upload path is missing");
  requireText("src-tauri/target/release/bundle/nsis/*-setup.exe", "NSIS EXE upload path is missing");
  requireText("src-tauri/target/release/bundle/SHA256SUMS.txt", "checksum manifest upload is missing");
  requireText("if-no-files-found: error", "artifact upload does not fail closed");
  requireText("actions/upload-artifact@", "installer artifact upload is missing");

  reject(/contents:\s*write/i, "workflow can write repository releases");
  reject(/GITHUB_TOKEN|gh\s+release|create-release|tauri-action/i, "workflow contains an external release-write path");
  reject(/release(s)?\/download\/(latest|nightly)/i, "workflow downloads an unpinned release asset");
  return issues;
}

try {
  const source = readRepositoryText(".github/workflows/windows.yml");
  const issues = validateWorkflow(source);
  assertEqual(issues.length, 0, issues.join("; "));

  const permissionNegative = source.replace("contents: read", "contents: write");
  assert(validateWorkflow(permissionNegative).some((issue) => issue.includes("write repository")), "permissions negative control did not fail");
  const targetNegative = source.replace("src-tauri/target/release/bundle/nsis/*-setup.exe", "src-tauri/target/release/bundle/msi/*.msi");
  assert(validateWorkflow(targetNegative).some((issue) => issue.includes("NSIS")), "NSIS negative control did not fail");

  console.log("Windows CI verification passed");
} catch (error) {
  reportFailure(error);
}
