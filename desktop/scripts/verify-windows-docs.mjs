import {
  assert,
  assertIncludes,
  readRepositoryText,
  readText,
  readJson,
  reportFailure,
} from "./lib/verify-utils.mjs";

try {
  const guide = readRepositoryText("docs/WINDOWS.md");
  const lower = guide.toLowerCase();
  const requiredHeadings = [
    `# cellcounter for windows ${readJson("package.json").version}`,
    "## system requirements",
    "## choose an installer",
    "## install",
    "## upgrade",
    "## uninstall",
    "## install the three models",
    "## local data and privacy",
    "## backup and restore",
    "## reset",
    "## troubleshooting",
    "## validation boundary",
  ];
  for (const heading of requiredHeadings) assertIncludes(lower, heading, "Windows guide section is missing");

  for (const model of ["`cpsam_v2`", "`cp-cyto3`", "`sd-fluo`"]) {
    assertIncludes(guide, model, `model bootstrap does not name ${model}`);
  }
  for (const fragment of [
    ".msi",
    ".exe",
    "%APPDATA%\\com.alperengur.cellcounter\\CellCounter",
    "%APPDATA%\\com.alperengur.cellcounter\\py",
    "store.sqlite",
    "Images",
    "Thumbnails",
    "Models",
    "Exports",
    ".venv",
    ".venv4",
    ".venvsd",
    "no silent model substitution",
    "WebView2",
    "SmartScreen",
    "Settings → Data & reset",
    "not remove the app-data directory",
    "physical Windows",
  ]) {
    assertIncludes(guide, fragment, "Windows operator guidance is incomplete");
  }
  assert(/images[^.]{0,100}(never|do not)[^.]{0,100}(upload|leave)/i.test(guide), "local-only image privacy promise is missing");
  assert(/model[^.]{0,100}(download|network|internet)/i.test(guide), "model download network exception is missing");
  assert(/close CellCounter/i.test(guide), "backup procedure does not require a closed database");
  assert(/unsigned/i.test(guide), "unsigned CI artifact limitation is not disclosed");

  const readme = readText("README.md");
  assertIncludes(readme, "Windows", "desktop README no longer identifies the Windows target");
  assertIncludes(readme, "../docs/WINDOWS.md", "desktop README does not link to the operator guide");
  assertIncludes(readme, readJson("package.json").version, "desktop README version identity is stale");

  console.log("Windows documentation verification passed");
} catch (error) {
  reportFailure(error);
}
