"""Explicit, versioned execution of trusted local Python workbench extensions.

The subprocess boundary contains failures and validates scientific outputs. It
is not an OS security sandbox: enabling a plugin trusts its code with the user's
account. Installing and restoring source bytes never executes them.
"""
from __future__ import annotations

from _workbench_indexed import image_capacity

from _workbench_indexed import image_index

import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid

MAX_MANIFEST_BYTES = 64 * 1024
MAX_SOURCE_BYTES = 1024 * 1024
MAX_RESULT_BYTES = 4 * 1024 * 1024
MAX_LOG_BYTES = 64 * 1024
MAX_EXPORT_BYTES = 128 * 1024 * 1024
MAX_PLUGINS = 128
MAX_RUNS = 1000
SUPPORTED_KINDS = ("segmentation", "measurement", "reader", "exporter")
_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,63}$")
_ID = re.compile(r"^[a-z][a-z0-9.-]{0,127}$")
_VERSION = re.compile(r"^[0-9][A-Za-z0-9.+-]{0,63}$")


def parameter_values_schema():
    return {"type": "object", "properties": {}, "maxProperties": 64,
            "additionalProperties": {"type": ["number", "boolean", "string"], "minLength": 0, "maxLength": 4096}}


def operations():
    from _workbench_schema import _object, _ID as identifier, _STRING, _op, _PARAMETERS
    plugin = {"pluginId": identifier}
    integer = {"type": "integer", "minimum": 0, "maximum": 64000000}
    result = [
        _op("plugin.install", "Retain a local Python manifest and source without executing them; installed disabled.",
            _object({"manifestPath": _STRING}, ["manifestPath"]), True),
        _op("plugin.list", "List retained plugin versions, availability and explicit trust state.", _object()),
        _op("plugin.inspect", "Inspect one retained manifest, parameter controls and source integrity.",
            _object(plugin, ["pluginId"])),
        _op("plugin.setEnabled", "Explicitly trust or disable a retained plugin version. Local code is not sandboxed.",
            _object({**plugin, "enabled": {"type": "boolean"}}, ["pluginId", "enabled"]), True),
        _op("plugin.run", "Execute an enabled local measurement or segmentation plugin on canonical source pixels.",
            _object({**plugin, "imageId": identifier, "parameters": parameter_values_schema(),
                     "target": {"type": "string", "enum": ["plane", "volume"]},
                     "sourceParameters": _PARAMETERS, "timeIndex": integer, "channel": integer},
                    ["pluginId", "imageId"]), True),
        _op("plugin.read", "Execute an enabled single-file reader, retaining its original input and canonical pixel output.",
            _object({**plugin, "path": _STRING, "parameters": parameter_values_schema(),
                     "name": {"type": "string", "minLength": 1, "maxLength": 200}},
                    ["pluginId", "path"]), True),
        _op("plugin.export", "Execute an enabled exporter, retain its output and publish to a new destination without overwriting.",
            _object({**plugin, "imageId": identifier, "destination": _STRING,
                     "parameters": parameter_values_schema(),
                     "target": {"type": "string", "enum": ["plane", "volume"]},
                     "sourceParameters": _PARAMETERS, "timeIndex": integer, "channel": integer},
                    ["pluginId", "imageId", "destination"]), True),
        _op("plugin.results", "Read plugin run metadata with live stale-state checks, or one exact saved output.",
            _object({"imageId": identifier, "runId": identifier})),
    ]
    for entry in result:
        if entry["name"] in ("plugin.run", "plugin.read", "plugin.export"):
            entry["usesExecutableCode"] = True
    next(entry for entry in result if entry["name"] == "plugin.install")["installsExecutableCode"] = True
    return result


def _fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def _digest(value):
    return hashlib.sha256(_canonical(value).encode("utf-8")).hexdigest()


def _finite(value):
    try:
        return type(value) in (int, float) and math.isfinite(value)
    except OverflowError:
        return False


def _json(data, label):
    def pairs(entries):
        result = {}
        for name, value in entries:
            if name in result:
                raise ValueError("Duplicate object key")
            result[name] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=pairs,
                          parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
    except (ValueError, UnicodeError, RecursionError) as exc:
        _fail("invalid-plugin", f"{label} must be finite JSON without duplicate keys.", {"reason": str(exc)[:200]})


def _regular_bytes(path, maximum, label):
    if path.is_symlink() or not path.is_file():
        _fail("invalid-plugin", f"{label} must be a regular file, not a symbolic link.")
    if path.stat().st_size > maximum:
        _fail("plugin-limit", f"{label} exceeds its {maximum}-byte limit.")
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        _fail("plugin-limit", f"{label} exceeds its {maximum}-byte limit.")
    return data


def _scalar(value, spec, field):
    kind = spec["type"]
    valid = ((kind == "boolean" and type(value) is bool) or
             (kind == "integer" and type(value) is int and _finite(value)) or
             (kind == "number" and _finite(value)) or
             (kind == "string" and isinstance(value, str) and "\x00" not in value and
              len(value) <= spec.get("maxLength", 4096)))
    if not valid:
        _fail("invalid-plugin-parameters", f"{field} must be a bounded {kind}.")
    if kind in ("number", "integer") and not (
            spec.get("minimum", -math.inf) <= value <= spec.get("maximum", math.inf)):
        _fail("invalid-plugin-parameters", f"{field} is outside its declared range.")
    if "enum" in spec and not any(type(value) is type(candidate) and value == candidate
                                  for candidate in spec["enum"]):
        _fail("invalid-plugin-parameters", f"{field} is not a declared choice.")


