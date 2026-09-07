import {
  assert,
  assertEqual,
  assertFile,
  assertIncludes,
  assertSameMembers,
  readJson,
  readText,
  reportFailure,
} from "./lib/verify-utils.mjs";

const RELEASE_VERSION = readJson("package.json").version;
const WINDOWS_TARGETS = ["msi", "nsis"];
const UPGRADE_CODE = "9d098d8e-800d-416c-a340-9b6754ea88d0";

function validateBundle(config, packageJson, packageLock, cargoToml, cargoLock) {
  const issues = [];
  const check = (condition, message) => {
    if (!condition) issues.push(message);
  };

  check(config.productName === "CellCounter", "productName must be CellCounter");
  check(config.identifier === "com.alperengur.cellcounter", "bundle identifier changed");
  check(config.version === RELEASE_VERSION, "Tauri version does not match the release version");
  check(packageJson.version === RELEASE_VERSION, "npm version does not match the release version");
  check(packageLock.version === RELEASE_VERSION, "npm lock version does not match the release version");
  check(packageLock.packages?.[""]?.version === RELEASE_VERSION, "npm root lock version does not match the release version");
  check(new RegExp(`^version = "${RELEASE_VERSION.replaceAll(".", "\\.")}"$`, "m").test(cargoToml), "Cargo version does not match the release version");
  check(new RegExp(`name = "desktop"\\r?\\nversion = "${RELEASE_VERSION.replaceAll(".", "\\.")}"`).test(cargoLock), "Cargo lock root version does not match the release version");

  const targets = config.bundle?.targets;
  check(Array.isArray(targets), "bundle targets must be an explicit array");
  if (Array.isArray(targets)) {
    check(JSON.stringify([...targets].sort()) === JSON.stringify([...WINDOWS_TARGETS].sort()), "bundle targets must be exactly MSI and NSIS");
  }
  check(config.bundle?.active === true, "bundling must be active");
  check(config.bundle?.useLocalToolsDir === true, "WiX/NSIS tools must use the build-local cache");
  check(config.bundle?.license === "MIT", "installer license metadata must be MIT");
  check(config.bundle?.licenseFile === "../../LICENSE", "installer license file must point to the repository license");
  check(config.bundle?.resources?.["../python"] === "python", "Python runtime resources are not bundled");
  check(JSON.stringify(config.bundle?.externalBin) === JSON.stringify(["binaries/uv"]), "uv external binary declaration changed");

  const windows = config.bundle?.windows;
  check(windows?.allowDowngrades === false, "installer must block downgrades");
  check(windows?.webviewInstallMode?.type === "embedBootstrapper", "WebView2 bootstrapper must be embedded");
  check(windows?.webviewInstallMode?.silent === true, "WebView2 setup must be silent");
  check(windows?.wix?.language === "en-US", "MSI language must be en-US");
  check(windows?.wix?.upgradeCode === UPGRADE_CODE, "stable MSI upgrade code changed");
  check(windows?.nsis?.installMode === "currentUser", "NSIS must default to a non-admin current-user install");
  check(windows?.nsis?.compression === "lzma", "NSIS compression must be LZMA");
  check(windows?.nsis?.installerIcon === "icons/icon.ico", "NSIS installer icon is not Windows-native");
  check(windows?.nsis?.uninstallerIcon === "icons/icon.ico", "NSIS uninstaller icon is not Windows-native");

  const security = config.app?.security;
  check(typeof security?.csp === "string" && security.csp.includes("object-src 'none'"), "production CSP is missing");
  check(security?.freezePrototype === true, "JavaScript prototype hardening is disabled");
  check(security?.assetProtocol?.enable === true, "local microscopy image protocol is disabled");
  const assetAllow = security?.assetProtocol?.scope?.allow;
  check(Array.isArray(assetAllow) && assetAllow.length === 2, "asset protocol must have two narrow image scopes");
  check(assetAllow?.every((entry) => entry.startsWith("$APPDATA/com.alperengur.cellcounter/CellCounter/")), "asset protocol scope escaped app data");
  check(cargoToml.includes('tauri = { version = "2", features = ["protocol-asset"] }'), "Tauri protocol-asset feature is not enabled");
  return issues;
}

try {
  const config = readJson("src-tauri/tauri.conf.json");
  const packageJson = readJson("package.json");
  const packageLock = readJson("package-lock.json");
  const cargoToml = readText("src-tauri/Cargo.toml");
  const cargoLock = readText("src-tauri/Cargo.lock");
  const issues = validateBundle(config, packageJson, packageLock, cargoToml, cargoLock);
  assertEqual(issues.length, 0, issues.join("; "));

  assertSameMembers(config.bundle.targets, WINDOWS_TARGETS, "native target set changed");
  for (const icon of config.bundle.icon) assertFile(`src-tauri/${icon}`);
  assertFile("src-tauri/icons/icon.ico");
  assertFile("../LICENSE");
  for (const resource of [
    "python/pyproject.toml",
    "python/uv.lock",
    "python/cellpose_detect.py",
    "python/cellpose4_detect.py",
    "python/stardist_detect.py",
    "python/_export_imagej_roi.py",
    "python/_seg_npy_io.py",
  ]) {
    assertFile(resource, `Bundled Python resource is missing or empty: ${resource}`);
  }
  assertIncludes(config.app.security.csp, "http://asset.localhost", "CSP does not permit Tauri's asset host");

  const negative = structuredClone(config);
  negative.bundle.targets = ["msi"];
  assert(validateBundle(negative, packageJson, packageLock, cargoToml, cargoLock).length > 0, "target negative control did not fail");

  const crlfCargoLock = cargoLock.replaceAll("\r\n", "\n").replaceAll("\n", "\r\n");
  assertEqual(
    validateBundle(config, packageJson, packageLock, cargoToml, crlfCargoLock).length,
    0,
    "Windows CRLF Cargo lock validation failed",
  );

  console.log("Windows bundle configuration verification passed");
} catch (error) {
  reportFailure(error);
}
