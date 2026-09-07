import {
  assert,
  assertEqual,
  assertIncludes,
  assertString,
  importTypeScriptModule,
  readText,
  reportFailure,
} from "./lib/verify-utils.mjs";

const EXPECTED_AREAS = ["Input", "Detection", "Analysis", "Editing", "Workflow", "Export", "System"];
const VALID_STATES = new Set(["ready", "adapted", "pending"]);
const REQUIRED_IMPLEMENTED = [
  "input-vendor",
  "analysis-intensity",
  "analysis-area",
  "analysis-puncta",
  "analysis-tracking",
  "analysis-neurite",
  "analysis-line-profile",
  "workflow-protocol",
  "workflow-finetune",
  "export-provenance",
  "export-overlay",
  "export-geojson",
];

function verifyEvidence(capability) {
  assert(Array.isArray(capability.evidence) && capability.evidence.length > 0,
    `${capability.id} has no machine-checkable implementation evidence`);
  for (const reference of capability.evidence) {
    assertString(reference, `${capability.id} has an empty evidence reference`);
    const separator = reference.indexOf("#");
    assert(separator > 0 && separator < reference.length - 1,
      `${capability.id} evidence must use path#literal-symbol: ${reference}`);
    const path = reference.slice(0, separator);
    const symbol = reference.slice(separator + 1);
    const source = readText(path);
    assertIncludes(source, symbol, `${capability.id} evidence surface disappeared (${path})`);
  }
}

try {
  const parityModule = await importTypeScriptModule("src/platform/windowsParity.ts");
  const capabilities = parityModule.WINDOWS_PARITY_CAPABILITIES;
  assert(Array.isArray(capabilities), "parity inventory did not export an array");
  assert(capabilities.length >= 47, "The existing parity inventory must not lose capabilities");

  const ids = new Set();
  const areas = new Set();
  for (const capability of capabilities) {
    assertString(capability.id, "parity capability id is empty");
    assert(!ids.has(capability.id), `duplicate parity id: ${capability.id}`);
    ids.add(capability.id);
    assertString(capability.name, `${capability.id} name is empty`);
    assertString(capability.windowsSurface, `${capability.id} Windows surface is empty`);
    assertString(capability.note, `${capability.id} note is empty`);
    assert(VALID_STATES.has(capability.state), `${capability.id} has invalid state ${capability.state}`);
    verifyEvidence(capability);
    areas.add(capability.area);
  }
  assertEqual(JSON.stringify([...areas].sort()), JSON.stringify([...EXPECTED_AREAS].sort()), "parity areas changed");

  const measured = capabilities.reduce(
    (counts, capability) => ({ ...counts, [capability.state]: counts[capability.state] + 1 }),
    { ready: 0, adapted: 0, pending: 0 },
  );
  assertEqual(JSON.stringify(parityModule.parityCounts()), JSON.stringify(measured), "parity summary is not derived from the inventory");

  const support = readText("src/pages/system/SupportPage.tsx");
  assertIncludes(support, "WINDOWS_PARITY_CAPABILITIES", "Support does not render the inventory");
  assertIncludes(support, 'item.state === "pending"', "Support cannot isolate unavailable work");
  assertIncludes(support, "aria-pressed", "pending filter is not exposed accessibly");
  assertIncludes(support, "All inventoried workflows are available.", "zero-pending state is not disclosed");
  assertIncludes(support, "rows.map", "Support does not render every capability row");
  const routes = readText("src/components/routes.tsx");
  assertIncludes(routes, 'path: "/support"', "parity inventory has no route");
  assertIncludes(routes, 'NAV_FOOTER: RouteId[] = ["support", "settings"]', "Support is not persistently visible in navigation");

  const pending = capabilities.filter((capability) => capability.state === "pending");
  assert(pending.every((capability) => capability.note.length >= 24), "pending items need actionable disclosure notes");

  for (const id of REQUIRED_IMPLEMENTED) {
    const capability = capabilities.find((item) => item.id === id);
    assert(capability && capability.state !== "pending", `${id} regressed to unavailable`);
  }

  const assayUi = readText("src/pages/results/AdvancedAssaysPanel.tsx");
  assertIncludes(assayUi, 'invoke("cancel_assay"', "advanced assays lost cancellation");
  assertIncludes(assayUi, "runId,", "advanced assays do not bind cancellation to a run id");
  const assayRunner = readText("src-tauri/src/analysis/runner.rs");
  assertIncludes(assayRunner, "fn assay_flag_takes_value", "assay IPC options are no longer allowlisted");
  assertIncludes(assayRunner, "MAX_LINE_PROFILE_PIXELS", "line-profile allocation budget disappeared");
  assertIncludes(assayRunner, "spawn_blocking", "line-profile decode returned to the async executor");

  const imageIo = readText("python/_imageio.py");
  assertIncludes(imageIo, "MAX_PROJECTED_FLOAT_BYTES", "vendor projected-image budget disappeared");
  assertIncludes(imageIo, "_enforce_shape_budget", "vendor dimension guard disappeared");
  const trainer = readText("python/cellpose_train.py");
  for (const forbidden of ["ap50=0.900", "train_loss = max(", 'write_bytes(b"")', "ap50 = precision * recall"]) {
    assert(!trainer.includes(forbidden), `trainer contains fabricated-success fallback: ${forbidden}`);
  }
  assertIncludes(trainer, "cp_metrics.average_precision", "fine-tune AP50 is not measured by Cellpose");
  const trainingHost = readText("src-tauri/src/analysis/training.rs");
  assertIncludes(trainingHost, "CheckpointCleanup", "fine-tune failure cleanup guard disappeared");
  assertIncludes(trainingHost, "canonical_checkpoint.starts_with(&models_dir)", "checkpoint insertion is not app-confined");
  const fineTune = readText("src/pages/finetune/FineTunePage.tsx");
  assertIncludes(fineTune, 'return Number.isFinite(value) ? value!.toFixed(3) : "unavailable"', "missing held-out metrics are displayed as measured zero");

  const provenance = readText("src-tauri/src/export/provenance.rs");
  assertIncludes(provenance, "run_model_from_detector", "exports no longer use exact per-detection model identity");
  assertIncludes(provenance, 'map.insert("weights_sha256"', "nullable weights checksum key disappeared");
  const settings = readText("src/pages/settings/SettingsPage.tsx");
  assertIncludes(settings, "GPU unavailable in Windows", "CPU-only runtime disclosure disappeared");
  assertIncludes(settings, "disabled />", "Windows GPU placebo control is enabled");

  console.log(`Windows parity verification passed (${measured.ready} ready, ${measured.adapted} adapted, ${measured.pending} unavailable; all evidence resolved)`);
} catch (error) {
  reportFailure(error);
}