def validate_manifest(value):
    if not isinstance(value, dict) or set(value) - {
            "schemaVersion", "id", "version", "name", "kind", "entryPoint", "parameters",
            "supportedDimensions", "timeoutSeconds", "description", "supportsValidSupport", "dependencies", "resources"}:
        _fail("invalid-plugin", "Manifest has unknown fields or is not an object.")
    if type(value.get("schemaVersion")) is not int or value["schemaVersion"] != 1:
        _fail("invalid-plugin", "Plugin schemaVersion must be 1.")
    if not isinstance(value.get("id"), str) or not _ID.fullmatch(value["id"]):
        _fail("invalid-plugin", "Plugin id must be a bounded lowercase identifier.")
    if not isinstance(value.get("version"), str) or not _VERSION.fullmatch(value["version"]):
        _fail("invalid-plugin", "Plugin version must begin with a digit and use version characters.")
    if not isinstance(value.get("name"), str) or not value["name"].strip() or len(value["name"]) > 200:
        _fail("invalid-plugin", "Plugin name is required and limited to 200 characters.")
    if "description" in value and (not isinstance(value["description"], str) or len(value["description"]) > 2000):
        _fail("invalid-plugin", "Plugin description is limited to 2000 characters.")
    if value.get("kind") not in SUPPORTED_KINDS:
        _fail("unsupported-plugin-kind", "This runtime executes segmentation, measurement, reader and exporter plugins.",
              {"supported": list(SUPPORTED_KINDS)})
    if "supportsValidSupport" in value and type(value["supportsValidSupport"]) is not bool:
        _fail("invalid-plugin", "supportsValidSupport must be a boolean declaring exclusion of unsupported input samples.")
    entry = value.get("entryPoint")
    if not isinstance(entry, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}\.py", entry):
        _fail("invalid-plugin", "entryPoint must name one Python file beside the manifest.")
    dimensions = value.get("supportedDimensions")
    if (not isinstance(dimensions, list) or not dimensions or len(dimensions) > 2 or
            any(type(item) is not int or item not in (2, 3) for item in dimensions) or
            len(set(dimensions)) != len(dimensions)):
        _fail("invalid-plugin", "supportedDimensions must contain 2 and/or 3 without duplicates.")
    timeout = value.get("timeoutSeconds", 30)
    if not _finite(timeout) or not 0.1 <= timeout <= 300:
        _fail("invalid-plugin", "timeoutSeconds must be between 0.1 and 300.")
    schema = value.get("parameters", {"type": "object", "properties": {}, "required": [],
                                      "additionalProperties": False})
    if (not isinstance(schema, dict) or set(schema) - {"type", "properties", "required", "additionalProperties"} or
            schema.get("type") != "object" or schema.get("additionalProperties") is not False or
            not isinstance(schema.get("properties"), dict) or len(schema["properties"]) > 64):
        _fail("invalid-plugin", "parameters must be a closed object schema with at most 64 scalar properties.")
    required = schema.get("required", [])
    if (not isinstance(required, list) or any(not isinstance(key, str) for key in required) or
            len(required) != len(set(required)) or set(required) - set(schema["properties"])):
        _fail("invalid-plugin", "Required parameter names must be unique declared properties.")
    for name, spec in schema["properties"].items():
        if not _NAME.fullmatch(name) or not isinstance(spec, dict) or set(spec) - {
                "type", "title", "description", "minimum", "maximum", "maxLength", "enum", "default"}:
            _fail("invalid-plugin", "Parameter names and schema fields must use supported bounded controls.")
        kind = spec.get("type")
        if kind not in ("number", "integer", "boolean", "string"):
            _fail("invalid-plugin", "Plugin parameters support number, integer, boolean and string controls.")
        for key in ("title", "description"):
            if key in spec and (not isinstance(spec[key], str) or len(spec[key]) > 500):
                _fail("invalid-plugin", f"Parameter {key} is limited to 500 characters.")
        for key in ("minimum", "maximum"):
            if key in spec and (kind not in ("number", "integer") or not _finite(spec[key])):
                _fail("invalid-plugin", "Numeric bounds must be finite and apply to numeric controls.")
        if spec.get("minimum", -math.inf) > spec.get("maximum", math.inf):
            _fail("invalid-plugin", "Parameter minimum exceeds its maximum.")
        if "maxLength" in spec and (kind != "string" or type(spec["maxLength"]) is not int or
                                    not 0 <= spec["maxLength"] <= 4096):
            _fail("invalid-plugin", "String maxLength must be between 0 and 4096.")
        if "enum" in spec:
            if not isinstance(spec["enum"], list) or not 1 <= len(spec["enum"]) <= 64:
                _fail("invalid-plugin", "Parameter choices require between 1 and 64 values.")
            without_enum = {key: item for key, item in spec.items() if key != "enum"}
            for option in spec["enum"]:
                _scalar(option, without_enum, name)
        if "default" in spec:
            _scalar(spec["default"], spec, name)
    result = copy.deepcopy(value)
    if "dependencies" in value:
        import _workbench_environment as environments
        try: result["dependencies"] = environments.normalize_constraints(value["dependencies"])
        except ValueError as error: _fail("invalid-plugin-dependencies", str(error))
    if "resources" in value:
        hints = value["resources"]
        if (not isinstance(hints, dict) or set(hints) - {"memoryMiB", "device", "notes"}
                or ("memoryMiB" in hints and (type(hints["memoryMiB"]) is not int or not 1 <= hints["memoryMiB"] <= 1048576))
                or ("device" in hints and hints["device"] not in ("cpu", "cuda", "mps", "any"))
                or ("notes" in hints and (not isinstance(hints["notes"], str) or len(hints["notes"]) > 2000))):
            _fail("invalid-plugin-resources", "Resources accept bounded memoryMiB, device cpu/cuda/mps/any and descriptive notes. They are declared hints, not observed availability.")
    result["parameters"] = copy.deepcopy(schema)
    result["parameters"]["required"] = list(required)
    result["timeoutSeconds"] = timeout
    return result


def validate_parameters(manifest, supplied=None):
    supplied = {} if supplied is None else supplied
    if not isinstance(supplied, dict) or len(supplied) > 64:
        _fail("invalid-plugin-parameters", "Plugin parameters must be a bounded object.")
    schema = manifest["parameters"]
    unknown = set(supplied) - set(schema["properties"])
    if unknown:
        _fail("invalid-plugin-parameters", "Unknown plugin parameter.", {"names": sorted(map(str, unknown))[:64]})
    result = {key: copy.deepcopy(spec["default"]) for key, spec in schema["properties"].items()
              if "default" in spec}
    result.update(supplied)
    for name in schema["required"]:
        if name not in result:
            _fail("invalid-plugin-parameters", f"Required plugin parameter {name!r} is missing.")
    for name, value in result.items():
        _scalar(value, schema["properties"][name], name)
    return result


def _record(document, plugin_id):
    for record in document.get("plugins", []):
        if record["pluginId"] == plugin_id:
            return record
    _fail("plugin-not-found", "Plugin version is not installed in this project.", {"pluginId": plugin_id})


def _verified(store, record):
    manifest_data = _regular_bytes(store.verify_artifact(record["manifestPath"], record["manifestHash"]),
                                   MAX_MANIFEST_BYTES, "Retained manifest")
    manifest = validate_manifest(_json(manifest_data, "Retained manifest"))
    source = _regular_bytes(store.verify_artifact(record["sourcePath"], record["sourceHash"]),
                            MAX_SOURCE_BYTES, "Retained source")
    package_hash = hashlib.sha256(manifest_data + b"\0" + source).hexdigest()
    if (package_hash != record["packageHash"] or manifest != record["manifest"] or
            record["pluginId"] != manifest["id"] + "@" + manifest["version"]):
        _fail("plugin-changed", "Retained plugin identity differs from its recorded manifest and source.")
    return manifest, source


