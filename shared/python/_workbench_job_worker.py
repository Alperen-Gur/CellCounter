#!/usr/bin/env python3
"""Detached worker for canonical job, sweep or refresh advancement and pause calls."""
from __future__ import annotations

import argparse
import secrets
import sys
from pathlib import Path
import threading
import time

# -I excludes the script directory. Add only this explicitly launched, bundled
# runtime directory, never a project or an inherited PYTHONPATH.
sys.path.insert(0, str(Path(__file__).resolve().parent))


def run(project_path, worker_id, supplied_token):
    import _workbench_jobs as jobs
    from _workbench_core import dispatch
    from _workbench_store import ProjectStore, utc_now

    store = ProjectStore(project_path)
    document = store.read()
    worker = jobs.record(document, worker_id)
    if (worker.get("status") in jobs.TERMINAL or not worker.get("runToken") or
            not secrets.compare_digest(worker["runToken"], supplied_token)):
        return 2
    path = jobs.directory(store, worker, True)
    identity = jobs.target_identity(worker)
    protocol = jobs.target_protocol(worker)
    kind = protocol["resultKey"]
    state = {"workerId": worker_id, "tokenHash": jobs.token_hash(worker), "status": "starting",
             **identity, "startedAt": utc_now(), "lastRevision": document["revision"]}
    lock = jobs.ProjectLock(store)
    if not lock.acquire():
        # A stop command may hold the lock while publishing the canonical pause.
        # Its status is authoritative; never overwrite that with a lock error.
        if jobs.stop_marker(store, worker) is None:
            state.update({"status": "attention", "finishedAt": utc_now(),
                          "error": {"code": "worker-ownership-conflict",
                                    "message": "Another workflow unit or worker already owns this project."}})
            jobs.write_json(path / "status.json", state)
        return 3

    heartbeat_stop = threading.Event()
    heartbeat_failed = threading.Event()

    def heartbeat():
        while not heartbeat_stop.is_set():
            try:
                jobs.write_json(path / "heartbeat.json", {
                    "workerId": worker_id, "tokenHash": jobs.token_hash(worker),
                    "heartbeatAt": utc_now(), "unixTime": time.time(),
                })
            except Exception:
                heartbeat_failed.set()
                return
            heartbeat_stop.wait(jobs.HEARTBEAT_SECONDS)

    def update(**values):
        state.update(values)
        jobs.write_json(path / "status.json", state)

    def finish(status, error=None, **values):
        update(status=status, finishedAt=utc_now(), **values,
               **({"error": error} if error else {}))

    thread = threading.Thread(target=heartbeat, name="CellCounter batch heartbeat", daemon=True)
    try:
        target = jobs.target_state(document, worker)
        state.update({"targetStatus": target["status"], kind + "Status": target["status"],
                      "progress": target["progress"]})
        jobs.write_json(path / "status.json", state)
        thread.start()
        sequence = 0
        with jobs.owned_project(store):
            while True:
                if heartbeat_failed.is_set():
                    finish("attention", {"code": "worker-heartbeat-write-failed",
                                         "message": "Heartbeat storage failed; no new unit was started."})
                    return 4
                document = store.read()
                current = jobs.record(document, worker_id)
                if (document.get("jobWorkers", [])[-1]["workerId"] != worker_id or
                        current.get("runToken") != supplied_token or jobs.target_identity(current) != identity or
                        current.get("sweepDefinitionHash") != worker.get("sweepDefinitionHash") or
                        current.get("refreshDefinitionHash") != worker.get("refreshDefinitionHash") or
                        current.get("analysisDefinitionHash") != worker.get("analysisDefinitionHash") or
                        current.get("workflowDefinitionHash") != worker.get("workflowDefinitionHash")):
                    finish("attention", {"code": "worker-ownership-changed",
                                         "message": "This worker was superseded. No further unit was started."})
                    return 4
                target = jobs.target_state(document, worker)
                marker = jobs.stop_marker(store, worker)
                if marker:
                    stop_request = {key: marker[key] for key in ("requestId", "actor", "reason", "requestedAt")}
                    update(status="stopping", stopRequest=stop_request, lastRevision=document["revision"])
                    response = jobs.pause_after_stop(store, worker, marker, document)
                    if response.get("ok"):
                        paused = response.get("result", {}).get(kind)
                        if paused:
                            update(targetStatus=paused["status"], progress=paused["progress"],
                                   **{kind + "Status": paused["status"]})
                        terminal_target = response.get("targetStatus")
                        outcome = terminal_target if terminal_target in ("completed", "cancelled", "blocked", "failed") else "stopped"
                        finish(outcome, response.get("targetError"), stopRequest=stop_request,
                               lastRevision=response.get("revision", document["revision"]))
                        return 0
                    finish("attention", response["error"], stopRequest=stop_request)
                    return 4
                if target["status"] not in ("pending", "running"):
                    finish(target["status"] if target["status"] in jobs.TERMINAL else "attention",
                           target.get("error"), lastRevision=document["revision"],
                           targetStatus=target["status"], progress=target["progress"],
                           **{kind + "Status": target["status"]})
                    return 0
                unit = target["nextUnit"]
                if unit is None:
                    finish("attention", {"code": "invalid-job-state",
                                         "message": "The unfinished worker target has no executable checkpoint."})
                    return 4
                sequence += 1
                request_id = f"worker:{worker_id}:{sequence}"
                request = {
                    "schemaVersion": 1, "operation": protocol["prefix"] + ".advance", "projectPath": str(store.root),
                    "requestId": request_id, "expectedRevision": document["revision"],
                    "arguments": {protocol["idField"]: identity["targetId"]}, "actor": worker["actor"],
                }
                update(status="running", lastUnit=unit, lastRequestId=request_id,
                       lastRevision=document["revision"])
                response = dispatch(request)
                if not response.get("ok"):
                    # In particular, never repeat expensive/executable work
                    # after a compare-and-swap conflict with another client.
                    finish("attention", response["error"])
                    return 4
                after = response["result"][kind]
                update(lastRevision=response["revision"], completedUnits=sequence,
                       progress=after.get("progress"), lastCompletedAt=utc_now(),
                       targetStatus=after["status"], **{kind + "Status": after["status"]})
                if after["status"] not in ("pending", "running"):
                    # A stop received during the final unit does not replace
                    # the fact that the analysis/export completed successfully.
                    finish(after["status"] if after["status"] in jobs.TERMINAL else "attention",
                           after.get("error") or response["result"].get("job", {}).get("error"))
                    return 0
    except Exception as exc:
        try:
            finish("attention", {"code": "worker-runtime-error", "message": str(exc)[:2000]})
        except Exception:
            pass
        return 4
    finally:
        heartbeat_stop.set()
        if thread.is_alive():
            thread.join(timeout=2)
        lock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--worker-id", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--microscopy-node")
    parser.add_argument("--microscopy-runtime")
    parser.add_argument("--runtime-registry")
    args = parser.parse_args()
    from workbench import configure_runtime
    configure_runtime(microscopy_node=args.microscopy_node, microscopy_runtime=args.microscopy_runtime,
                      runtime_registry=args.runtime_registry)
    return run(args.project, args.worker_id, args.token)


if __name__ == "__main__":
    raise SystemExit(main())
