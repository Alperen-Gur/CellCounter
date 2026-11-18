"""
_cellpose_runtime.py — what actually ran, recorded with every Cellpose result.

`runtime_block(...)` returns the dict a Cellpose sidecar adds to its payload as
``image_stats["runtime"]``:

    schema               1
    cellpose_version     importlib.metadata version of the Cellpose package
    torch_version, torchvision_version, numpy_version
                         the versions loaded in this process (metadata fallback)
    opencv_version, opencv_distribution
                         e.g. "4.13.0.92", "opencv-python-headless"
    python_version       e.g. "3.12.13"
    device               the device the model runs on ("mps", "cpu", "cuda:0")
    model_dtype          dtype of the loaded network's parameters ("bfloat16")
    requested_model      the model name the host asked for
    weights_file         file name of the checkpoint Cellpose loaded (no folder,
                         so exported tables do not carry the user's home path)
    weights_size_bytes, weights_mtime (UTC, ISO 8601), weights_sha256
    accel, accel_patches the `_cellpose_accel` status line and active patches
                         ("not used" when the sidecar does not load it)

The SHA-256 of a checkpoint is computed once per (path, size, modification
time) and kept in a small JSON file in the user's caches folder
(``~/Library/Caches/CellCounter/weights-sha256.json`` on macOS), so a 1.2 GB
checkpoint is not read again for every image. ``CELLCOUNTER_WEIGHTS_HASH_CACHE``
names another file (tests).

Every field is best effort. A value that cannot be read is left out, and
nothing here raises: provenance must never fail a detection.
"""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import os
import platform
import re
import stat
import sys
import tempfile
import threading
from datetime import datetime, timezone

SCHEMA = 1
ENV_HASH_CACHE = "CELLCOUNTER_WEIGHTS_HASH_CACHE"

OPENCV_DISTRIBUTIONS = (
    "opencv-python-headless",
    "opencv-python",
    "opencv-contrib-python-headless",
    "opencv-contrib-python",
)

_CACHE_FORMAT = 1
_CACHE_LIMIT = 64
_CHUNK_BYTES = 8 * 1024 * 1024
_HEX64 = re.compile(r"[0-9a-f]{64}")

# (real path, size, mtime_ns) -> sha256 for this process, so a warm worker
# does not even re-read the JSON file for each image.
_memo: dict = {}
_lock = threading.Lock()


def _stderr(message: str) -> None:
    print(f"[cellpose_detect] {message}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------

def distribution_version(name: str):
    """Installed version of a distribution, or None."""
    try:
        version = importlib.metadata.version(name)
    except Exception:  # noqa: BLE001
        return None
    return str(version) if version else None


def module_version(module_name: str, distribution: str):
    """`__version__` of an imported module (what this process runs), else
    the installed distribution's version."""
    module = sys.modules.get(module_name)
    version = getattr(module, "__version__", None) if module is not None else None
    if isinstance(version, str) and version:
        return str(version)
    return distribution_version(distribution)


def opencv_version():
    """(distribution name, version) of the installed OpenCV, or (None, None)."""
    for name in OPENCV_DISTRIBUTIONS:
        version = distribution_version(name)
        if version:
            return name, version
    cv2 = sys.modules.get("cv2")
    version = getattr(cv2, "__version__", None) if cv2 is not None else None
    return (None, str(version)) if isinstance(version, str) and version else (None, None)


# ---------------------------------------------------------------------------
# The loaded model
# ---------------------------------------------------------------------------

def _owners(model):
    """The model, and the wrapped CellposeModel of a restoration model."""
    owners = [model] if model is not None else []
    inner = getattr(model, "cp", None) if model is not None else None
    if inner is not None:
        owners.append(inner)
    return owners


def model_device(model):
    for owner in _owners(model):
        for candidate in (owner, getattr(owner, "net", None)):
            device = getattr(candidate, "device", None) if candidate is not None else None
            if device is not None:
                return str(device)
    return None


def parameter_dtype(model):
    """dtype of the network's parameters, e.g. "bfloat16" or "float32"."""
    for owner in _owners(model):
        net = getattr(owner, "net", None)
        if net is None:
            continue
        try:
            parameter = next(iter(net.parameters()))
            return str(parameter.dtype).replace("torch.", "")
        except Exception:  # noqa: BLE001
            pass
        dtype = getattr(net, "dtype", None)
        if dtype is not None:
            return str(dtype).replace("torch.", "")
    return None


def loaded_weights_path(model):
    """The checkpoint path Cellpose resolved (`CellposeModel.pretrained_model`)."""
    for owner in _owners(model):
        value = getattr(owner, "pretrained_model", None)
        if isinstance(value, (list, tuple)):
            value = value[0] if value else None
        if isinstance(value, (str, os.PathLike)) and os.fspath(value):
            return os.fspath(value)
    return None


# ---------------------------------------------------------------------------
# Weights checksum, cached by (path, size, mtime)
# ---------------------------------------------------------------------------

def hash_cache_path() -> str:
    override = os.environ.get(ENV_HASH_CACHE)
    if override:
        return override
    home = os.path.expanduser("~")
    if sys.platform == "darwin":
        folder = os.path.join(home, "Library", "Caches", "CellCounter")
    else:
        folder = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(home, ".cache"),
                              "cellcounter")
    return os.path.join(folder, "weights-sha256.json")