def install(store, document, manifest_path, revision):
    from _workbench_store import utc_now
    path = Path(manifest_path).expanduser()
    if not path.is_absolute():
        _fail("invalid-path", "manifestPath must be absolute.")
    manifest = validate_manifest(_json(_regular_bytes(path, MAX_MANIFEST_BYTES, "Plugin manifest"), "Plugin manifest"))
    source = _regular_bytes(path.parent / manifest["entryPoint"], MAX_SOURCE_BYTES, "Plugin source")
    try:
        compile(source.decode("utf-8"), manifest["entryPoint"], "exec")
    except (UnicodeError, SyntaxError, ValueError) as exc:
        _fail("invalid-plugin", "Plugin source must be valid UTF-8 Python.", {"reason": str(exc)[:300]})
    manifest_data = (_canonical(manifest) + "\n").encode("utf-8")
    if len(manifest_data) > MAX_MANIFEST_BYTES:
        _fail("plugin-limit", "Normalized manifest exceeds the 64 KiB limit.")
    package_hash = hashlib.sha256(manifest_data + b"\0" + source).hexdigest()
    plugin_id = manifest["id"] + "@" + manifest["version"]
    for previous in document.get("plugins", []):
        if previous["pluginId"] == plugin_id:
            if previous["packageHash"] != package_hash:
                _fail("plugin-version-conflict", "This id and version already retain different source. Use a new version.")
            _verified(store, previous)
            return {"plugin": describe(previous), "alreadyInstalled": True}
    if len(document.get("plugins", [])) >= MAX_PLUGINS:
        _fail("plugin-limit", "A project can retain at most 128 plugin versions.")
    manifest_ref, manifest_hash = store.put_bytes(manifest_data, ".plugin.json")
    source_ref, source_hash = store.put_bytes(source, ".plugin.py")
    record = {"pluginId": plugin_id, "manifest": manifest, "manifestPath": manifest_ref,
              "manifestHash": manifest_hash, "sourcePath": source_ref, "sourceHash": source_hash,
              "packageHash": package_hash, "enabled": False, "installedAt": utc_now(),
              "installedRevision": revision}
    document.setdefault("plugins", []).append(record)
    return {"plugin": describe(record), "alreadyInstalled": False}


def describe(record):
    return {key: copy.deepcopy(record[key]) for key in (
        "pluginId", "manifest", "manifestHash", "sourceHash", "packageHash", "enabled",
        "installedAt", "installedRevision")} | {"executionIsolation": "trusted-local-subprocess",
            "resourcePolicy": {"hintsAreEnforced": False, "enforced": ["declared-timeout", "input-array-bounds", "output-byte-bounds", "log-byte-bounds"], "deviceAvailability": "not-probed"}}


def artifact_references(document):
    result = {}
    for record in document.get("plugins", []):
        result[record["manifestPath"]] = record["manifestHash"]
        result[record["sourcePath"]] = record["sourceHash"]
    for run in document.get("pluginRuns", []):
        result[run["outputPath"]] = run["outputHash"]
        if run.get("environment"):
            result[run["environment"]["inventoryPath"]] = run["environment"]["inventoryHash"]
        for prefix in ("labels", "inputLabels", "support"):
            if prefix + "Path" in run:
                result[run[prefix + "Path"]] = run[prefix + "Hash"]
        if "exportFilePath" in run:
            result[run["exportFilePath"]] = run["exportFileHash"]
    for image in document.get("images", []):
        origin = image.get("readerOrigin")
        if origin:
            result[origin["originalSourcePath"]] = origin["originalSourceHash"]
            if origin.get("environment"):
                result[origin["environment"]["inventoryPath"]] = origin["environment"]["inventoryHash"]
    return result


def _stop(process):
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        elif process.poll() is None:
            process.kill()
    except ProcessLookupError:
        pass


def _directory_size(directory):
    total, entries = 0, 0
    for base, directories, files in os.walk(directory, followlinks=False):
        entries += len(directories) + len(files)
        if entries > 256 or len(Path(base).relative_to(directory).parts) > 4:
            _fail("plugin-limit", "Plugin output contains too many filesystem entries.")
        if any((Path(base) / name).is_symlink() for name in directories):
            _fail("invalid-plugin-output", "Plugin output cannot contain symbolic links.")
        for filename in files:
            path = Path(base) / filename
            if path.is_symlink():
                _fail("invalid-plugin-output", "Plugin output cannot contain symbolic links.")
            try:
                total += path.stat().st_size
            except FileNotFoundError:
                # A plugin may atomically replace its own temporary output.
                continue
    return total


def _read_output_labels(path, shape):
    from _workbench_imaging import require, MAX_CELLS
    np, = require("numpy")
    if path.is_symlink() or not path.is_file() or path.stat().st_size > math.prod(shape) * 4 + 4096:
        _fail("invalid-plugin-output", "Segmentation must return a bounded regular uint32 NPY file.")
    try:
        data = np.load(path, allow_pickle=False, mmap_mode="r", max_header_size=4096)
        if not isinstance(data, np.ndarray) or data.dtype != np.dtype("uint32") or tuple(data.shape) != tuple(shape):
            _fail("invalid-plugin-output", "Plugin label dtype or dimensions differ from the exact input geometry.")
        values = np.unique(data)
        if len(values) - int(0 in values) > MAX_CELLS:
            _fail("plugin-limit", "Plugin segmentation exceeds the 20,000-instance limit.")
        return np.array(data, dtype=np.uint32, order="C", copy=True)
    except (ValueError, OSError, EOFError) as exc:
        _fail("invalid-plugin-output", "Plugin labels are not a valid, non-pickled uint32 NPY array.",
              {"reason": str(exc)[:200]})


def _measurement_output(value, label_ids):
    if not isinstance(value, dict) or set(value) != {"schemaVersion", "measurements", "summary", "units"}:
        _fail("invalid-plugin-output", "Measurement response requires schemaVersion, measurements, summary and units.")
    measurements, summary, units = value["measurements"], value["summary"], value["units"]
    if not isinstance(measurements, list) or len(measurements) > 20000:
        _fail("plugin-limit", "Measurement output is limited to 20,000 instance rows.")
    if (not isinstance(units, dict) or not units or len(units) > 64 or
            any(not _NAME.fullmatch(key) or not isinstance(unit, str) or not unit.strip() or
                len(unit) > 80 or "\x00" in unit for key, unit in units.items())):
        _fail("invalid-plugin-output", "Declare between 1 and 64 named, bounded measurement units.")
    def values_valid(values):
        return (isinstance(values, dict) and not (set(values) - set(units)) and
                all(number is None or _finite(number)
                    for number in values.values()))
    if not values_valid(summary):
        _fail("invalid-plugin-output", "Summary metrics require declared units and finite numeric or null values.")
    seen = set()
    for row in measurements:
        if (not isinstance(row, dict) or set(row) != {"labelId", "values"} or
                type(row["labelId"]) is not int or row["labelId"] not in label_ids or
                row["labelId"] in seen or not values_valid(row["values"])):
            _fail("invalid-plugin-output", "Measurement rows must name distinct current labels and declared finite metrics.")
        seen.add(row["labelId"])
    if not measurements and not summary:
        _fail("invalid-plugin-output", "Measurement response must contain measured values.")
    return value


