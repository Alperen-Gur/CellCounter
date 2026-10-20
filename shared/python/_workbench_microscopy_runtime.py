"""Bounded host-local adapter to the existing shared TypeScript microscopy engine.

Runtime paths come only from application/CLI startup configuration. Project data
cannot select code, shell arguments or an interpreter. Scientific algorithms are
implemented in shared/microscopy, not copied into this transport module.
"""
from __future__ import annotations

from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tempfile
import uuid

NODE_VERSION = "24.22.0"
OPERATIONS = {"catalogue", "workspace.create", "workspace.import", "workspace.validate", "workspace.export",
              "workspace.compose", "workspace.replay", "workspace.positions", "semantic.render", "lineage.validate", "lineage.build",
              "zarr.inspect", "zarr.plane", "animation.gif"}
_runtime = None


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def _relative(root, value):
    if not isinstance(value, str):
        fail("invalid-microscopy-path", "A runtime/output path must be a relative string.")
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or any(part in (".", "..", "") for part in value.split("/")) or "\\" in value:
        fail("invalid-microscopy-path", "Runtime and artifact paths must stay inside their declared root.")
    result = root
    for part in path.parts:
        result = result / part
        if result.is_symlink():
            fail("invalid-microscopy-path", "Symbolic links are not permitted in retained runtime or worker artifact paths.")
    if root.resolve() not in result.resolve().parents:
        fail("invalid-microscopy-path", "The path escapes its declared root.")
    return result


def configure(node_path, runtime_root):
    global _runtime
    from _workbench_schema import absolute_path
    from _workbench_packages import _json
    node, root = absolute_path(node_path, "microscopyNode"), absolute_path(runtime_root, "microscopyRuntime")
    manifest = root / "microscopy-runtime.json"
    if not node.is_file() or not os.access(node, os.X_OK) or not manifest.is_file() or manifest.stat().st_size > 1024 ** 2:
        fail("microscopy-runtime-unavailable", "Configure the pinned Node executable and packaged microscopy runtime manifest.")
    raw = manifest.read_bytes()
    record = _json(raw, "microscopy runtime manifest")
    if (record.get("schemaVersion") != 1 or record.get("nodeVersion") != NODE_VERSION
            or not isinstance(record.get("files"), list) or not 1 <= len(record["files"]) <= 1024
            or not isinstance(record.get("node"), dict)):
        fail("unsupported-microscopy-runtime", "The microscopy runtime must declare Node " + NODE_VERSION + " and its retained file hashes.")
    names = [entry.get("path") for entry in record["files"]]
    if len(set(names)) != len(names) or record.get("entrypoint") not in names:
        fail("invalid-microscopy-runtime", "The fixed worker entrypoint must be covered by the runtime file manifest.")
    for name in names:
        _relative(root, name)
    _runtime = {"nodePath": str(node), "root": str(root), "manifest": record,
                "manifestHash": hashlib.sha256(raw).hexdigest()}


def describe():
    return {"configured": _runtime is not None, "nodeVersion": NODE_VERSION,
            "engineVersion": _runtime["manifest"].get("engineVersion") if _runtime else None,
            "manifestHash": _runtime["manifestHash"] if _runtime else None,
            "automaticInstallation": False,
            "configuration": "--microscopy-node /absolute/node --microscopy-runtime /absolute/runtime"}


def _verified_runtime():
    from _workbench_store import file_hash
    if _runtime is None:
        fail("microscopy-runtime-unavailable", "This operation requires the packaged microscopy runtime or explicit --microscopy-node and --microscopy-runtime configuration.")
    runtime = _runtime
    root, node = Path(runtime["root"]), Path(runtime["nodePath"])
    manifest = runtime["manifest"]
    if file_hash(root / "microscopy-runtime.json") != runtime["manifestHash"]:
        fail("microscopy-runtime-changed", "The configured runtime manifest changed. Explicitly reconfigure the installed runtime.")
    if node.stat().st_size != manifest["node"]["bytes"] or file_hash(node) != manifest["node"]["sha256"]:
        fail("microscopy-runtime-changed", "The Node executable differs from its configured pinned runtime identity.")
    for entry in manifest["files"]:
        path = _relative(root, entry["path"])
        if not path.is_file() or path.stat().st_size != entry["bytes"] or file_hash(path) != entry["sha256"]:
            fail("microscopy-runtime-changed", "A packaged microscopy engine file differs from its manifest.", {"file": entry["path"]})
    return runtime


def verify_read_set(stores, records):
    """Bind present chunks and absence probes before publishing source provenance."""
    from _workbench_store import file_hash
    roots = {entry["id"]: Path(entry["root"]) for entry in stores}
    if not isinstance(records, list) or len(records) > 65536:
        fail("microscopy-read-limit", "The engine read set exceeds its bounded file count.")
    seen = {}
    for item in records:
        root = roots.get(item.get("storeId"))
        if root is None:
            fail("ungranted-microscopy-source", "The engine referenced an ungranted source directory.")
        path = _relative(root, item.get("path"))
        identity = (item["storeId"], item["path"])
        if identity in seen and seen[identity] != item:
            fail("microscopy-source-changed", "One source path had conflicting read identities during execution.")
        seen[identity] = item
        if item.get("missing") or item.get("sha256") is None:
            if path.exists():
                fail("microscopy-source-changed", "A missing source chunk appeared during computation. Repeat the operation against current data.")
        elif not path.is_file() or path.stat().st_size != item.get("bytes") or file_hash(path) != item.get("sha256"):
            fail("microscopy-source-changed", "Source metadata or chunks changed during computation. No result has been published.")


