"""Explicit hash-bound host interpreter registry shared by extension adapters.

Registry bindings are host configuration, not portable project authority. No
operation installs packages, searches PATH, or enables an executable plugin.
"""
from __future__ import annotations

import copy
import contextvars
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from _workbench_host_registry import configuration_hash, digest, transact

MAX_BYTES = 2 * 1024 ** 2
MAX_RUNTIMES = 32
MAX_BINDINGS = 512
_registry_path = None
_captures = contextvars.ContextVar("workbench_runtime_captures", default=None)


def begin_request(): return _captures.set({})
def end_request(token): _captures.reset(token)


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def configure(value):
    global _registry_path
    if not isinstance(value, str) or not Path(value).is_absolute() or "\0" in value:
        fail("runtime-registry-path", "Choose an absolute host-local runtime registry path.")
    path = Path(value)
    if path.is_symlink() or not path.parent.is_dir(): fail("runtime-registry-path", "The registry requires an existing local parent and cannot be a file symlink.")
    _registry_path = path.absolute()


def configured_path(): return str(_registry_path) if _registry_path is not None else None


def _path():
    if _registry_path is None: fail("runtime-registry-required", "Configure --runtime-registry (or SDK runtime_registry) before managing host-local interpreters.")
    return _registry_path


def _read():
    path = _path()
    if not path.exists(): return {"schemaVersion": 1, "runtimes": [], "bindings": [], "receipts": []}
    from _workbench_host_registry import read_json
    value = read_json(path, MAX_BYTES, code="runtime-registry")
    if value.get("schemaVersion") != 1 or set(value) - {"schemaVersion", "runtimes", "bindings", "receipts"}:
        fail("invalid-runtime-registry", "The host runtime registry schema is unsupported.")
    for key, maximum in (("runtimes", MAX_RUNTIMES), ("bindings", MAX_BINDINGS), ("receipts", 256)):
        if not isinstance(value.get(key), list) or len(value[key]) > maximum:
            fail("invalid-runtime-registry", "A runtime registry collection exceeds its declared bound.", {"collection": key})
    identities = set()
    for record in value["runtimes"]:
        if not isinstance(record, dict) or set(record) - {"id", "name", "pythonPath", "pythonSha256", "registeredAt", "actor", "environmentHash"} or not {"id", "name", "pythonPath", "pythonSha256", "registeredAt", "actor"}.issubset(record):
            fail("invalid-runtime-registry", "A registered interpreter record has an unsupported structure.")
        if not isinstance(record["id"], str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", record["id"]) or record["id"] in identities:
            fail("invalid-runtime-registry", "Registered interpreter identities must be distinct bounded names.")
        identities.add(record["id"])
        if not isinstance(record["pythonPath"], str) or not Path(record["pythonPath"]).is_absolute() or not isinstance(record["pythonSha256"], str) or not re.fullmatch("[0-9a-f]{64}", record["pythonSha256"]):
            fail("invalid-runtime-registry", "A registered interpreter requires an absolute path and exact lowercase SHA256.")
        if "environmentHash" in record and (not isinstance(record["environmentHash"], str) or not re.fullmatch("[0-9a-f]{64}", record["environmentHash"])):
            fail("invalid-runtime-registry", "An optional observed environment binding requires an exact SHA256.")
    bound = set()
    for binding in value["bindings"]:
        if not isinstance(binding, dict) or set(binding) != {"packageHash", "runtimeId", "boundAt", "actor"} or binding.get("runtimeId") not in identities:
            fail("invalid-runtime-registry", "A plugin binding requires one configured interpreter identity.")
        key = binding.get("packageHash")
        if not isinstance(key, str) or not re.fullmatch("[0-9a-f]{64}", key) or key in bound:
            fail("invalid-runtime-registry", "Plugin package bindings must be distinct exact SHA256 identities.")
        bound.add(key)
    return value


def candidate(value):
    from _workbench_store import file_hash
    if not isinstance(value, str) or not Path(value).is_absolute(): fail("runtime-path", "The interpreter must be an explicitly selected absolute path.")
    lexical = Path(value)
    # Venv interpreter symlinks are a supported explicit binding. Both the
    # lexical path and resolved executable identity are retained/rechecked.
    if not lexical.is_file(): fail("runtime-missing", "The selected interpreter file is unavailable.")
    path = lexical.resolve()
    size = path.stat().st_size
    if not 0 < size <= 512 * 1024 ** 2: fail("runtime-executable-limit", "The selected interpreter must be a nonempty file of at most512MiB.")
    return {"pythonPath": str(lexical.absolute()), "resolvedPath": str(path), "pythonSha256": file_hash(path), "bytes": size, "executed": False}


def _record(registry, identifier):
    record = next((row for row in registry["runtimes"] if row["id"] == identifier), None)
    if record is None: fail("runtime-not-found", "This host has no interpreter registered under that identity.", {"runtimeId": identifier})
    return record


def _public(record):
    return {**copy.deepcopy(record), "present": Path(record["pythonPath"]).is_file(), "readiness": "not-probed"}


def inspect():
    if _registry_path is None:
        return {"configured": False, "configurationHash": "missing", "runtimes": [], "bindings": [], "notes": notes()}
    registry = _read()
    return {"configured": True, "registryPath": str(_registry_path), "configurationHash": configuration_hash(_registry_path, registry),
            "runtimes": [_public(record) for record in registry["runtimes"]], "bindings": copy.deepcopy(registry["bindings"]), "notes": notes()}


def notes():
    return ["Registering or binding an interpreter never enables a plugin and never installs dependencies.",
            "A probe observes isolated Python distribution metadata, not binary reproducibility or available accelerator performance.",
            "Runtime paths and plugin-to-runtime bindings stay on this host; portable files retain only execution evidence."]


def resolve(package_hash=None, runtime_id=None, *, force_default=False):
    registry = _read() if _registry_path is not None and not force_default else {"runtimes": [], "bindings": []}
    selected = None if force_default else runtime_id or next((row["runtimeId"] for row in registry["bindings"] if row["packageHash"] == package_hash), None)
    if selected is None:
        found = candidate(sys.executable)
        return {"kind": "current-runtime", "runtimeId": None, "pythonPath": found["pythonPath"], "pythonSha256": found["pythonSha256"]}
    record = _record(registry, selected); found = candidate(record["pythonPath"])
    if found["pythonSha256"] != record["pythonSha256"]:
        fail("runtime-changed", "The registered interpreter bytes changed. Explicitly register its new identity before executing extensions.", {"runtimeId": selected})
    return {"kind": "registered-runtime", "runtimeId": selected, "pythonPath": record["pythonPath"], "pythonSha256": record["pythonSha256"], **({"environmentHash": record["environmentHash"]} if record.get("environmentHash") else {})}


def metadata_binding(package_hash=None, runtime_id=None):
    """Read configured intent without hashing/executing a host executable."""
    registry = _read() if _registry_path is not None else {"runtimes": [], "bindings": []}
    selected = runtime_id or next((row["runtimeId"] for row in registry["bindings"] if row["packageHash"] == package_hash), None)
    if selected is None: return {"kind": "current-runtime", "runtimeId": None, "pythonPath": sys.executable, "readiness": "not-probed"}
    record = _record(registry, selected)
    return {"kind": "registered-runtime", "runtimeId": selected, "pythonPath": record["pythonPath"], "pythonSha256": record["pythonSha256"], "readiness": "not-probed"}


def identity(binding):
    value = {key: binding[key] for key in ("kind", "runtimeId", "pythonSha256")}
    if binding.get("environmentHash"): value["environmentHash"] = binding["environmentHash"]
    return {**value, "bindingHash": digest(value)}


def capture(binding):
    import _workbench_environment as environments
    cache = _captures.get()
    cache_key = (binding["pythonPath"], identity(binding)["bindingHash"])
    if cache is not None and cache_key in cache: return copy.deepcopy(cache[cache_key])
    worker = Path(__file__).with_name("_workbench_plugin_worker.py")
    env = {key: value for key, value in os.environ.items() if key in ("SYSTEMROOT", "WINDIR", "HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP", "TMPDIR", "LANG", "LC_ALL", "CUDA_VISIBLE_DEVICES")}
    with tempfile.TemporaryDirectory(prefix="cellcounter-runtime-probe-") as directory:
        path = Path(directory) / "environment.json"
        try:
            result = subprocess.run([binding["pythonPath"], "-I", "-B", str(worker), "--capture-only", "--environment", str(path)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as error:
            fail("runtime-probe-failed", "The selected isolated interpreter could not complete the bounded metadata probe.", {"reason": str(error)[:300]})
        if result.returncode != 0 or path.is_symlink() or not path.is_file() or path.stat().st_size > environments.MAX_BYTES:
            fail("runtime-probe-failed", "The interpreter did not return a valid bounded environment inventory.")
        try: value = environments.validate(json.loads(path.read_text("utf-8")))
        except (ValueError, OSError): fail("runtime-probe-failed", "The interpreter returned an invalid observed environment inventory.")
        if cache is not None: cache[cache_key] = value
        return copy.deepcopy(value)


def configure_request(request, plugin=None):
    from _workbench_store import utc_now
    arguments = request["arguments"]
    def mutate(registry):
        if request["operation"] == "runtime.interpreter.register":
            found = candidate(arguments["pythonPath"])
            if found["pythonSha256"] != arguments["pythonSha256"]: fail("runtime-changed", "The interpreter differs from the selected exact SHA256; read its candidate identity again.")
            rows = [row for row in registry["runtimes"] if row["id"] != arguments["runtimeId"]]
            if len(rows) >= MAX_RUNTIMES: fail("runtime-registry-limit", "The host registry supports at most32 interpreters.")
            rows.append({"id": arguments["runtimeId"], "name": arguments["name"], "pythonPath": found["pythonPath"], "pythonSha256": found["pythonSha256"], "registeredAt": utc_now(), "actor": copy.deepcopy(request.get("actor"))})
            if "environmentHash" in arguments: rows[-1]["environmentHash"] = arguments["environmentHash"]
            registry["runtimes"] = sorted(rows, key=lambda row: row["id"])
            return {"runtime": _public(rows[-1]), "executed": False}
        if plugin is None: fail("plugin-required", "Binding a plugin runtime requires an exact retained plugin package.")
        selected = arguments["runtimeId"]
        if selected is not None: _record(registry, selected)
        bindings = [row for row in registry["bindings"] if row["packageHash"] != plugin["packageHash"]]
        if selected is not None:
            if len(bindings) >= MAX_BINDINGS: fail("runtime-binding-limit", "The host registry supports at most512 exact plugin package bindings.")
            bindings.append({"packageHash": plugin["packageHash"], "runtimeId": selected, "boundAt": utc_now(), "actor": copy.deepcopy(request.get("actor"))})
        registry["bindings"] = bindings
        return {"pluginId": plugin["pluginId"], "packageHash": plugin["packageHash"], "runtimeId": selected,
                "enabled": bool(plugin["enabled"]), "executed": False, "trustChanged": False}
    return transact(_path(), request, _read, mutate, context={"packageHash": plugin["packageHash"]} if plugin else None)


def binding_schema():
    from _workbench_schema import _object
    sha = {"type": "string", "minLength": 64, "maxLength": 64, "pattern": "^[0-9a-f]{64}$"}
    return _object({"kind": {"type": "string", "enum": ["current-runtime", "registered-runtime"]},
                    "runtimeId": {"type": ["string", "null"], "minLength": 1, "maxLength": 64},
                    "pythonSha256": sha, "bindingHash": sha, "environmentHash": sha},
                   ["kind", "runtimeId", "pythonSha256", "bindingHash"])


def operations():
    from _workbench_schema import _object, _op, _STRING, _ID
    identifier = {"type": "string", "minLength": 1, "maxLength": 64, "pattern": "^[A-Za-z0-9][A-Za-z0-9_.-]*$"}
    sha = {"type": "string", "pattern": "^[0-9a-f]{64}$", "minLength": 64, "maxLength": 64}
    entries = [
        _op("runtime.registry.inspect", "Read host-local runtime/binding metadata without executing Python.", _object()),
        _op("runtime.interpreter.list", "List explicitly registered local interpreters without probing them.", _object()),
        _op("runtime.interpreter.candidate", "Read the exact executable identity of an explicitly selected interpreter without running it.", _object({"pythonPath": _STRING}, ["pythonPath"])),
        _op("runtime.interpreter.register", "Register exact local interpreter bytes and optional observed environment hash with host configuration CAS; never install or execute packages.", _object({"runtimeId": identifier, "name": {"type": "string", "minLength": 1, "maxLength": 200}, "pythonPath": _STRING, "pythonSha256": sha, "environmentHash": sha, "expectedConfigurationHash": _ID}, ["runtimeId", "name", "pythonPath", "pythonSha256", "expectedConfigurationHash"]), True),
        _op("runtime.interpreter.probe", "Observe distribution metadata using the explicitly registered isolated Python interpreter.", _object({"runtimeId": identifier}, ["runtimeId"])),
        _op("plugin.runtime.bind", "Bind or unbind one exact installed plugin package to a host interpreter; trust remains unchanged.", _object({"pluginId": _ID, "runtimeId": {"type": ["string", "null"], "minLength": 1, "maxLength": 64}, "expectedConfigurationHash": _ID}, ["pluginId", "runtimeId", "expectedConfigurationHash"]), True),
        _op("plugin.runtime.inspect", "Read this exact plugin package's cross-project host runtime intent and declared dependencies without execution.", _object({"pluginId": _ID}, ["pluginId"])),
        _op("plugin.runtime.probe", "Explicitly observe the bound isolated interpreter and validate declared dependencies without loading plugin code.", _object({"pluginId": _ID}, ["pluginId"])),
    ]
    for entry in entries:
        entry["requiresProject"] = entry["name"].startswith("plugin.")
        entry["affectsProjectRevision"] = False
        if entry["mutating"]: entry.update({"requiresExpectedRevision": False, "hostLocalConfiguration": True, "configurationKind": "runtimes"})
        if entry["name"].endswith(".probe"): entry["usesExecutableCode"] = True
    return entries


def execute(request):
    operation, args = request["operation"], request["arguments"]
    if operation in ("runtime.registry.inspect", "runtime.interpreter.list"): return inspect()
    if operation == "runtime.interpreter.candidate": return candidate(args["pythonPath"])
    if operation == "runtime.interpreter.register": return configure_request(request)
    if operation == "runtime.interpreter.probe":
        import _workbench_environment as environments
        binding = resolve(runtime_id=args["runtimeId"]); inventory = capture(binding)
        return {"runtime": identity(binding), "environment": inventory, "summary": environments.summary(inventory), "notes": notes()}
    fail("unknown-operation", "Unsupported host runtime operation.")