def _reader_output(value, directory, manifest):
    from _workbench_imaging import require, _bounded, MAX_DECODE_BYTES
    np, = require("numpy")
    if (set(value) - {"schemaVersion", "pixelsPath", "axes", "voxelSizeUm", "timeStepSeconds"} or
            not isinstance(value.get("pixelsPath"), str) or
            not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}\.npy", value["pixelsPath"]) or
            not isinstance(value.get("axes"), str)):
        _fail("invalid-plugin-output", "Reader response requires a NumPy pixel file and explicit supported axes.")
    path = directory / value["pixelsPath"]
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_DECODE_BYTES + 4096:
        _fail("plugin-limit", "Reader pixels must be a bounded regular NumPy file.")
    try:
        array = np.load(path, allow_pickle=False, mmap_mode="r", max_header_size=4096)
        if not isinstance(array, np.ndarray):
            _fail("invalid-plugin-output", "Reader pixels must be one non-pickled NumPy array.")
        _bounded(array.shape, array.dtype, value["axes"])
        if (3 if "Z" in value["axes"] else 2) not in manifest["supportedDimensions"]:
            _fail("invalid-plugin-output", "Reader returned spatial dimensions absent from its manifest.")
        if not np.isfinite(array).all():
            _fail("invalid-plugin-output", "Reader source pixels must be finite.")
        pixels = np.array(array, copy=True)
    except (ValueError, OSError, EOFError) as exc:
        _fail("invalid-plugin-output", "Reader returned invalid NumPy pixels.", {"reason": str(exc)[:200]})
    spacing = value.get("voxelSizeUm", {})
    if not isinstance(spacing, dict) or set(spacing) - {"x", "y", "z"}:
        _fail("invalid-plugin-output", "Reader voxelSizeUm must name x, y and/or z in micrometres.")
    spacing = {axis: spacing.get(axis) for axis in "xyz"}
    for number in [*spacing.values(), value.get("timeStepSeconds")]:
        if number is not None and (not _finite(number) or not 0 < number <= 1000000):
            _fail("invalid-plugin-output", "Reader calibration must be positive, finite and bounded, or null.")
    return {"pixels": pixels, "axes": value["axes"], "voxelSizeUm": spacing,
            "timeStepSeconds": value.get("timeStepSeconds")}