@contextmanager
def invoke(operation, arguments, *, documents=None, inputs=None, stores=None, timeout=300):
    """Yield verified metadata/artifacts until the caller retains required outputs."""
    from _workbench_store import canonical, file_hash
    from _workbench_packages import _json
    if operation not in OPERATIONS:
        fail("unsupported-microscopy-operation", "The adapter accepts only its fixed operation catalogue.")
    runtime = _verified_runtime()
    stores = stores or []
    if len(stores) > 32 or len({entry["id"] for entry in stores}) != len(stores):
        fail("microscopy-source-limit", "Directory grants must have distinct identities and contain at most 32 roots.")
    for entry in stores:
        path = Path(entry["root"])
        if not path.is_absolute() or not path.is_dir() or path.is_symlink() or path.resolve() != path:
            fail("invalid-microscopy-source", "Source directories must be canonical absolute directories without symlinks.")
    temporary = Path(tempfile.mkdtemp(prefix="cellcounter-microscopy-"))
    try:
        files, total = [], 0
        for index, (identity, value) in enumerate((documents or {}).items()):
            data = value if isinstance(value, bytes) else canonical(value).encode()
            if len(data) > 32 * 1024 ** 2:
                fail("microscopy-input-limit", "A workspace document exceeds 32 MiB.")
            path = temporary / ("document-" + str(index) + ".json")
            path.write_bytes(data)
            files.append({"id": identity, "path": str(path), "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
            total += len(data)
        for index, (identity, value) in enumerate((inputs or {}).items()):
            if any(entry["id"] == identity for entry in files):
                fail("duplicate-microscopy-input", "Document and raster input IDs must be distinct.")
            source, checksum, size = value
            path = temporary / ("input-" + str(index) + ".bin")
            source = Path(source)
            if not source.is_file() or source.is_symlink() or source.stat().st_size != size:
                fail("microscopy-input-changed", "An input artifact no longer has its declared byte length.")
            total += size
            if total > 256 * 1024 ** 2:
                fail("microscopy-input-limit", "Engine inputs exceed 256 MiB; select fewer layers or a bounded source plane.")
            try:
                os.link(source, path)
            except OSError:
                shutil.copyfile(source, path)
            files.append({"id": identity, "path": str(path), "sha256": checksum, "bytes": size})
        if total > 256 * 1024 ** 2 or len(files) > 1024:
            fail("microscopy-input-limit", "Engine inputs exceed their byte/file limit.")
        request_id = str(uuid.uuid4())
        output = temporary / "output"
        response_path = output / "result.json"
        request = {"schemaVersion": 1, "requestId": request_id, "operation": operation, "arguments": arguments,
                   "inputs": files, "stores": stores, "outputDirectory": str(output)}
        request_bytes = canonical(request).encode()
        if len(request_bytes) > 8 * 1024 ** 2:
            fail("microscopy-request-limit", "The engine request exceeds 8 MiB.")
        request_path = temporary / "request.json"
        request_path.write_bytes(request_bytes)
        env = {key: value for key, value in os.environ.items() if key not in ("NODE_OPTIONS", "NODE_PATH")}
        argv = [runtime["nodePath"], str(_relative(Path(runtime["root"]), runtime["manifest"]["entrypoint"])),
                "--request", str(request_path), "--response", str(response_path)]
        with tempfile.TemporaryFile() as diagnostics:
            try:
                process = subprocess.run(argv, cwd=str(temporary), env=env, stdin=subprocess.DEVNULL,
                                         stdout=diagnostics, stderr=diagnostics, timeout=timeout, check=False)
            except subprocess.TimeoutExpired:
                fail("microscopy-timeout", "The bounded microscopy operation exceeded its execution time. No result was committed.")
            if not response_path.is_file() or response_path.is_symlink() or response_path.stat().st_size > 16 * 1024 ** 2:
                diagnostics.seek(0)
                fail("microscopy-worker-failed", "The worker did not publish a bounded response.",
                     {"exitCode": process.returncode, "diagnostic": diagnostics.read(65536).decode("utf-8", "replace")})
        response = _json(response_path.read_bytes(), "microscopy response")
        if (response.get("schemaVersion") != 1 or response.get("requestId") != request_id
                or response.get("operation") != operation or response.get("nodeVersion") != NODE_VERSION):
            fail("microscopy-protocol-mismatch", "The worker returned an incompatible operation or runtime identity.")
        if not response.get("ok"):
            fail(response.get("error", {}).get("code", "microscopy-worker-failed"),
                 response.get("error", {}).get("message", "The microscopy engine failed."))
        outputs, output_bytes = {}, 0
        entries = response.get("outputs")
        if not isinstance(entries, list) or len(entries) > 1024:
            fail("microscopy-output-limit", "The worker output list exceeds its bounded file count.")
        for entry in entries:
            path = _relative(output, entry["path"])
            if entry["id"] in outputs or not path.is_file() or path.stat().st_size != entry["bytes"] or file_hash(path) != entry["sha256"]:
                fail("microscopy-output-changed", "A worker output has a duplicate identity or failed integrity verification.")
            output_bytes += entry["bytes"]
            if output_bytes > 256 * 1024 ** 2:
                fail("microscopy-output-limit", "Worker outputs exceed 256 MiB.")
            outputs[entry["id"]] = {**entry, "absolutePath": path}
        verify_read_set(stores, response.get("readSet", []))
        yield {"result": response["result"], "outputs": outputs, "readSet": response.get("readSet", []),
               "engineVersion": response.get("engineVersion"), "nodeVersion": NODE_VERSION,
               "runtimeManifestHash": runtime["manifestHash"]}
    finally:
        shutil.rmtree(temporary)
