"""Durable launch intents and token-bound controls for local batch workers."""
from __future__ import annotations

from contextlib import contextmanager
from contextvars import ContextVar
import copy
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time
import uuid

ACTIVE = frozenset(("queued", "starting", "running", "stopping"))
TERMINAL = frozenset(("stopped", "completed", "paused", "cancelled", "blocked", "failed", "attention", "interrupted", "awaiting-review"))
MAX_WORKERS = 1000
MAX_STATUS_BYTES = 64 * 1024
HEARTBEAT_SECONDS = 5
LOST_SECONDS = 120
_OWNED_PROJECT = ContextVar("cellcounter_owned_batch_project", default=None)


def operations():
    from _workbench_schema import _object, _op, _ID
    entries = [
        _op("job.worker.start", "Commit a local background worker intent and continue an existing pending or running workflow job.",
            _object({"jobId": _ID}, ["jobId"]), True),
        _op("sweep.worker.start", "Commit a background worker intent for every remaining canonical checkpoint in a parameter sweep.",
            _object({"sweepId": _ID}, ["sweepId"]), True),
        _op("refresh.worker.start", "Commit a background worker intent for remaining frozen downstream measurement refresh units.",
            _object({"refreshId": _ID}, ["refreshId"]), True),
        _op("tiled.analysis.worker.start", "Commit a background worker intent for canonical tiled-analysis checkpoints.",
            _object({"analysisId": _ID}, ["analysisId"]), True),
        _op("job.worker.status", "Read a background worker's heartbeat, checkpoint progress and terminal reason.",
            _object({"workerId": _ID}, ["workerId"])),
        _op("job.worker.stop", "Queue a durable stop marker; pause after the current checkpoint without interrupting computation.",
            _object({"workerId": _ID, "reason": {"type": "string", "minLength": 1, "maxLength": 500}},
                    ["workerId"]), True),
        _op("job.worker.list", "Read retained local background workers without starting or restarting them.", _object()),
    ]
    for entry in entries:
        if entry["name"] in ("job.worker.start", "sweep.worker.start", "refresh.worker.start", "tiled.analysis.worker.start"):
            entry["startsBackgroundWorker"] = True
        if entry["name"] == "job.worker.stop":
            entry["requiresExpectedRevision"] = False
            entry["controlMutation"] = "durable-stop-marker"
    return entries


def fail(code, message):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message)


def _root(store, create=False):
    root = store.root / "workers"
    if root.is_symlink():
        fail("project-corrupt", "The worker directory cannot be a symbolic link.")
    if create:
        root.mkdir(exist_ok=True)
    if root.exists() and (not root.is_dir() or root.resolve().parent != store.root):
        fail("project-corrupt", "The worker directory must remain inside its project.")
    return root


def directory(store, worker, create=False):
    worker_id = worker["workerId"]
    try:
        if str(uuid.UUID(worker_id)) != worker_id:
            raise ValueError()
    except (ValueError, TypeError):
        fail("project-corrupt", "Invalid worker identity.")
    root = _root(store, create)
    path = root / worker_id
    if path.is_symlink():
        fail("project-corrupt", "Worker state cannot be a symbolic link.")
    if create:
        path.mkdir(exist_ok=True)
    if path.exists() and (not path.is_dir() or path.resolve().parent != root):
        fail("project-corrupt", "Worker state must remain inside its project directory.")
    return path


def write_json(path, value):
    from _workbench_store import canonical, sync_directory
    if path.is_symlink():
        fail("project-corrupt", "A worker state file cannot be a symbolic link.")
    encoded = (canonical(value) + "\n").encode()
    if len(encoded) > MAX_STATUS_BYTES:
        fail("worker-state-limit", "Worker control metadata exceeds its bounded size.")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".worker-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def read_json(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_STATUS_BYTES:
        fail("invalid-worker-state", "Worker control metadata is unavailable or exceeds its bounded size.")
    try:
        with path.open("rb") as stream:
            data = stream.read(MAX_STATUS_BYTES + 1)
        if len(data) > MAX_STATUS_BYTES:
            raise ValueError()
        value = json.loads(data)
    except (ValueError, UnicodeError, RecursionError):
        fail("invalid-worker-state", "Worker control metadata is invalid JSON.")
    if not isinstance(value, dict):
        fail("invalid-worker-state", "Worker control metadata must be an object.")
    return value