def _invoke(store, record, raw, parameters, labels=None, calibration=None, reader_source=None, measurements=None,
            intensity_units="raw-source", valid_support=None, expected_environment_hash=None,
            expected_runtime_binding=None, legacy_default_runtime=False):
    from _workbench_imaging import require, MAX_PIXELS, MAX_DECODE_BYTES
    from _workbench_volume import MAX_VOLUME_VOXELS
    np, = require("numpy")
    if not record.get("enabled"):
        _fail("plugin-disabled", "Enable this exact plugin version before explicitly executing its trusted local code.")
    manifest, source = _verified(store, record)
    import _workbench_runtimes as runtimes
    runtime = runtimes.resolve(package_hash=record["packageHash"], force_default=legacy_default_runtime)
    runtime_identity = runtimes.identity(runtime)
    if expected_runtime_binding is not None and expected_runtime_binding != runtime_identity:
        _fail("plugin-runtime-changed", "The frozen plugin interpreter binding changed. Restore that explicit binding or save a new workflow/refresh plan.")
    if runtime.get("environmentHash") and expected_environment_hash is not None and runtime["environmentHash"] != expected_environment_hash:
        _fail("plugin-environment-changed", "The registered environment binding differs from the frozen execution plan.")
    expected_environment_hash = expected_environment_hash or runtime.get("environmentHash")
    if (valid_support is not None and not valid_support.all() and manifest["kind"] == "measurement"
            and not manifest.get("supportsValidSupport", False)):
        _fail("unsupported-plugin-support",
              "This measurement plugin must explicitly declare supportsValidSupport and exclude unsupported samples before measuring registered sources.")
    original_shape = None
    support_region = None
    if valid_support is not None and not valid_support.all() and manifest["kind"] == "segmentation":
        from _workbench_support import rectangular_crop
        support_region = rectangular_crop(valid_support)
        original_shape = raw.shape
        raw = raw[support_region]
        valid_support = valid_support[support_region]
        if labels is not None:
            labels = labels[support_region]
    parameters = validate_parameters(manifest, parameters)
    if manifest["kind"] != "reader":
        raw = np.asarray(raw)
        if (raw.ndim not in manifest["supportedDimensions"] or raw.ndim not in (2, 3) or not raw.size or
                raw.size > (MAX_PIXELS if raw.ndim == 2 else MAX_VOLUME_VOXELS) or
                raw.dtype.kind not in "uifb" or raw.nbytes > MAX_DECODE_BYTES or not np.isfinite(raw).all()):
            _fail("invalid-plugin-input", "Plugin requires a supported, bounded finite source plane or volume.")
    elif reader_source is None:
        _fail("invalid-plugin-input", "Reader execution requires a retained single-file input.")
    if manifest["kind"] == "measurement" and (labels is None or labels.shape != raw.shape):
        _fail("analysis-required", "Measurement plugins require current exact labels with matching source geometry.")
    # Every byte sent to the plugin is staged separately from immutable project
    # artifacts. Its outputs are accepted only after shape/schema validation.
    with tempfile.TemporaryDirectory(prefix="cellcounter-plugin-") as directory:
        root = Path(directory)
        output = root / "output"
        output.mkdir()
        entry = root / manifest["entryPoint"]
        entry.write_bytes(source)
        if manifest["kind"] == "reader":
            source_directory = root / "source"
            source_directory.mkdir()
            source_path = source_directory / reader_source["name"]
            checksum = hashlib.sha256()
            with open(reader_source["path"], "rb") as source_stream, source_path.open("wb") as staged:
                for block in iter(lambda: source_stream.read(1024 * 1024), b""):
                    checksum.update(block)
                    staged.write(block)
            if checksum.hexdigest() != reader_source["sha256"]:
                _fail("artifact-changed", "The retained reader input changed while being staged.")
            input_info = {"sourcePath": str(source_path), "sourceName": reader_source["name"],
                          "sourceHash": reader_source["sha256"]}
        else:
            np.save(root / "pixels.npy", raw, allow_pickle=False)
            input_info = {"pixelsPath": str(root / "pixels.npy"), "shape": list(raw.shape),
                          "axes": "YX" if raw.ndim == 2 else "ZYX",
                          "coordinateSpace": "pixel-edges", "intensityUnits": intensity_units,
                          "calibration": calibration or {"x": None, "y": None, "z": None}}
        if labels is not None:
            np.save(root / "labels.npy", labels, allow_pickle=False)
            input_info["labelsPath"] = str(root / "labels.npy")
        if valid_support is not None:
            np.save(root / "valid-support.npy", valid_support.astype(np.uint8), allow_pickle=False)
            input_info["validSupport"] = {"path": str(root / "valid-support.npy"), "dtype": "uint8",
                                          "validSamples": int(valid_support.sum()),
                                          "invalidSamples": int(valid_support.size - valid_support.sum()),
                                          "rule": "exclude zero-valued support samples from every biological measurement"}
        if support_region is not None:
            input_info["sourceRegion"] = {"arraySlices": [[part.start, part.stop] for part in support_region],
                                          "originalShape": list(original_shape),
                                          "outputCoordinates": "local cropped array; host restores original coordinates"}
        if measurements is not None:
            (root / "measurements.json").write_text(_canonical(measurements), encoding="utf-8")
            input_info["measurementsPath"] = str(root / "measurements.json")
        request = {"schemaVersion": 1, "kind": manifest["kind"], "parameters": parameters,
                   "input": input_info, "outputDirectory": str(output)}
        if "dependencies" in manifest: request["dependencies"] = manifest["dependencies"]
        request_path, response_path = root / "request.json", output / "response.json"
        request_path.write_text(_canonical(request), encoding="utf-8")
        environment = {key: value for key, value in os.environ.items()
                       if key in ("PATH", "SYSTEMROOT", "WINDIR", "HOME", "USERPROFILE", "APPDATA",
                                  "LOCALAPPDATA", "TEMP", "TMP", "TMPDIR", "LANG", "LC_ALL",
                                  "CUDA_VISIBLE_DEVICES")}
        budget = ((MAX_DECODE_BYTES if manifest["kind"] == "reader" else MAX_EXPORT_BYTES)
                  if manifest["kind"] in ("reader", "exporter") else int(raw.size) * 4)
        budget += MAX_RESULT_BYTES + MAX_SOURCE_BYTES
        stdout, stderr = root / "stdout.log", root / "stderr.log"
        inventory_path = root / "python-environment.json"
        worker = Path(__file__).resolve().with_name("_workbench_plugin_worker.py")
        started = time.monotonic()
        with stdout.open("wb") as out, stderr.open("wb") as err:
            command = [runtime["pythonPath"], "-I", "-B", str(worker),
                                        "--entry", str(entry), "--request", str(request_path),
                                        "--response", str(response_path), "--environment", str(inventory_path)]
            if expected_environment_hash is not None:
                command.extend(["--expected-environment-hash", expected_environment_hash])
            process = subprocess.Popen(command,
                                       stdin=subprocess.DEVNULL, stdout=out, stderr=err, cwd=output,
                                       env=environment, start_new_session=os.name == "posix")
            try:
                while process.poll() is None:
                    if time.monotonic() - started > manifest["timeoutSeconds"]:
                        _fail("plugin-timeout", "Plugin exceeded its declared execution timeout.")
                    if stdout.stat().st_size + stderr.stat().st_size > MAX_LOG_BYTES:
                        _fail("plugin-output-limit", "Plugin logs exceeded 64 KiB.")
                    if _directory_size(output) > budget:
                        _fail("plugin-output-limit", "Plugin output exceeded its bounded result budget.")
                    time.sleep(0.02)
                if stdout.stat().st_size + stderr.stat().st_size > MAX_LOG_BYTES or _directory_size(output) > budget:
                    _fail("plugin-output-limit", "Plugin output exceeded its bounded result budget.")
                if process.returncode != 0:
                    if process.returncode == 43:
                        error = stderr.read_bytes()[:4096].decode("utf-8", errors="replace")
                        _fail("plugin-dependencies-unsatisfied", "The actual isolated interpreter does not satisfy the plugin's declared dependencies. Configure an appropriate runtime; no packages were installed.", {"reason": error})
                    if process.returncode == 42 and expected_environment_hash is not None:
                        import _workbench_environment as environments
                        observed = _json(_regular_bytes(inventory_path, environments.MAX_BYTES, "Plugin environment"), "Plugin environment")
                        if observed.get("hash") != expected_environment_hash:
                            _fail("plugin-environment-changed", "The isolated measurement-plugin environment changed after the refresh plan. Restore the recorded environment or create a new plan.")
                    error = stderr.read_bytes()[:4096].decode("utf-8", errors="replace")
                    _fail("plugin-failed", "Plugin subprocess failed.", {"exitCode": process.returncode, "stderr": error})
            finally:
                _stop(process)
                process.wait(timeout=5)
        response = _json(_regular_bytes(response_path, MAX_RESULT_BYTES, "Plugin response"), "Plugin response")
        if not isinstance(response, dict) or type(response.get("schemaVersion")) is not int or response["schemaVersion"] != 1:
            _fail("invalid-plugin-output", "Plugin response schemaVersion must be 1.")
        if manifest["kind"] == "segmentation":
            if (set(response) != {"schemaVersion", "labelsPath"} or not isinstance(response["labelsPath"], str) or
                    not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}\.npy", response["labelsPath"])):
                _fail("invalid-plugin-output", "Segmentation response must name one uint32 NPY file in outputDirectory.")
            result = _read_output_labels(output / response["labelsPath"], raw.shape)
            if support_region is not None:
                restored = np.zeros(original_shape, dtype=np.uint32)
                restored[support_region] = result
                result = restored
        elif manifest["kind"] == "measurement":
            result = _measurement_output(response, set(map(int, np.unique(labels))) - {0})
        elif manifest["kind"] == "reader":
            result = _reader_output(response, output, manifest)
        else:
            if (set(response) != {"schemaVersion", "filePath", "mediaType"} or
                    not isinstance(response["filePath"], str) or
                    not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]{0,127}", response["filePath"]) or
                    ".." in response["filePath"] or
                    not isinstance(response["mediaType"], str) or
                    not re.fullmatch(r"[A-Za-z0-9.+-]{1,60}/[A-Za-z0-9.+-]{1,80}", response["mediaType"])):
                _fail("invalid-plugin-output", "Exporter response requires one ordinary filename and a bounded MIME mediaType.")
            contents = _regular_bytes(output / response["filePath"], MAX_EXPORT_BYTES, "Exported file")
            if not contents:
                _fail("invalid-plugin-output", "Exporter returned an empty file.")
            result = {"contents": contents, "filename": response["filePath"], "mediaType": response["mediaType"]}
        import _workbench_environment as environments
        observed = _json(_regular_bytes(inventory_path, environments.MAX_BYTES, "Plugin environment"), "Plugin environment")
        try:
            observed = environments.retain(store, observed)
        except ValueError as exc:
            _fail("invalid-environment-record", str(exc))
        provenance = {"pluginId": record["pluginId"], "packageHash": record["packageHash"],
                      "pluginSourceHash": record["sourceHash"], "manifestHash": record["manifestHash"],
                      "parameters": parameters, "pythonVersion": observed["summary"]["pythonVersion"],
                      "environment": observed,
                      "runtime": runtime_identity,
                      "dependencyConstraints": copy.deepcopy(manifest.get("dependencies")),
                      "executionIsolation": "trusted-local-subprocess"}
        if support_region is not None:
            provenance["supportRegion"] = {"arraySlices": [[part.start, part.stop] for part in support_region],
                                            "originalShape": list(original_shape)}
        return result, provenance


def predict(store, document, plugin_id, raw, parameters=None):
    """Run the identical segmentation protocol without mutating project state."""
    record = _record(document, plugin_id)
    if record["manifest"]["kind"] != "segmentation":
        _fail("unsupported-plugin-kind", "Prediction requires a segmentation plugin.")
    return _invoke(store, record, raw, parameters)


def freeze_step(document, step):
    """Resolve a workflow's declarative plugin node to one immutable version."""
    record = _record(document, step["pluginId"])
    expected_kind = {"plugin-segmentation": "segmentation", "plugin-measurement": "measurement"}[step["type"]]
    if record["manifest"]["kind"] != expected_kind:
        _fail("invalid-workflow", f"This node requires a {expected_kind} plugin.")
    if step.get("packageHash", record["packageHash"]) != record["packageHash"]:
        _fail("plugin-changed", "The workflow names a different retained version hash.")
    result = copy.deepcopy(step)
    import _workbench_runtimes as runtimes
    binding = runtimes.identity(runtimes.resolve(package_hash=record["packageHash"]))
    if "pluginRuntimeBinding" in step and step["pluginRuntimeBinding"] != binding:
        _fail("plugin-runtime-changed", "This saved plugin node names a different host interpreter binding. Rebind it explicitly or save a new definition.")
    result.update({"packageHash": record["packageHash"], "usesExecutableCode": True,
                   "pluginRuntimeBinding": binding,
                   "pluginParameters": validate_parameters(record["manifest"], step.get("pluginParameters"))})
    return result


