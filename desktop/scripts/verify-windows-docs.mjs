import { statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import {
  assertIncludes,
  readRepositoryText,
  readJson,
  repositoryPath,
  reportFailure,
} from "./lib/verify-utils.mjs";

function verifyLocalLinks(document, source) {
  for (const [, target] of source.matchAll(/\[[^\]\n]*\]\(([^\s)]+)\)/g)) {
    if (/^(?:[a-z][a-z\d+.-]*:|#|\/\/)/i.test(target)) continue;
    const path = decodeURIComponent(target.split(/[?#]/)[0]);
    if (!path) continue;
    const resolved = resolve(dirname(repositoryPath(document)), path);
    try {
      if (!statSync(resolved).isFile()) throw new Error("not a file");
    } catch {
      throw new Error(`${document} links to a missing file: ${target}`);
    }
  }
}

try {
  const { version } = readJson("package.json");
  const config = readJson("src-tauri/tauri.conf.json");
  const release = `${config.bundle.homepage}/releases/tag/windows-v${version}`;
  const guide = readRepositoryText("docs/WINDOWS.md");
  const readme = readRepositoryText("desktop/README.md");
  for (const [document, source] of [["docs/WINDOWS.md", guide], ["desktop/README.md", readme]]) {
    assertIncludes(source, release, `${document} must link to the current Windows release`);
    assertIncludes(source, "SHA256SUMS.txt", `${document} must identify the installer checksum file`);
    verifyLocalLinks(document, source);
  }

  const installerPrefix = `${config.productName}_${version}_x64`;
  assertIncludes(guide, `${installerPrefix}-setup.exe`, "Windows guide names a stale NSIS installer");
  assertIncludes(guide, `${installerPrefix}_${config.bundle.windows.wix.language}.msi`, "Windows guide names a stale MSI installer");
  assertIncludes(readme, "../docs/WINDOWS.md", "desktop README does not link to the operator guide");

  console.log("Windows documentation verification passed");
} catch (error) {
  reportFailure(error);
}