class ProjectLock:
    """Kernel-owned lock, released on process exit; never remove its inode."""
    def __init__(self, store):
        self.store, self.stream = store, None

    def acquire(self):
        path = _root(self.store, True) / ".active.lock"
        if path.is_symlink():
            fail("project-corrupt", "The project worker lock cannot be a symbolic link.")
        descriptor = os.open(str(path), os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
        stream = os.fdopen(descriptor, "r+b", buffering=0)
        try:
            if os.fstat(stream.fileno()).st_size == 0:
                stream.write(b"\0")
            stream.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            stream.close()
            return False
        self.stream = stream
        return True

    def close(self):
        if self.stream is not None:
            self.stream.close()
            self.stream = None


@contextmanager
def advance_guard(store):
    if _OWNED_PROJECT.get() == str(store.root):
        yield
        return
    lock = ProjectLock(store)
    if not lock.acquire():
        fail("worker-active", "A workflow unit or background worker already owns this project. Stop it after its checkpoint before advancing manually.")
    try:
        document = store.read()
        workers = document.get("jobWorkers", [])
        if workers and describe(store, document, workers[-1])["status"] in ACTIVE:
            fail("worker-active", "A queued background worker owns the next checkpoint. Stop it before advancing manually.")
        yield
    finally:
        lock.close()


@contextmanager
def start_guard(store):
    lock = ProjectLock(store)
    if not lock.acquire():
        fail("worker-active", "Another workflow unit or background worker owns this project.")
    try:
        yield
    finally:
        lock.close()


@contextmanager
def owned_project(store):
    """Only the child holding ProjectLock enters this process-local context."""
    token = _OWNED_PROJECT.set(str(store.root))
    try:
        yield
    finally:
        _OWNED_PROJECT.reset(token)


def record(document, worker_id):
    for worker in document.get("jobWorkers", []):
        if worker["workerId"] == worker_id:
            return worker
    fail("worker-not-found", "The selected background worker does not belong to this project.")


def token_hash(worker):
    return hashlib.sha256(worker["runToken"].encode()).hexdigest()


def target_identity(worker):
    """Interpret old job-only worker records without rewriting their binding."""
    kind = worker.get("targetKind", "job")
    if kind not in ("job", "sweep", "refresh", "tiled-analysis"):
        fail("invalid-worker-target", "The worker target kind is unsupported.")
    field = "analysisId" if kind == "tiled-analysis" else kind + "Id"
    target_id = worker.get("targetId", worker.get(field))
    if not isinstance(target_id, str) or not target_id or worker.get(field, target_id) != target_id:
        fail("invalid-worker-target", "The worker's target identifiers are inconsistent.")
    return {"targetKind": kind, "targetId": target_id, field: target_id}


def target_protocol(worker):
    identity = target_identity(worker)
    if identity["targetKind"] == "tiled-analysis":
        return {"prefix": "tiled.analysis", "idField": "analysisId", "resultKey": "analysis"}
    kind = identity["targetKind"]
    return {"prefix": kind, "idField": kind + "Id", "resultKey": kind}


def _tiled_definition(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical({key: value[key] for key in
        ("id", "sourceId", "metadataHash", "selection", "region", "tileSize", "halo", "grid", "tileCount", "parameters", "engineVersion")}).encode()).hexdigest()


def target_state(document, worker):
    """Read target progress and binding without copying image measurements."""
    from _workbench_workflows import get_job, next_unit, job_progress
    identity = target_identity(worker)
    if identity["targetKind"] == "tiled-analysis":
        import _workbench_tiled as tiled
        import _workbench_zarr as zarr_sources
        value = tiled._analysis(document, identity["targetId"])
        source = zarr_sources.source(document, value["sourceId"])
        if _tiled_definition(value) != worker["analysisDefinitionHash"] or source["path"] != worker["sourcePath"]:
            fail("tiled-definition-changed", "The frozen tiled definition or authorized source location changed; start a new worker explicitly.")
        descriptor = tiled.describe(value)
        return {**identity, "status": value["status"], "progress": descriptor["progress"],
                "nextUnit": descriptor["nextUnit"], **({"error": value["error"]} if value.get("error") else {})}
    if identity["targetKind"] == "job":
        job = get_job(document, identity["targetId"])
        if job["definitionHash"] != worker["workflowDefinitionHash"]:
            fail("workflow-changed", "The worker's immutable workflow definition changed.")
        return {**identity, "status": job["status"], "progress": job_progress(job),
                "nextUnit": next_unit(job), **({"error": job["error"]} if job.get("error") else {})}
    if identity["targetKind"] == "refresh":
        import _workbench_refresh as refresh
        job = refresh.get(document, identity["targetId"])
        if job["definitionHash"] != worker["refreshDefinitionHash"]:
            fail("refresh-changed", "The worker's frozen downstream refresh definition changed.")
        descriptor = refresh.describe(document, job, compact=True)
        return {**identity, "status": job["status"], "progress": descriptor["progress"],
                "nextUnit": descriptor["nextUnit"], **({"error": job["error"]} if job.get("error") else {})}
    import _workbench_sweeps as sweeps
    sweep = sweeps.get(document, identity["targetId"])
    if sweep["definitionHash"] != worker["sweepDefinitionHash"]:
        fail("sweep-changed", "The worker's immutable sweep definition changed.")
    children = sweeps._jobs(document, sweep)
    state = sweeps.status(document, sweep, children)
    selected = sweeps.next_job(document, sweep, children)
    unit = next_unit(selected) if selected else None
    if unit is not None:
        unit = {**unit, "jobId": selected["id"], "combinationIndex": next(
            item["index"] for item in sweep["combinations"] if item["jobId"] == selected["id"])}
    progress = [job_progress(job) for job in children]
    error = next((job["error"] for job in children if job.get("error") and
                  job["status"] in ("blocked", "failed")), None)
    if error is None and state == "blocked" and sweeps.stale_sources(document, sweep):
        error = {"code": "stale-sweep-input", "message": "Original sweep inputs changed. Create a new sweep to use them."}
    return {**identity, "status": state,
            "progress": {"completed": sum(item["completed"] for item in progress),
                         "total": sum(item["total"] for item in progress)},
            "nextUnit": unit, **({"error": error} if error else {})}


def stop_marker(store, worker):
    path = directory(store, worker) / "stop.json"
    if not path.exists():
        return None
    value = read_json(path)
    if value.get("workerId") != worker["workerId"] or value.get("tokenHash") != token_hash(worker):
        fail("worker-control-mismatch", "The stop marker does not belong to this worker.")
    return value


def describe(store, document, worker):
    result = {key: copy.deepcopy(value) for key, value in worker.items() if key != "runToken"}
    result.update(target_identity(worker))
    result["stopRequested"] = False
    if store is None or worker.get("status") in TERMINAL:
        try:
            target = target_state(document, worker)
            result.update({"targetStatus": target["status"], "progress": target["progress"],
                           target_protocol(worker)["resultKey"] + "Status": target["status"]})
        except Exception as exc:
            result.setdefault("error", {"code": "worker-target-unavailable", "message": str(exc)[:2000]})
        return result
    try:
        path = directory(store, worker)
        status = path / "status.json"
        if status.exists():
            state = read_json(status)
            if state.get("workerId") != worker["workerId"] or state.get("tokenHash") != token_hash(worker):
                fail("worker-control-mismatch", "The worker status belongs to a different run.")
            result.update({key: value for key, value in state.items()
                           if key not in ("tokenHash", "workerId", "jobId", "sweepId", "refreshId", "actor",
                                          "targetKind", "targetId", "workflowDefinitionHash", "sweepDefinitionHash", "refreshDefinitionHash", "analysisDefinitionHash", "analysisId", "sourcePath")})
        marker = stop_marker(store, worker)
        if marker:
            result.update({"stopRequested": True, "stopRequest": {
                key: marker[key] for key in ("requestId", "actor", "reason", "requestedAt")}})
            if result["status"] in ACTIVE:
                result["status"] = "stopping"
        heartbeat = path / "heartbeat.json"
        if heartbeat.exists():
            beat = read_json(heartbeat)
            if beat.get("workerId") != worker["workerId"] or beat.get("tokenHash") != token_hash(worker):
                fail("worker-control-mismatch", "The worker heartbeat belongs to a different run.")
            result["heartbeatAt"] = beat["heartbeatAt"]
            last_seen = beat["unixTime"]
        else:
            from datetime import datetime
            last_seen = datetime.fromisoformat(worker["createdAt"].replace("Z", "+00:00")).timestamp()
        target = target_state(document, worker)
        if target["status"] in ("completed", "cancelled", "blocked", "failed", "paused", "awaiting-review") and result["status"] in ACTIVE:
            result["status"] = target["status"]
            if target.get("error"):
                result["error"] = target["error"]
        elif result["status"] in ACTIVE and time.time() - last_seen > LOST_SECONDS:
            result.update({"status": "interrupted", "error": {
                "code": "worker-heartbeat-lost",
                "message": "The worker heartbeat stopped. Start a new worker explicitly after checking its target."}})
        result.update({"targetStatus": target["status"], "progress": target["progress"],
                       target_protocol(worker)["resultKey"] + "Status": target["status"]})
    except Exception as exc:
        result.update({"status": "interrupted", "error": {"code": "worker-state-unavailable", "message": str(exc)[:2000]}})
    return result


def inspect_workers(store, document):
    return [describe(store, document, worker) for worker in document.get("jobWorkers", [])]


def prepare_start(store, document, request, actor):
    from _workbench_workflows import get_job, check_inputs
    from _workbench_store import utc_now
    workers = document.setdefault("jobWorkers", [])
    if len(workers) >= MAX_WORKERS:
        fail("worker-limit", "A project retains at most 1,000 background worker records.")
    if request["operation"] == "tiled.analysis.worker.start":
        import _workbench_tiled as tiled
        import _workbench_zarr as zarr_sources
        value = tiled._analysis(document, request["arguments"]["analysisId"])
        if value["status"] not in ("pending", "running"):
            fail("invalid-tiled-state", "Explicitly resume this tiled analysis before starting a worker.")
        source = zarr_sources.source(document, value["sourceId"])
        if source["metadataHash"] != value["metadataHash"]:
            fail("zarr-source-changed", "The frozen tiled source metadata changed.")
        target = {"targetKind": "tiled-analysis", "targetId": value["id"], "analysisId": value["id"],
                  "analysisDefinitionHash": _tiled_definition(value), "sourcePath": source["path"]}
    elif request["operation"] == "refresh.worker.start":
        import _workbench_refresh as refresh
        job = refresh.get(document, request["arguments"]["refreshId"])
        if job["status"] not in ("pending", "running"):
            fail("invalid-refresh-state", "Explicitly resume or retry this refresh before starting a background worker.")
        refresh.check_inputs(document, job)
        target = {"targetKind": "refresh", "targetId": job["id"], "refreshId": job["id"],
                  "refreshDefinitionHash": job["definitionHash"]}
    elif request["operation"] == "sweep.worker.start":
        import _workbench_sweeps as sweeps
        sweep = sweeps.get(document, request["arguments"]["sweepId"])
        sweeps.check_advance(document, sweep)
        target = {"targetKind": "sweep", "targetId": sweep["id"], "sweepId": sweep["id"],
                  "sweepDefinitionHash": sweep["definitionHash"]}
    else:
        job = get_job(document, request["arguments"]["jobId"])
        if job["status"] not in ("pending", "running"):
            fail("invalid-job-state", "Explicitly resume or retry this job before starting a new background worker.")
        check_inputs(document, job)
        target = {"targetKind": "job", "targetId": job["id"], "jobId": job["id"],
                  "workflowDefinitionHash": job["definitionHash"]}
    if any(describe(store, document, item)["status"] in ACTIVE for item in workers):
        fail("worker-active", "This project already has a queued or active background worker.")
    worker = {
        "workerId": str(uuid.uuid4()), **target, "status": "queued",
        "runToken": secrets.token_hex(32),
        "createdAt": utc_now(), "createdRevision": document["revision"] + 1,
        "startRequestId": request["requestId"], "actor": copy.deepcopy(actor),
    }
    workers.append(worker)
    return {"worker": describe(None, document, worker)}


def _pause_request(store, worker, marker, document):
    identity = target_identity(worker)
    protocol = target_protocol(worker)
    arguments = {protocol["idField"]: identity["targetId"]}
    if identity["targetKind"] != "tiled-analysis":
        arguments.update({"reason": marker["reason"], "controlRequestId": marker["requestId"]})
    return {
        "schemaVersion": 1, "operation": protocol["prefix"] + ".pause", "projectPath": str(store.root),
        "requestId": "worker-stop:" + worker["workerId"] + ":" + hashlib.sha256(marker["requestId"].encode()).hexdigest(),
        "expectedRevision": document["revision"],
        "arguments": arguments,
        "actor": marker["actor"],
    }


def pause_after_stop(store, worker, marker, document):
    """Caller owns the project execution lock; never retries revision conflicts."""
    from _workbench_core import dispatch
    target = target_state(document, worker)
    if target["status"] not in ("pending", "running"):
        return {"ok": True, "revision": document["revision"], "targetStatus": target["status"],
                target_protocol(worker)["resultKey"] + "Status": target["status"],
                **({"targetError": target["error"]} if target.get("error") else {})}
    return dispatch(_pause_request(store, worker, marker, document))


def request_stop(store, document, request, actor):
    from _workbench_store import canonical, utc_now, sync_directory
    worker = record(document, request["arguments"]["workerId"])
    if not worker.get("runToken"):
        fail("worker-unavailable", "Restored workers cannot control processes; start a new worker explicitly.")
    path = directory(store, worker, True)
    previous_status = describe(store, document, worker)["status"]
    payload = _control_payload(request, actor)
    digest = hashlib.sha256(canonical(payload).encode()).hexdigest()
    request_key = hashlib.sha256(request["requestId"].encode()).hexdigest()
    controls = _root(store, True)
    receipt_path = controls / ("stop-request-" + request_key + ".json")
    marker = {"workerId": worker["workerId"], "tokenHash": token_hash(worker),
              "requestId": request["requestId"], "payloadHash": digest, "actor": copy.deepcopy(actor),
              "reason": payload["reason"], "requestedAt": utc_now()}
    # A short control lock serializes request-id receipts and stop publication;
    # it does not contend with the long-running scientific execution lock.
    control_path = controls / ".control.lock"
    lock = _ControlLock(control_path)
    with lock:
        if receipt_path.exists():
            previous = read_json(receipt_path)
            if previous.get("payloadHash") != digest:
                fail("request-id-conflict", "This stop requestId was already used with different arguments or actor.")
            marker = previous
        else:
            if len(list(controls.glob("stop-request-*.json"))) >= 10000:
                fail("worker-control-limit", "This project retains at most 10,000 distinct worker stop requests.")
            write_json(receipt_path, marker)
        stop_path = path / "stop.json"
        if not stop_path.exists():
            write_json(stop_path, marker)
            sync_directory(path)
        else:
            marker = stop_marker(store, worker)
    # If no computation owns the project, pause immediately. Otherwise the
    # already-authorized child consumes the marker after its current commit.
    execution = ProjectLock(store)
    latest_owner = document.get("jobWorkers", [])[-1]["workerId"] == worker["workerId"]
    if latest_owner and previous_status not in TERMINAL - {"interrupted"} and execution.acquire():
        try:
            current = store.read()
            current_worker = record(current, worker["workerId"])
            response = pause_after_stop(store, current_worker, marker, current)
            terminal_target = response.get("targetStatus")
            status = (terminal_target if response.get("ok") and terminal_target in
                      ("completed", "cancelled", "blocked", "failed") else
                      "stopped" if response.get("ok") else "attention")
            write_json(path / "status.json", {
                "workerId": worker["workerId"], "tokenHash": token_hash(worker), "status": status,
                "finishedAt": utc_now(), "lastRevision": response.get("revision", current["revision"]),
                "stopRequest": {key: marker[key] for key in ("requestId", "actor", "reason", "requestedAt")},
                **({"error": response["error"]} if not response.get("ok") else {}),
                **({"error": response["targetError"]} if response.get("targetError") else {}),
            })
        finally:
            execution.close()
    latest = store.read()
    result = describe(store, latest, record(latest, worker["workerId"]))
    result["stopRequested"] = True
    return {"worker": result}, latest["revision"]


def _control_payload(request, actor):
    return {"operation": request["operation"], "workerId": request["arguments"]["workerId"],
            "reason": request["arguments"].get("reason", "Requested by the client"), "actor": actor}


def check_control_request_id(store, request, actor):
    """Reserve stop IDs project-wide, including against later ordinary writes."""
    from _workbench_store import canonical
    key = hashlib.sha256(request["requestId"].encode()).hexdigest()
    path = _root(store) / ("stop-request-" + key + ".json")
    if not path.exists():
        return
    previous = read_json(path)
    if request["operation"] != "job.worker.stop":
        fail("request-id-conflict", "This requestId belongs to a durable worker stop command.")
    digest = hashlib.sha256(canonical(_control_payload(request, actor)).encode()).hexdigest()
    if previous.get("payloadHash") != digest:
        fail("request-id-conflict", "This stop requestId was already used with different arguments or actor.")


class _ControlLock:
    def __init__(self, path):
        self.path, self.stream = path, None

    def __enter__(self):
        if self.path.is_symlink():
            fail("project-corrupt", "Worker control lock cannot be a symbolic link.")
        descriptor = os.open(str(self.path), os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
        self.stream = os.fdopen(descriptor, "r+b", buffering=0)
        if os.fstat(self.stream.fileno()).st_size == 0:
            self.stream.write(b"\0")
        self.stream.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.stream.fileno(), msvcrt.LK_LOCK, 1)
            else:
                import fcntl
                fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX)
        except Exception:
            self.stream.close()
            raise
        return self

    def __exit__(self, *_):
        self.stream.close()


