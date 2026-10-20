"""Shared host-only configuration CAS, receipt and atomic publication primitives."""
from __future__ import annotations

import contextlib
import copy
import hashlib
import json
import os
import stat
from pathlib import Path
import tempfile


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()


def digest(value): return hashlib.sha256(encoded(value)).hexdigest()


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def configuration_hash(path, registry):
    return digest({key: value for key, value in registry.items() if key != "receipts"}) if path.exists() else "missing"


def read_json(path, maximum, *, private=False, code="host-configuration"):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > maximum:
        fail(code, "A local configuration file is missing, linked, or exceeds its size limit.")
    mode = path.stat()
    if private and os.name != "nt" and (mode.st_uid != os.getuid() or stat.S_IMODE(mode.st_mode) & 0o077):
        fail(code + "-permissions", "The credential file must be owned by the current user and readable only by that user (mode0600).")
    def pairs(entries):
        result = {}
        for key, value in entries:
            if key in result: raise ValueError("Duplicate key")
            result[key] = value
        return result
    try:
        with path.open("rb") as stream: data = stream.read(maximum + 1)
        if len(data) > maximum: raise ValueError("Byte limit")
        value = json.loads(data, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Nonfinite")))
    except (ValueError, OSError, UnicodeError, RecursionError): fail(code, "The local configuration must be bounded finite JSON with unique keys.")
    if not isinstance(value, dict): fail(code, "The local configuration must be a JSON object.")
    return value


@contextlib.contextmanager
def locked(path):
    path = Path(path)
    if path.is_symlink() or not path.parent.is_dir(): fail("host-configuration-path", "Select a host registry in an existing local directory without a file symlink.")
    lock = path.with_name(path.name + ".lock")
    if lock.is_symlink(): fail("host-configuration-path", "A configuration lock cannot be a symbolic link.")
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(lock, flags, 0o600), "r+b") as stream:
        if os.name == "nt":
            import msvcrt
            if stream.seek(0, 2) == 0: stream.write(b"0"); stream.flush()
            stream.seek(0); msvcrt.locking(stream.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        try: yield
        finally:
            if os.name == "nt": stream.seek(0); msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else: fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def publish(path, value, maximum):
    payload = encoded(value)
    if len(payload) > maximum: fail("host-configuration-limit", "The host registry and bounded retry receipts exceed their byte budget.")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".workbench-registry-", delete=False) as stream:
            temporary = Path(stream.name); os.chmod(temporary, 0o600)
            stream.write(payload); stream.flush(); os.fsync(stream.fileno())
        if path.is_symlink(): fail("host-configuration-path", "The host registry became a symbolic link during publication.")
        os.replace(temporary, path)
        if os.name != "nt":
            descriptor = os.open(path.parent, os.O_RDONLY)
            try: os.fsync(descriptor)
            finally: os.close(descriptor)
    finally:
        if temporary is not None: temporary.unlink(missing_ok=True)


def transact(path, request, read, mutate, *, maximum=2 * 1024 ** 2, receipt_limit=256,
             conflict_code="host-configuration-conflict", context=None):
    """Call mutate only after exact replay and configuration CAS checks."""
    identifier = request.get("requestId")
    if not isinstance(identifier, str) or not identifier: fail("invalid-request", "Host configuration writes require an explicit requestId.")
    identity = {"operation": request["operation"], "arguments": request["arguments"], "actor": request.get("actor")}
    if context is not None: identity["context"] = context
    request_hash = digest(identity)
    with locked(path):
        registry = read()
        for receipt in registry.get("receipts", []):
            if receipt.get("requestId") == identifier:
                if receipt.get("requestHash") != request_hash: fail("request-id-reused", "This requestId belongs to a different host configuration write.")
                return copy.deepcopy(receipt["result"])
        if request["arguments"]["expectedConfigurationHash"] != configuration_hash(path, registry):
            fail(conflict_code, "Host configuration changed. Read its current configurationHash before explicitly retrying this edit.")
        result = mutate(registry)
        result["configurationHash"] = digest({key: value for key, value in registry.items() if key != "receipts"})
        registry["receipts"] = (registry.get("receipts", []) + [{"requestId": identifier, "requestHash": request_hash, "result": result}])[-receipt_limit:]
        publish(path, registry, maximum)
        return result