def _read_cache(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    entries = data.get("entries") if isinstance(data, dict) else None
    return dict(entries) if isinstance(entries, dict) else {}


def _write_cache(path: str, entries: dict) -> None:
    # Newest last; keep the file small.
    items = list(entries.items())[-_CACHE_LIMIT:]
    folder = os.path.dirname(path) or "."
    temporary = None
    try:
        os.makedirs(folder, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", dir=folder, prefix=".weights-sha256-",
                                         suffix=".tmp", delete=False,
                                         encoding="utf-8") as handle:
            temporary = handle.name
            json.dump({"format": _CACHE_FORMAT, "entries": dict(items)}, handle)
        os.replace(temporary, path)
        temporary = None
    except OSError:
        pass
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def _hash_file(path: str):
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            for block in iter(lambda: handle.read(_CHUNK_BYTES), b""):
                digest.update(block)
    except OSError:
        return None
    return digest.hexdigest()


def weights_sha256(path: str, log=_stderr):
    """SHA-256 of `path`, hashed at most once per (path, size, mtime).

    Returns None when the file cannot be read or changed while it was read
    (a digest of something else must never be recorded).
    """
    try:
        real = os.path.realpath(path)
        info = os.stat(real)
    except OSError:
        return None
    if not stat.S_ISREG(info.st_mode):
        return None
    size, mtime_ns = int(info.st_size), int(info.st_mtime_ns)
    key = (real, size, mtime_ns)
    with _lock:
        cached = _memo.get(key)
    if cached:
        return cached
    cache_file = hash_cache_path()
    entries = _read_cache(cache_file)
    entry = entries.get(real)
    if (isinstance(entry, dict) and entry.get("size") == size
            and entry.get("mtime_ns") == mtime_ns
            and isinstance(entry.get("sha256"), str) and _HEX64.fullmatch(entry["sha256"])):
        digest = entry["sha256"]
    else:
        if log is not None:
            log(f"computing the checksum of {os.path.basename(real)} once, for provenance")
        digest = _hash_file(real)
        if digest is None:
            return None
        try:
            after = os.stat(real)
        except OSError:
            return None
        if (int(after.st_size), int(after.st_mtime_ns)) != (size, mtime_ns):
            return None
        entries.pop(real, None)
        entries[real] = {"size": size, "mtime_ns": mtime_ns, "sha256": digest}
        _write_cache(cache_file, entries)
    with _lock:
        _memo[key] = digest
    return digest


def weights_info(path, log=_stderr) -> dict:
    """File name, size, UTC modification time and SHA-256 of a checkpoint."""
    if not path:
        return {}
    info = {"weights_file": os.path.basename(os.fspath(path))}
    try:
        status = os.stat(path)
    except OSError:
        return info
    if not stat.S_ISREG(status.st_mode):
        return info
    info["weights_size_bytes"] = int(status.st_size)
    modified = datetime.fromtimestamp(status.st_mtime, timezone.utc)
    info["weights_mtime"] = modified.isoformat(timespec="seconds").replace("+00:00", "Z")
    digest = weights_sha256(path, log=log)
    if digest:
        info["weights_sha256"] = digest
    return info


# ---------------------------------------------------------------------------
# Speed patches
# ---------------------------------------------------------------------------

def accel_status() -> dict:
    module = sys.modules.get("_cellpose_accel")
    if module is None:
        return {"accel": "not used"}
    try:
        line = str(module.status())
        patches = [str(name) for name in module.active_patches()]
    except Exception:  # noqa: BLE001
        return {}
    prefix = "cellpose accel: "
    return {"accel": line[len(prefix):] if line.startswith(prefix) else line,
            "accel_patches": patches}


# ---------------------------------------------------------------------------
# The block
# ---------------------------------------------------------------------------

def runtime_block(model=None, requested_model=None, device=None, weights_path=None,
                  package: str = "cellpose", log=_stderr) -> dict:
    """The ``image_stats["runtime"]`` dict. Never raises."""
    block: dict = {"schema": SCHEMA}

    def put(key, compute):
        try:
            value = compute()
        except Exception:  # noqa: BLE001
            return
        if value is not None and value != "":
            block[key] = value

    put("cellpose_version", lambda: distribution_version(package))
    put("torch_version", lambda: module_version("torch", "torch"))
    put("torchvision_version", lambda: module_version("torchvision", "torchvision"))
    put("numpy_version", lambda: module_version("numpy", "numpy"))
    put("opencv_distribution", lambda: opencv_version()[0])
    put("opencv_version", lambda: opencv_version()[1])
    put("python_version", platform.python_version)
    put("device", lambda: str(device) if device is not None else model_device(model))
    put("model_dtype", lambda: parameter_dtype(model))
    put("requested_model", lambda: str(requested_model) if requested_model is not None else None)
    try:
        block.update(weights_info(weights_path or loaded_weights_path(model), log=log))
    except Exception:  # noqa: BLE001
        pass
    try:
        block.update(accel_status())
    except Exception:  # noqa: BLE001
        pass
    return block
