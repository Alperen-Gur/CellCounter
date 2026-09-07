import { readdirSync } from "node:fs";
import { join } from "node:path";
import {
  assert,
  assertFile,
  assertIncludes,
  assertSameMembers,
  DESKTOP_ROOT,
  readJson,
  readText,
  reportFailure,
} from "./lib/verify-utils.mjs";

function stagesBefore(source, command, operation) {
  const start = source.indexOf(`fn ${command}(`);
  assert(start !== -1, `Command missing: ${command}`);
  const end = source.indexOf("\n#[tauri::command]", start);
  const body = source.slice(start, end < 0 ? undefined : end);
  const stage = body.indexOf("stage_python_project(");
  const launch = body.indexOf(operation);
  return stage >= 0 && launch > stage;
}

try {
  const files = readText("python/runtime-files.txt").split(/\r?\n/)
    .map((line) => line.trim()).filter((line) => line && !line.startsWith("#"));
  const expected = readdirSync(join(DESKTOP_ROOT, "python"))
    .filter((name) => name.endsWith(".py") && !name.startsWith("test_"))
    .concat(["pyproject.toml", "uv.lock", "microscopy-requirements.txt"]);
  assertSameMembers(files, expected, "Embedded runtime must cover every production script and dependency manifest");
  assert(new Set(files).size === files.length, "Duplicate runtime resource");
  for (const name of files) {
    assert(!/[\\/]/.test(name) && name !== "." && name !== "..", "Unsafe runtime filename");
    assertFile(`python/${name}`);
  }
  assert(readJson("src-tauri/tauri.conf.json").bundle.resources["../python"] === "python",
    "MSI and NSIS must retain their Python resources");
  assertIncludes(readText("src-tauri/build.rs"), 'include_bytes!', "Runtime must be embedded in the executable");
  const lib = readText("src-tauri/src/lib.rs");
  assertIncludes(lib.slice(lib.indexOf(".setup("), lib.indexOf(".invoke_handler(")),
    "stage_python_project(&handle, &store)", "Startup must finish staging before commands");

  const commands = [
    ["detection/sidecar.rs", "run_detection", "resolve_sidecar("],
    ["detection/sidecar.rs", "detection_availability", "if !script.exists()"],
    ["env/uv.rs", "env_install", "install_cellpose4_env("],
    ["env/uv.rs", "env_availability", "if !python.exists()"],
    ["images/importer.rs", "import_vendor_image", "store.venv_io_python()"],
    ["analysis/training.rs", "run_fine_tune", 'store.python_script("cellpose_train.py")'],
    ["analysis/runner.rs", "assay_availability", "store.python_script("],
    ["analysis/runner.rs", "run_assay", "store.python_script("],
    ["detection/seg_npy.rs", "seg_npy_import", "resolve_helper("],
    ["detection/seg_npy.rs", "seg_npy_export", "resolve_helper("],
    ["export/roi.rs", "export_imagej_roi", "resolve_helper_python("],
  ];
  for (const [path, command, operation] of commands) {
    const source = readText(`src-tauri/src/${path}`);
    assert(stagesBefore(source, command, operation), `${command} must stage before its Python operation`);
    assert(!stagesBefore(source.replaceAll("stage_python_project(", "missing_stage("), command, operation),
      `Missing staging negative control failed for ${command}`);
  }
  console.log("Python staging contract verification passed");
} catch (error) {
  reportFailure(error);
}