def execute_step(store, document, step, checkpoint, revision, hooks=None):
    record = _record(document, step["pluginId"])
    if record["packageHash"] != step["packageHash"]:
        _fail("plugin-changed", "The saved workflow's exact plugin version is unavailable.")
    arguments = {"pluginId": step["pluginId"], "imageId": checkpoint["imageId"],
                 "parameters": step["pluginParameters"],
                 "target": "volume" if "timeIndex" in checkpoint else "plane"}
    if "timeIndex" in checkpoint:
        arguments.update({key: checkpoint[key] for key in ("timeIndex", "channel")})
    elif "sourceParameters" in step:
        arguments["sourceParameters"] = step["sourceParameters"]
    return execute(store, document, "plugin.run", arguments, revision, hooks,
                   expected_runtime_binding=step.get("pluginRuntimeBinding"),
                   legacy_default_runtime="pluginRuntimeBinding" not in step)


def checkpoint_outputs_current(document, checkpoint, runs=None):
    runs = runs if runs is not None else {run["runId"]: run for run in document.get("pluginRuns", [])}
    for result in checkpoint.get("stepResults", []):
        if "pluginRunId" not in result:
            continue
        run = runs.get(result["pluginRunId"])
        if (run is None or run["outputHash"] != result["outputHash"] or
                run["packageHash"] != result["packageHash"]):
            return False
    return True


def _state_fingerprint(image, target, time_index=None, channel=None):
    import _workbench_support as support
    support_value = {"validSupport": support.fingerprint(image)} if support.descriptor(image) else {}
    if target == "plane":
        analysis = image.get("analysis")
        if analysis is None:
            return _digest({"sourceHash": image["sourceHash"], "shape": image["shape"],
                            "pxPerUm": image["pxPerUm"], "voxelSizeUm": image.get("voxelSizeUm"),
                            "analysis": None, **support_value})
        value = {"sourceHash": image["sourceHash"], "shape": image["shape"],
                 "parameters": analysis["parameters"], "labelsHash": analysis["labelsHash"],
                 "pxPerUm": image["pxPerUm"], "voxelSizeUm": image.get("voxelSizeUm"),
                 "engineVersion": analysis["engineVersion"], **support_value}
    else:
        from _workbench_volume import get_frame, analysis_fingerprint
        frame = get_frame(image, time_index, channel, required=False)
        if frame:
            return analysis_fingerprint(image, frame)
        return _digest({"sourceHash": image["sourceHash"], "shape": image["shape"],
                        "voxelSizeUm": image.get("voxelSizeUm"), "timeIndex": time_index,
                        "channel": channel, "analysis": None, **support_value})
    return _digest(value)


def results(store, document, arguments):
    from _workbench_store import MAX_RESPONSE_BYTES
    runs = document.get("pluginRuns", [])
    if "runId" in arguments:
        runs = [run for run in runs if run["runId"] == arguments["runId"]]
        if not runs:
            _fail("plugin-run-not-found", "The requested plugin run is not retained.")
    if "imageId" in arguments:
        runs = [run for run in runs if run["imageId"] == arguments["imageId"]]
    images = image_index(document)
    output = []
    verified = set()
    def verify_once(path, checksum):
        if (path, checksum) not in verified:
            store.verify_artifact(path, checksum)
            verified.add((path, checksum))
    for run in runs[-100:]:
        image = images.get(run["imageId"])
        current = _state_fingerprint(image, run["target"], run.get("timeIndex"), run.get("channel")) if image else None
        item = {key: copy.deepcopy(value) for key, value in run.items() if key not in ("outputPath",)}
        item["stale"] = current != run["currentFingerprint"]
        if image:
            verify_once(image["sourcePath"], image["sourceHash"])
            analysis = image.get("analysis") if run["target"] == "plane" else next(
                (frame for frame in image.get("volumeFrames", []) if
                 frame["timeIndex"] == run["timeIndex"] and frame["channel"] == run["channel"]), None)
            if analysis:
                verify_once(analysis["labelsPath"], analysis["labelsHash"])
        if "runId" in arguments:
            path = store.verify_artifact(run["outputPath"], run["outputHash"])
            item["output"] = _json(_regular_bytes(path, MAX_RESULT_BYTES, "Retained plugin output"), "Retained plugin output")
        output.append(item)
    result = {"runs": output, "total": len(runs), "returned": len(output)}
    if len(_canonical(result).encode("utf-8")) > MAX_RESPONSE_BYTES - 4096:
        _fail("result-too-large", "Inspect individual plugin run outputs to stay within the response budget.")
    return result


