import {
  assert,
  assertEqual,
  assertIncludes,
  importTypeScriptModule,
  readText,
  reportFailure,
} from "./lib/verify-utils.mjs";

const EXPECTED_IDS = ["cpsam_v2", "cp-cyto3", "sd-fluo", "cp4-cpsam_v2", "cp4-cpdino", "cp4-cpdino-vitb", "cp-cyto3-r", "cp-cyto2", "cp-nuclei", "sd-he", "sd-dsb2018", "omni-bact-phase", "omni-bact-fluor", "omni-cyto2", "cw-otsu", "cw-triangle", "cw-adaptive", "cw-manual"];

try {
  const catalogModule = await importTypeScriptModule("src/pages/models/catalog.ts");
  const catalog = catalogModule.MODEL_CATALOG;
  assert(Array.isArray(catalog), "model catalog did not export an array");
  assertEqual(JSON.stringify(catalog.map((model) => model.id)), JSON.stringify(EXPECTED_IDS), "runnable model order or membership changed");
  assert(catalog.every((model) => model.available === true), "every catalog model must be runnable");
  assertEqual(new Set(catalog.map((model) => model.id)).size, EXPECTED_IDS.length, "model ids must be unique");
  assertEqual(catalogModule.ACTIVE_MODEL_ID, "cp-cyto3", "default model changed");

  const sidecar = readText("src-tauri/src/detection/sidecar.rs");
  const allowlistBlock = sidecar.match(/pub const WINDOWS_MODEL_IDS[^=]*=\s*\[([\s\S]*?)\];/)?.[1] ?? "";
  const nativeIds = [...allowlistBlock.matchAll(/"([^"]+)"/g)].map(match => match[1]);
  assertEqual(JSON.stringify(nativeIds.sort()), JSON.stringify([...EXPECTED_IDS, "cp4-cpsam"].sort()), "native model allowlist differs from catalog plus explicit legacy alias");
  assertIncludes(sidecar, '"cpsam_v2" => Some("cpsam")', "CPSAM mapping changed");
  assertIncludes(sidecar, '"cp-cyto3" | "cp-cyto3-r" => Some("cyto3")', "cyto3 mapping changed");
  assertIncludes(sidecar, '"sd-fluo" => Some("2D_versatile_fluo")', "StarDist mapping changed");
  assertIncludes(sidecar, "_ => None", "unknown model ids no longer fail closed");
  assertIncludes(sidecar, 'Err(format!("unsupported model id: {model_id}"))', "unknown model sidecar error is missing");
  assertIncludes(sidecar, "enforce_windows_runtime_contract(&mut params)", "detection IPC trust-boundary normalization disappeared");
  assertIncludes(sidecar, "params.checkpoint_path = None", "client checkpoint injection is no longer discarded");
  assertIncludes(sidecar, "params.use_gpu = false", "CPU-only Windows runtime is no longer enforced by the backend");
  assertIncludes(sidecar, 'model_id.starts_with("cp-cyto3@")', "derived cyto3 lineage is not explicitly resolved");
  assertIncludes(sidecar, "checkpoint.starts_with(&models_dir)", "derived checkpoint is not confined to Models");

  const environment = readText("src-tauri/src/env/uv.rs");
  assertIncludes(environment, "if !is_supported_model(&model_id)", "environment installer does not enforce the allowlist");
  assertIncludes(environment, "Unsupported model id", "environment installer error is not actionable");
  const pyproject = readText("python/pyproject.toml");
  assertIncludes(pyproject, 'torch = { index = "pytorch-cpu" }', "Windows Torch install is no longer deterministically CPU-only");

  const cpsam = readText("python/cellpose4_detect.py");
  assertIncludes(cpsam, 'if raw_model not in ("cpsam", "cpsam_v2", "cpdino", "cpdino-vitb"):', "Cellpose 4 sidecar must use its exact checkpoint allowlist");
  assertIncludes(cpsam, "raise ValueError", "Cellpose-SAM sidecar does not reject unknown names");
  const stardist = readText("python/stardist_detect.py");
  assertIncludes(stardist, 'MODEL_NAME = "2D_versatile_fluo"', "StarDist checkpoint changed");
  assertIncludes(stardist, 'if args.model not in ("2D_versatile_fluo", "2D_versatile_he", "2D_paper_dsb2018"):', "StarDist sidecar must reject unknown checkpoint names");

  const settings = readText("src/pages/settings/SettingsPage.tsx");
  assertIncludes(settings, "MODEL_CATALOG.filter(model => model.available)", "Settings must derive installable defaults from the shared catalog");
  assertIncludes(settings, "value: activeModelId", "Settings must retain imported or derived model selection");
  assertIncludes(settings, "GPU unavailable in Windows", "Settings does not disclose the CPU-only runtime");

  const store = readText("src/kernel/store/store.ts");
  assertIncludes(store, "useGpu: false", "Windows analysis defaults still request GPU");
  assertIncludes(store, "setUseGpu: () => set({ useGpu: false })", "a persisted/UI action can still enable placebo GPU mode");

  const fineTune = readText("src/pages/finetune/FineTunePage.tsx");
  assertIncludes(fineTune, "cp-cyto3@${version.id}", "fine-tuned versions are not represented as cyto3 lineage");
  assertIncludes(fineTune, "mixedPrecision: false", "CPU training still requests mixed precision");
  const training = readText("src-tauri/src/analysis/training.rs");
  assertIncludes(training, '.args(["--base-model", "cp-cyto3"])', "fine-tuning can leave the cyto3 family");
  assertIncludes(training, "Refusing to record a checkpoint outside CellCounter's model store.", "trained checkpoint insertion is not confined");

  console.log(`Windows model catalog verification passed (${EXPECTED_IDS.length} catalog entries, explicit native aliases, confined cyto3 lineage, CPU-only runtime)`);
} catch (error) {
  reportFailure(error);
}
