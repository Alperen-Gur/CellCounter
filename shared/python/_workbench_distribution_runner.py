"""Foreground CLI orchestration for one portable distributed task.

Scientific work, checkpoints and publication use canonical operations. The
runner owns the existing project execution lock and never retries a failed
request or silently adopts a concurrent revision.
"""
from __future__ import annotations

from contextlib import AbstractContextManager
import signal
import sys
import threading
import uuid


class _OperationFailure(Exception):
    def __init__(self, response):
        self.response = response
        super().__init__(response.get("error", {}).get("message", "Operation failed."))


class _CheckpointStop(AbstractContextManager):
    def __init__(self):
        self.requested = False
        self.previous = {}

    def _request(self, signum, frame):
        if not self.requested:
            print("Stop requested. The current checkpoint will finish before pausing.", file=sys.stderr, flush=True)
        self.requested = True

    def __enter__(self):
        if threading.current_thread() is threading.main_thread():
            for name in ("SIGINT", "SIGTERM"):
                value = getattr(signal, name, None)
                if value is not None:
                    self.previous[value] = signal.signal(value, self._request)
        return self

    def __exit__(self, *exc):
        for value, handler in self.previous.items():
            signal.signal(value, handler)
        return False


def _destination(value, label):
    from _workbench_schema import WorkbenchError, absolute_path

    path = absolute_path(value, label)
    if path.suffix.lower() != ".zip":
        raise WorkbenchError("invalid-path", label + " must be a new .zip file.")
    if path.exists() or path.is_symlink():
        raise WorkbenchError("destination-exists", label + " already exists. Choose a new file.")
    if not path.parent.is_dir():
        raise WorkbenchError("invalid-path", label + " requires an existing parent directory.")
    return str(path)