def _retain_reader_source(store, path):
    from _workbench_schema import absolute_path
    from _workbench_store import MAX_SOURCE_BYTES, file_hash
    source = absolute_path(path, "path")
    if not source.is_file():
        _fail("invalid-path", "Reader plugins import one existing regular source file.")
    if source.stat().st_size > MAX_SOURCE_BYTES:
        _fail("image-too-large", "Reader input is limited to 512 MiB.")
    directory = store.root / "artifacts"
    if directory.is_symlink() or directory.resolve().parent != store.root:
        _fail("project-corrupt", "Artifact directory is outside the project.")
    temporary = None
    try:
        checksum, size = hashlib.sha256(), 0
        with tempfile.NamedTemporaryFile(dir=directory, prefix=".reader-input-", delete=False) as target:
            temporary = Path(target.name)
            with source.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    size += len(block)
                    if size > MAX_SOURCE_BYTES:
                        _fail("image-too-large", "Reader input exceeded 512 MiB while being retained.")
                    checksum.update(block)
                    target.write(block)
            target.flush()
            os.fsync(target.fileno())
        digest = checksum.hexdigest()
        relative = f"artifacts/{digest}.reader-source"
        destination = store.root / relative
        try:
            os.link(temporary, destination)
        except FileExistsError:
            if destination.is_symlink() or file_hash(destination) != digest:
                _fail("artifact-changed", "An immutable retained reader input has changed.")
        return relative, digest, size, source
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def read_source(store, document, arguments, revision):
    from _workbench_imaging import require, inspect_source
    from _workbench_store import utc_now
    import io
    record = _record(document, arguments["pluginId"])
    if record["manifest"]["kind"] != "reader":
        _fail("unsupported-plugin-kind", "plugin.read requires a reader plugin.")
    if not record.get("enabled"):
        _fail("plugin-disabled", "Enable the reader's exact retained version before executing it.")
    if len(document["images"]) >= image_capacity(document):
        _fail("project-too-large", "A project can retain at most 1,000 images.")
    _verified(store, record)
    reference, original_hash, size, source = _retain_reader_source(store, arguments["path"])
    result, provenance = _invoke(store, record, None, arguments.get("parameters"),
                                  reader_source={"path": store.artifact_path(reference),
                                                 "name": source.name, "sha256": original_hash})
    np, tifffile = require("numpy", "tifffile")
    axes = result["axes"].replace("S", "C")
    canonical_axes = "".join(axis for axis in "TCZYX" if axis in axes)
    array = np.transpose(result["pixels"], tuple(axes.index(axis) for axis in canonical_axes))
    metadata = {"axes": canonical_axes}
    for axis, spacing in result["voxelSizeUm"].items():
        if spacing is not None:
            metadata["PhysicalSize" + axis.upper()] = spacing
            metadata["PhysicalSize" + axis.upper() + "Unit"] = "µm"
    if result["timeStepSeconds"] is not None:
        metadata.update({"TimeIncrement": result["timeStepSeconds"], "TimeIncrementUnit": "s"})
    output = io.BytesIO()
    tifffile.imwrite(output, array, ome=True, photometric="minisblack", metadata=metadata)
    contents = output.getvalue()
    pixel_path, pixel_hash = store.put_bytes(contents, ".reader.ome.tif")
    imported = inspect_source(store.artifact_path(pixel_path))
    created = utc_now()
    origin = {**provenance, "originalSourcePath": reference, "originalSourceHash": original_hash,
              "originalSourceBytes": size, "originalName": source.name,
              "reportedAxes": result["axes"], "canonicalAxes": imported["axes"],
              "createdRevision": revision, "createdAt": created}
    image = {"id": str(uuid.uuid4()), "name": arguments.get("name", source.name[:200]),
             "sourcePath": pixel_path, "sourceHash": pixel_hash, "sourceBytes": len(contents),
             "importedAt": created, "pxPerUm": imported["metadataPxPerUm"],
             "voxelSizeUm": imported["voxelSizeUm"], "timeStepSeconds": imported["timeStepSeconds"],
             "calibrationSource": "reader" if any(imported["voxelSizeUm"].values()) else "unknown",
             "readerOrigin": origin, "undoStack": [],
             **{key: imported[key] for key in ("width", "height", "channels", "axes", "shape",
                                               "dtype", "zCount", "timeCount")}}
    document["images"].append(image)
    return {"importedImageIds": [image["id"]], "imageId": image["id"],
            "image": {key: value for key, value in image.items() if key not in ("sourcePath", "undoStack")},
            "reader": provenance}


def prepare_export(store, document, arguments, revision, hooks):
    """Retain one exporter result, then use the store's durable publication intent."""
    from _workbench_schema import absolute_path, analysis_parameters
    from _workbench_store import utc_now, sync_directory
    import _workbench_volume as volume
    record = _record(document, arguments["pluginId"])
    if record["manifest"]["kind"] != "exporter":
        _fail("unsupported-plugin-kind", "plugin.export requires an exporter plugin.")
    if not record.get("enabled"):
        _fail("plugin-disabled", "Enable the exporter's exact retained version before executing it.")
    if len(document.get("pluginRuns", [])) >= MAX_RUNS:
        _fail("plugin-limit", "This project retains 1,000 plugin runs.")
    destination = absolute_path(arguments["destination"], "destination")
    if not destination.parent.is_dir():
        _fail("invalid-path", "Exporter destination parent directory must exist.")
    if destination.exists():
        _fail("destination-exists", "Plugin exports never overwrite an existing destination.")
    image = hooks["image"](document, arguments["imageId"])
    target = arguments.get("target", "plane")
    analysis = None
    if target == "volume":
        if "timeIndex" not in arguments or "channel" not in arguments or "sourceParameters" in arguments:
            _fail("invalid-arguments", "Volume exports require timeIndex and channel without plane sourceParameters.")
        time_index, channel = arguments["timeIndex"], arguments["channel"]
        raw = volume.load_source(store, image, time_index, channel)
        if volume.get_frame(image, time_index, channel, required=False):
            analysis = volume.current_frame(store, image, time_index, channel)
        labels = volume.read_labels(store, image, analysis) if analysis else None
        selection = {"timeIndex": time_index, "channel": channel}
    else:
        if "timeIndex" in arguments or "channel" in arguments:
            _fail("invalid-arguments", "Plane exports use sourceParameters for selection.")
        time_index = channel = None
        if image.get("analysis"):
            analysis = hooks["current_analysis"](store, image)
            parameters = analysis["parameters"]
            if any(arguments.get("sourceParameters", {}).get(key, parameters[key]) != parameters[key]
                   for key in ("channel", "zProjection")):
                _fail("invalid-arguments", "An analyzed export uses its saved mask's source selection.")
            labels = hooks["labels"](store, image)
        else:
            parameters = analysis_parameters({"parameters": {
                **image.get("preferredSourceParameters", {}), **arguments.get("sourceParameters", {})}})
            labels = None
        raw = hooks["source"](store, image, parameters)
        selection = {"sourceParameters": parameters}
    measured = None if analysis is None else {
        "imageId": image["id"], "cells": analysis["cells"], "parameters": analysis["parameters"],
        "analysisRevision": analysis["analysisRevision"], "measurementRevision": analysis["measurementRevision"],
        "coordinateSpace": "pixel-edges", "voxelSizeUm": volume.calibration(image),
        "intensityUnits": "processed-source" if image.get("derivation") else "raw-source"}
    import _workbench_support as support
    valid = support.load(store, image, raw.shape, selection.get("sourceParameters"))
    if measured is not None:
        measured["validSupport"] = support.summary(image, valid, raw.shape)
    result, provenance = _invoke(store, record, raw, arguments.get("parameters"), labels,
                                  volume.calibration(image), measurements=measured,
                                  intensity_units="processed-source" if image.get("derivation") else "raw-source",
                                  valid_support=valid)
    file_path, file_hash = store.put_bytes(result["contents"], ".plugin-export")
    payload = {"schemaVersion": 1, "filePath": file_path, "sha256": file_hash,
               "filename": result["filename"], "mediaType": result["mediaType"],
               "bytes": len(result["contents"]), "selection": selection}
    output_path, output_hash = store.put_bytes((_canonical(payload) + "\n").encode("utf-8"), ".plugin-output.json")
    fingerprint = _state_fingerprint(image, target, time_index, channel)
    run = {"runId": str(uuid.uuid4()), "imageId": image["id"], "kind": "exporter", "target": target,
           "revision": revision, "createdAt": utc_now(), "sourceHash": image["sourceHash"],
           "sourceFingerprint": fingerprint, "currentFingerprint": fingerprint,
           "outputPath": output_path, "outputHash": output_hash, "exportFilePath": file_path,
           "exportFileHash": file_hash, "destination": str(destination), "mediaType": result["mediaType"],
           **selection, **provenance}
    if analysis:
        run.update({"inputLabelsPath": analysis["labelsPath"], "inputLabelsHash": analysis["labelsHash"]})
    if support.descriptor(image):
        run.update({"supportPath": support.descriptor(image)["path"], "supportHash": support.descriptor(image)["hash"]})
    document.setdefault("pluginRuns", []).append(run)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".cellcounter-plugin-export-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(result["contents"])
            stream.flush()
            os.fsync(stream.fileno())
        def cleanup():
            try:
                if os.path.samefile(destination, temporary):
                    destination.unlink()
                    sync_directory(destination.parent)
            except FileNotFoundError:
                pass
        def publish():
            try:
                os.link(temporary, destination)
            except FileExistsError:
                _fail("destination-exists", "Plugin exports never overwrite an existing destination.")
            try:
                sync_directory(destination.parent)
            except OSError:
                cleanup()
                raise
            return cleanup
        reply = {"run": {key: value for key, value in run.items() if key != "outputPath"} | {"stale": False},
                 "destination": str(destination), "sha256": file_hash, "mediaType": result["mediaType"],
                 "bytes": len(result["contents"])}
        return reply, publish, temporary, {"destination": str(destination), "sha256": file_hash}
    except Exception:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
        raise


