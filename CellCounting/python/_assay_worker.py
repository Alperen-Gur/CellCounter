"""Serialized assay host with bounded prepared-pixel caches.

The CLI entry points remain the numerical implementation. Only decoding and
polygon rasterization are cached; every request reruns its assay with its own
arguments. There is no display-image or result cache. SIGTERM cancels an active
request by retiring the host; a fresh process starts with empty caches.
"""
from __future__ import annotations

import collections
import contextlib
import copy
import hashlib
import importlib
import io
import json
import os
import sys
import traceback

# CLI execution and assay imports must share the same cache instance.
if __name__ == "__main__":
    sys.modules["_assay_worker"] = sys.modules[__name__]


class PreparedDataCache:
    """Byte- and entry-bounded LRU. Clients receive private working copies."""
    def __init__(self, max_bytes=128 * 1024 * 1024, max_entries=8):
        self.max_bytes = max(0, max_bytes)
        self.max_entries = max(0, max_entries)
        self.entries = collections.OrderedDict()
        self.bytes = 0
        self.hits = 0
        self.misses = 0

    @staticmethod
    def size(value):
        # Arrays include their raw storage, dict/list metadata is counted too.
        if hasattr(value, "nbytes"):
            return int(value.nbytes) + 128
        if isinstance(value, dict):
            return 128 + sum(PreparedDataCache.size(k) + PreparedDataCache.size(v)
                             for k, v in value.items())
        if isinstance(value, (list, tuple)):
            return 64 + sum(PreparedDataCache.size(v) for v in value)
        if isinstance(value, str):
            return len(value.encode("utf-8")) + 64
        if isinstance(value, bytes):
            return len(value) + 64
        return 64

    def get_or_load(self, key, loader):
        if key in self.entries:
            self.hits += 1
            value, cost = self.entries.pop(key)
            self.entries[key] = (value, cost)
            return copy.deepcopy(value)
        self.misses += 1
        value = loader()
        cost = self.size(key) + self.size(value)
        if cost <= self.max_bytes and self.max_entries:
            while self.entries and (self.bytes + cost > self.max_bytes
                                    or len(self.entries) >= self.max_entries):
                _, (_, old_cost) = self.entries.popitem(last=False)
                self.bytes -= old_cost
            # The caller may normalize or edit its returned mask in-place.
            # A private retained copy prevents cross-request contamination.
            self.entries[key] = (copy.deepcopy(value), cost)
            self.bytes += cost
        return value

    def clear(self):
        self.entries.clear()
        self.bytes = 0


CACHE = PreparedDataCache()


def file_identity(path):
    canonical = os.path.realpath(os.fspath(path))
    stat = os.stat(canonical)  # Missing/unreadable files must never use stale data.
    return (canonical, stat.st_dev, stat.st_ino, stat.st_size,
            stat.st_mtime_ns, stat.st_ctime_ns)


def cached_file_load(namespace, path, loader, parameters=()):
    identity = file_identity(path)
    def stable_load():
        value = loader()
        if file_identity(path) != identity:
            raise OSError("Input changed while it was being read; retry the assay.")
        return value
    return CACHE.get_or_load((namespace, identity, parameters), stable_load)


def cached_value(namespace, descriptor, loader):
    # Content identity allows freshly exported temporary mask JSON to reuse
    # rasterization, while every coordinate/label/order/shape edit invalidates.
    encoded = json.dumps(descriptor, sort_keys=True, separators=(",", ":"),
                         allow_nan=False).encode("utf-8")
    return CACHE.get_or_load((namespace, hashlib.sha256(encoded).digest()), loader)


def load_raw_planes(path, *, z_project="max", channel=None):
    import _imageio
    return cached_file_load("raw-planes", path,
                            lambda: _imageio.load_planes(path, z_project=z_project, channel=channel),
                            (z_project, channel))


ASSAYS = {"area_assays_detect.py", "puncta_detect.py", "neurite_outgrowth.py",
          "intensity_assays.py"}
MAX_REQUEST_BYTES = 4 * 1024 * 1024
MAX_RESPONSE_BYTES = 128 * 1024 * 1024


class LimitedOutput(io.StringIO):
    def __init__(self):
        super().__init__()
        self.bytes_written = 0
    def write(self, value):
        self.bytes_written += len(value.encode("utf-8"))
        if self.bytes_written > MAX_RESPONSE_BYTES:
            raise ValueError("Assay output exceeds the response limit.")
        return super().write(value)


def execute(args):
    if not isinstance(args, list) or not args or not all(isinstance(arg, str) for arg in args):
        raise ValueError("args must contain an assay name and string arguments")
    if args[0] not in ASSAYS:
        raise ValueError("Unknown assay")
    output = LimitedOutput()
    previous_argv = sys.argv
    code = 0
    try:
        sys.argv = list(args)
        with contextlib.redirect_stdout(output):
            module = importlib.import_module(args[0][:-3])
            module.main()
    except SystemExit as exc:
        code = exc.code if isinstance(exc.code, int) else 1
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        code = 1
        output = io.StringIO(json.dumps({"error": "assay-failed", "hint": str(exc)}))
    finally:
        sys.argv = previous_argv
    return code, output.getvalue()


def serve():
    while True:
        line = sys.stdin.buffer.readline(MAX_REQUEST_BYTES + 1)
        if not line:
            return
        if len(line) > MAX_REQUEST_BYTES:
            # A truncated request cannot be safely resynchronized.
            return
        request_id = None
        try:
            request = json.loads(line)
            request_id = request.get("request_id")
            if not isinstance(request_id, str):
                raise ValueError("request_id must be a string")
            code, output = execute(request.get("args"))
        except Exception as exc:
            code, output = 2, json.dumps({"error": "invalid-request", "hint": str(exc)})
        response = {"request_id": request_id, "exit_code": code, "stdout": output,
                    "worker_pid": os.getpid(),
                    "cache": {"entries": len(CACHE.entries), "bytes": CACHE.bytes,
                              "hits": CACHE.hits, "misses": CACHE.misses}}
        sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    if sys.argv[1:] != ["--serve"]:
        raise SystemExit("Use --serve for the assay request protocol.")
    serve()