def _launch(store, document, worker):
    from _workbench_store import canonical, utc_now
    if (worker.get("status") in TERMINAL or not worker.get("runToken") or
            document.get("jobWorkers", [])[-1]["workerId"] != worker["workerId"]):
        return
    path = directory(store, worker, True)
    existing = path / "status.json"
    if existing.exists() and read_json(existing).get("status") in TERMINAL:
        return
    marker = path / ".launched"
    try:
        descriptor = os.open(str(marker), os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except FileExistsError:
        return
    with os.fdopen(descriptor, "w") as stream:
        stream.write(canonical({"workerId": worker["workerId"], "tokenHash": token_hash(worker), "at": utc_now()}))
        stream.flush()
        os.fsync(stream.fileno())
    from _workbench_store import sync_directory
    sync_directory(path)
    script = Path(__file__).resolve().with_name("_workbench_job_worker.py")
    # Only inherit runtime necessities, not shell/Python injection settings.
    environment = {key: value for key, value in os.environ.items()
                   if key in ("PATH", "HOME", "USERPROFILE", "SYSTEMROOT", "WINDIR", "TEMP", "TMP", "TMPDIR",
                              "LANG", "LC_ALL", "VIRTUAL_ENV", "CONDA_PREFIX")}
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    flags = ((getattr(subprocess, "DETACHED_PROCESS", 0) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
             if os.name == "nt" else 0)
    # Worker diagnostics are bounded status records; scientific libraries must
    # not grow unattended log files for the lifetime of a background batch.
    from workbench import runtime_configuration
    configuration = runtime_configuration()["bindings"]
    runtime_args = []
    for key, flag in (("microscopyNode", "--microscopy-node"), ("microscopyRuntime", "--microscopy-runtime"),
                      ("runtimeRegistry", "--runtime-registry")):
        if configuration.get(key): runtime_args.extend((flag, configuration[key]))
    process = subprocess.Popen([
        sys.executable, "-I", "-B", str(script), "--project", str(store.root),
        "--worker-id", worker["workerId"], "--token", worker["runToken"], *runtime_args,
    ], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
       close_fds=True, env=environment, start_new_session=os.name != "nt", creationflags=flags)
    write_json(path / "process.json", {"workerId": worker["workerId"], "tokenHash": token_hash(worker),
                                      "pid": process.pid, "launchedAt": utc_now()})


def after_commit(store, document, result):
    from _workbench_store import utc_now
    worker = record(document, result["worker"]["workerId"])
    try:
        _launch(store, document, worker)
    except Exception as exc:
        try:
            path = directory(store, worker, True)
            write_json(path / "status.json", {
                "workerId": worker["workerId"], "tokenHash": token_hash(worker), "status": "failed",
                "finishedAt": utc_now(), "error": {"code": "worker-launch-failed", "message": str(exc)[:2000]},
            })
        except Exception:
            # The launch intent has already committed. Do not report a failed
            # project mutation if the filesystem also prevents status writing.
            pass


def read(store, document, operation, args):
    if operation == "job.worker.list":
        return {"workers": inspect_workers(store, document)}
    return {"worker": describe(store, document, record(document, args["workerId"]))}


def restored_records(document):
    for worker in document.get("jobWorkers", []):
        worker.pop("runToken", None)
        worker["statusBeforeRestore"] = worker.get("status")
        worker["status"] = "interrupted"
        worker["error"] = {
            "code": "restored-background-worker",
            "message": "Background processes belong to their original project. Resume the job, sweep or refresh and explicitly start a new worker.",
        }