class _Run:
    def __init__(self, project, dispatch):
        self.project = project
        self.dispatch = dispatch
        self.id = str(uuid.uuid4())
        self.revision = None
        self.sequence = 0
        self.task = None
        self.job = None
        self.completed_units = 0

    def call(self, operation, arguments=None, *, mutation=False):
        self.sequence += 1
        request = {
            "schemaVersion": 1, "operation": operation,
            "requestId": f"distributed-cli:{self.id}:{self.sequence}",
            "projectPath": self.project,
            "actor": {"kind": "cli", "name": "CellCounter distributed runner"},
            "arguments": arguments or {},
        }
        if mutation:
            if self.revision is None:
                raise ValueError("A task revision is required before a mutation.")
            request["expectedRevision"] = self.revision
        response = self.dispatch(request)
        if not response.get("ok"):
            raise _OperationFailure(response)
        revision = response.get("revision")
        if not isinstance(revision, int) or isinstance(revision, bool):
            raise ValueError("The operation did not return a project revision.")
        self.revision = revision
        return response["result"]

    def response(self, *, error=None, **values):
        result = {"projectPath": self.project, "completedUnits": self.completed_units, **values}
        if self.task:
            result["taskId"] = self.task["id"]
            result["distributionId"] = self.task["distributionId"]
        if self.job:
            result["job"] = self.job
        response = {
            "schemaVersion": 1, "operation": "distributed-run", "requestId": self.id,
            "ok": error is None, "result": result,
        }
        if self.revision is not None:
            response["revision"] = self.revision
        if error is not None:
            response["error"] = error
        return response

    def stop(self):
        if self.job["status"] in ("pending", "running"):
            self.job = self.call("job.pause", {"jobId": self.job["id"]}, mutation=True)["job"]
        return self.response(error={
            "code": "runner-stopped",
            "message": "Execution stopped at a checkpoint. Use --resume for a paused task; completed tasks can be exported by running again.",
        }, resultExported=False)

    def execute(self, args, destination, workflow_export):
        from _workbench_schema import WorkbenchError

        self.task = self.call("distribution.task.get")["task"]
        with _CheckpointStop() as stop:
            if self.task["prepared"]:
                if workflow_export or args.allow_runtime_differences:
                    raise WorkbenchError("task-already-prepared", "This task is already prepared. Omit preparation-only --workflow-export and --allow-runtime-differences options.")
                self.job = self.task["job"]
            else:
                if args.resume or args.retry:
                    raise WorkbenchError("task-not-prepared", "This task has no job to resume or retry. Run without --resume or --retry.")
                preparation = {"allowRuntimeDifferences": bool(args.allow_runtime_differences)}
                if workflow_export:
                    preparation["exportDestination"] = workflow_export
                prepared = self.call("distribution.task.prepare", preparation, mutation=True)
                self.task = prepared["task"]
                self.job = prepared.get("job") or self.task["job"]

            if not self.job or self.job.get("id") != self.task["jobId"]:
                raise WorkbenchError("invalid-task-job", "The prepared task does not identify its canonical workflow job.")
            if stop.requested:
                return self.stop()
            if args.resume or args.retry:
                action = "resume" if args.resume else "retry"
                # The canonical operation enforces allowed states and current inputs.
                self.job = self.call("job." + action, {"jobId": self.job["id"]}, mutation=True)["job"]

            while self.job["status"] in ("pending", "running"):
                if stop.requested:
                    return self.stop()
                if self.job.get("nextUnit") is None:
                    raise WorkbenchError("invalid-job-state", "The unfinished task has no executable checkpoint.")
                before_count = self.job.get("progress", {}).get("completed", 0)
                self.job = self.call("job.advance", {"jobId": self.job["id"]}, mutation=True)["job"]
                progress = self.job.get("progress", {})
                self.completed_units += max(0, progress.get("completed", 0) - before_count)
                print(f"Task {self.task['id']}: {self.job['status']} "
                      f"({progress.get('completed', '?')}/{progress.get('total', '?')} units)",
                      file=sys.stderr, flush=True)

            if self.job["status"] != "completed":
                state = self.job["status"]
                advice = {"paused": "Use --resume to continue.",
                          "awaiting-review": "Inspect job.graph.review.get and record an explicit decision; then rerun distributed-run. Agent recommendations cannot approve a human-required gate.",
                          "failed": "Resolve the reported failure and use --retry.",
                          "blocked": "Inputs changed; create a new task from the intended inputs.",
                          "cancelled": "Create a new task if this work is still needed."}
                return self.response(error={
                    "code": "task-" + state,
                    "message": f"The task is {state}. " + advice.get(state, "Inspect the task before continuing."),
                    **({"details": self.job["error"]} if self.job.get("error") else {}),
                }, resultExported=False)
            if self.job.get("outputsCurrent") is not True:
                raise WorkbenchError("stale-task-output", "The completed task's outputs are no longer current. No result package was exported.")
            if stop.requested:
                return self.stop()
            exported = self.call("project.export", {"destination": destination}, mutation=True)
            return self.response(resultExported=True, export=exported)


def run(args, dispatch):
    """Return one CLI JSON envelope; print checkpoint progress only to stderr."""
    from _workbench_schema import WorkbenchError, absolute_path
    from _workbench_store import ProjectStore
    import _workbench_jobs as jobs

    state = _Run(args.project or "", dispatch)
    try:
        if not args.project:
            raise WorkbenchError("project-required", "Supply --project before distributed-run.")
        state.project = str(absolute_path(args.project, "projectPath"))
        destination = _destination(args.result, "result destination")
        workflow_export = (_destination(args.workflow_export, "workflow export destination")
                           if args.workflow_export else None)
        if workflow_export == destination:
            raise WorkbenchError("duplicate-destination", "The workflow export and collected result need separate destination files.")
        if args.package:
            state.call("package.restore", {"path": args.package})
            print("Task package restored. Executable plugins and models remain disabled until explicitly enabled.",
                  file=sys.stderr, flush=True)
        store = ProjectStore(state.project)
        # advance_guard also rejects a queued detached worker. Holding its lock
        # across checkpoints avoids racing another runner or worker startup.
        with jobs.advance_guard(store), jobs.owned_project(store):
            return state.execute(args, destination, workflow_export)
    except _OperationFailure as exc:
        return state.response(error=exc.response["error"], failedOperation=exc.response["operation"],
                              failedRequestId=exc.response["requestId"], resultExported=False)
    except WorkbenchError as exc:
        error = {"code": exc.code, "message": exc.message}
        if exc.details is not None:
            error["details"] = exc.details
        return state.response(error=error, resultExported=False)
    except (ValueError, OSError) as exc:
        return state.response(error={"code": "runner-error", "message": str(exc)}, resultExported=False)