def execute(store, document, operation, arguments, revision, hooks=None, *, expected_environment_hash=None,
            expected_runtime_binding=None, legacy_default_runtime=False):
    from _workbench_store import utc_now
    from _workbench_schema import analysis_parameters
    import _workbench_volume as volume
    if operation == "plugin.install":
        return install(store, document, arguments["manifestPath"], revision)
    if operation == "plugin.read":
        return read_source(store, document, arguments, revision)
    if operation == "plugin.list":
        entries = []
        from _workbench_schema import WorkbenchError
        for record in document.get("plugins", []):
            item = describe(record)
            try:
                _verified(store, record)
                item["available"] = True
            except WorkbenchError as error:
                item["available"] = False
                item["error"] = {"code": error.code, "message": error.message}
            entries.append(item)
        return {"plugins": entries, "supportedKinds": list(SUPPORTED_KINDS),
                "executionIsolation": "trusted-local-subprocess"}
    if operation == "plugin.results":
        return results(store, document, arguments)
    record = _record(document, arguments["pluginId"])
    if operation == "plugin.inspect":
        _verified(store, record)
        return {"plugin": describe(record)}
    if operation == "plugin.setEnabled":
        if arguments["enabled"]:
            _verified(store, record)
        record["enabled"] = arguments["enabled"]
        return {"plugin": describe(record)}
    if operation != "plugin.run":
        _fail("unknown-operation", "Unknown plugin operation.")
    if record["manifest"]["kind"] not in ("measurement", "segmentation"):
        _fail("unsupported-plugin-kind", "Use plugin.read or plugin.export for reader and exporter plugins.")
    if not record.get("enabled"):
        _fail("plugin-disabled", "Enable this exact plugin version before executing its trusted local code.")
    if len(document.get("pluginRuns", [])) >= MAX_RUNS:
        _fail("plugin-limit", "This project retains 1,000 plugin runs. Export and start a new project to retain more.")
    if hooks is None:
        import _workbench_core as core
        hooks = {"image": core._image, "source": core._source, "labels": core._labels,
                 "current_analysis": core._current_analysis, "set_analysis": core._set_analysis}
    image = hooks["image"](document, arguments["imageId"])
    target = arguments.get("target", "plane")
    measurement = record["manifest"]["kind"] == "measurement"
    time_index, channel = arguments.get("timeIndex"), arguments.get("channel")
    if target == "volume":
        if time_index is None or channel is None or "sourceParameters" in arguments:
            _fail("invalid-arguments", "Volume plugins require timeIndex and channel, without plane sourceParameters.")
        raw = volume.load_source(store, image, time_index, channel)
        frame = volume.current_frame(store, image, time_index, channel) if measurement else None
        labels = volume.read_labels(store, image, frame) if frame else None
        source_parameters = None
    else:
        if time_index is not None or channel is not None:
            _fail("invalid-arguments", "Plane plugins select channels through sourceParameters, not volume selectors.")
        if measurement:
            if "sourceParameters" in arguments:
                _fail("invalid-arguments", "Measurements use the saved analysis source selection.")
            analysis = hooks["current_analysis"](store, image)
            source_parameters = analysis["parameters"]
            labels = hooks["labels"](store, image)
        else:
            source_parameters = analysis_parameters({"parameters": {
                **image.get("preferredSourceParameters", {}),
                **arguments.get("sourceParameters", image.get("analysis", {}).get("parameters", {}))}})
            labels = None
        raw = hooks["source"](store, image, source_parameters)
    before = _state_fingerprint(image, target, time_index, channel)
    import _workbench_support as support
    valid = support.load(store, image, raw.shape, source_parameters)
    result, provenance = _invoke(store, record, raw, arguments.get("parameters"), labels, volume.calibration(image),
                                  intensity_units="processed-source" if image.get("derivation") else "raw-source",
                                  valid_support=valid, expected_environment_hash=expected_environment_hash,
                                  expected_runtime_binding=expected_runtime_binding, legacy_default_runtime=legacy_default_runtime)
    if measurement:
        output = result
        scientific_result = None
    else:
        if target == "plane":
            scientific_result = hooks["set_analysis"](store, image, result, raw, source_parameters, revision)
            saved = image["analysis"]
        else:
            saved = volume.save_frame(store, image, raw, result, volume.parameters(), time_index, channel, revision)
            scientific_result = volume.result(image, saved)
        output = {"schemaVersion": 1, "labelsPath": saved["labelsPath"], "labelsHash": saved["labelsHash"],
                  "shape": list(result.shape), "cellCount": len(saved["cells"])}
    output_path, output_hash = store.put_bytes((_canonical(output) + "\n").encode("utf-8"), ".plugin-output.json")
    run = {"runId": str(uuid.uuid4()), "imageId": image["id"], "target": target,
           "kind": record["manifest"]["kind"], "revision": revision, "createdAt": utc_now(),
           "sourceFingerprint": before, "currentFingerprint": _state_fingerprint(image, target, time_index, channel),
           "sourceHash": image["sourceHash"], "sourceParameters": copy.deepcopy(source_parameters),
           "outputPath": output_path, "outputHash": output_hash, **provenance}
    if support.descriptor(image):
        run.update({"supportPath": support.descriptor(image)["path"], "supportHash": support.descriptor(image)["hash"],
                    "validSupport": support.summary(image, valid, raw.shape)})
    if target == "volume":
        run.update({"timeIndex": time_index, "channel": channel})
    if measurement:
        run.update({"measurementCount": len(output["measurements"]), "summary": output["summary"], "units": output["units"]})
        current = image["analysis"] if target == "plane" else frame
        run.update({"inputLabelsPath": current["labelsPath"], "inputLabelsHash": current["labelsHash"]})
    else:
        run.update({"labelsPath": saved["labelsPath"], "labelsHash": saved["labelsHash"]})
    document.setdefault("pluginRuns", []).append(run)
    reply = {"run": {key: value for key, value in run.items() if key != "outputPath"} | {"stale": False}}
    if scientific_result is not None:
        reply["analysis"] = scientific_result
    return reply


def capture_environment(package_hash=None, *, legacy_default_runtime=False):
    """Observe one effective interpreter per request without loading plugin code."""
    import _workbench_runtimes as runtimes
    return runtimes.capture(runtimes.resolve(package_hash=package_hash, force_default=legacy_default_runtime))
