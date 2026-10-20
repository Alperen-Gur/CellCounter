#!/usr/bin/env python3
"""CellCounter's local command-line adapter for shared workbench operations.

Ordinary commands require only the workbench runtime. MCP is an optional
transport and its dependencies are imported only by the ``mcp`` command.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
from contextlib import redirect_stdout
import json
from pathlib import Path
import sys
import threading
import uuid
from typing import Any, Dict, Optional, Sequence


# One configuration/dispatch lock even when launched as a script and imported by SDK helpers.
sys.modules.setdefault("workbench", sys.modules[__name__])

MAX_REQUEST_BYTES = 8 * 1024 * 1024
_DISPATCH_LOCK = threading.RLock()
_RUNTIME_CONFIGURATION = {}


def runtime_configuration() -> Dict[str, Any]:
    """Read the process-local binding; never saved in a portable project."""
    with _DISPATCH_LOCK:
        value = copy.deepcopy(_RUNTIME_CONFIGURATION)
        identity = hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        return {"scope": "process", "hash": identity, "bindings": value,
                "notes": ["Configuration is process-wide and serialized with dispatch. Replacing it requires its current hash.",
                          "Local SDK clients bind this identity; a configuration change cannot silently redirect their subsequent requests."]}


def configure_runtime(*, native_helper: Optional[str] = None, microscopy_node: Optional[str] = None,
                      microscopy_runtime: Optional[str] = None, omero_profiles: Optional[str] = None,
                      runtime_registry: Optional[str] = None,
                      expected_configuration_hash: Optional[str] = None) -> Dict[str, Any]:
    """Explicit host-local startup configuration shared by CLI and Python SDK.

    Omitted fields preserve existing bindings. A different nonempty configuration
    requires an explicit compare-and-swap hash. This never installs/enables code,
    starts a network connection or changes portable project metadata.
    """
    global _RUNTIME_CONFIGURATION
    requested = {key: value for key, value in {"nativeHelper": native_helper, "microscopyNode": microscopy_node,
                 "microscopyRuntime": microscopy_runtime, "omeroProfiles": omero_profiles,
                 "runtimeRegistry": runtime_registry}.items() if value is not None}
    with _DISPATCH_LOCK:
        current = runtime_configuration()
        if expected_configuration_hash is not None and expected_configuration_hash != current["hash"]:
            raise ValueError("Runtime configuration changed. Inspect runtime_configuration() before explicitly rebinding it.")
        proposed = {**_RUNTIME_CONFIGURATION, **requested}
        if proposed == _RUNTIME_CONFIGURATION:
            return current
        if _RUNTIME_CONFIGURATION and expected_configuration_hash is None:
            raise ValueError("Replacing an existing process runtime binding requires expected_configuration_hash.")
        if bool(proposed.get("microscopyNode")) != bool(proposed.get("microscopyRuntime")):
            raise ValueError("Provide both microscopy_node and microscopy_runtime.")
        import _workbench_migration as migration
        import _workbench_microscopy_runtime as microscopy
        import _workbench_omero as omero
        import _workbench_runtimes as runtimes
        before = (copy.deepcopy(migration._native_helper), copy.deepcopy(microscopy._runtime), omero._registry_path, runtimes._registry_path)
        try:
            if "nativeHelper" in requested: migration.configure_native_helper(proposed["nativeHelper"])
            if "microscopyNode" in requested or "microscopyRuntime" in requested:
                microscopy.configure(proposed["microscopyNode"], proposed["microscopyRuntime"])
            if "omeroProfiles" in requested: omero.configure(proposed["omeroProfiles"])
            if "runtimeRegistry" in requested: runtimes.configure(proposed["runtimeRegistry"])
        except Exception:
            migration._native_helper, microscopy._runtime, omero._registry_path, runtimes._registry_path = before
            raise
        _RUNTIME_CONFIGURATION = proposed
        return runtime_configuration()


def _unique_object(pairs: Any) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key: " + key)
        result[key] = value
    return result


def _nonfinite(value: str) -> Any:
    raise ValueError("Non-finite JSON value: " + value)


def parse_json(text: str) -> Dict[str, Any]:
    """Parse one bounded JSON object without accepting duplicate keys or NaN."""
    if len(text.encode("utf-8")) > MAX_REQUEST_BYTES:
        raise ValueError("Request exceeds the 8 MiB limit.")
    value = json.loads(
        text, object_pairs_hook=_unique_object, parse_constant=_nonfinite
    )
    if not isinstance(value, dict):
        raise ValueError("A JSON object is required.")
    return value


def failure(
    code: str, message: str, request: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    request = request or {}
    return {
        "schemaVersion": 1,
        "ok": False,
        "operation": request.get("operation") if isinstance(request.get("operation"), str) else "",
        "requestId": request.get("requestId") if isinstance(request.get("requestId"), str) else "",
        "error": {"code": code, "message": message},
    }


def run_request(request: Dict[str, Any], *, configuration_hash: Optional[str] = None) -> Dict[str, Any]:
    """Call the same dispatcher used by the GUI; stdout remains JSON-only."""
    try:
        # redirect_stdout changes process-wide state. Serialize dispatch in a
        # server process so concurrent MCP requests cannot restore each other's
        # stream while a scientific dependency is still printing diagnostics.
        with _DISPATCH_LOCK, redirect_stdout(sys.stderr):
            if configuration_hash is not None and configuration_hash != runtime_configuration()["hash"]:
                return failure("runtime-configuration-changed", "This client's bound host runtime changed. Rebind explicitly or create a client for the intended configuration.", request)
            from _workbench_core import dispatch

            response = dispatch(request)
        if not isinstance(response, dict) or not isinstance(response.get("ok"), bool):
            return failure("invalid_response", "The operation returned an invalid response.", request)
        return response
    except ImportError as exc:
        print(str(exc), file=sys.stderr)
        return failure(
            "runtime_unavailable",
            "The workbench runtime or a required dependency is unavailable.",
            request,
        )
    except Exception as exc:
        # Diagnostics belong on stderr, never in the native/MCP wire stream.
        print(f"Workbench operation failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return failure("internal_error", "The workbench operation could not complete.", request)


def _emit(response: Dict[str, Any]) -> int:
    try:
        encoded = json.dumps(response, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
    except (TypeError, ValueError):
        encoded = json.dumps(failure("invalid_response", "The operation returned invalid JSON."))
        print(encoded, flush=True)
        return 1
    print(encoded, flush=True)
    return 0 if response.get("ok") else 1


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run persistent CellCounter workbench operations locally."
    )
    parser.add_argument("--project", help="Absolute workbench project directory for call or distributed-run commands.")
    parser.add_argument("--omero-profiles", help="Explicit host-local OMERO registry; credentials/runtime references never come from portable projects.")
    parser.add_argument("--runtime-registry", help="Explicit host-local registered interpreter/plugin binding registry; never supplied by portable project data.")
    parser.add_argument("--native-helper", help="Explicit installed macOS application executable for read-only legacy archive capture; never taken from project data.")
    parser.add_argument("--microscopy-node", help="Explicit pinned Node executable for the bundled shared microscopy engine.")
    parser.add_argument("--microscopy-runtime", help="Absolute bundled microscopy runtime directory containing microscopy-runtime.json; never taken from project data.")
    sub = parser.add_subparsers(dest="command", required=True)

    request = sub.add_parser("request", help="Execute a complete versioned JSON request.")
    sources = request.add_mutually_exclusive_group()
    sources.add_argument("--json", help="One JSON request.")
    sources.add_argument("--file", help="Read one request from a UTF-8 JSON file.")
    sources.add_argument("--stdin", action="store_true", help="Read one JSON request from stdin (the default).")

    sub.add_parser("capabilities", help="Describe available operations without opening a project.")

    call = sub.add_parser("call", help="Build a request from an operation and JSON arguments.")
    call.add_argument("operation", help="Operation name, for example project.inspect.")
    call.add_argument("--args", default="{}", help="JSON operation arguments (default: {}).")
    call.add_argument("--expected-revision", type=int)
    call.add_argument("--request-id", help="Reuse this ID only when retrying the exact same request.")

    distributed = sub.add_parser("distributed-run", help="Run one portable task through canonical checkpoints and export its result.")
    distributed.add_argument("--package", help="First restore this task ZIP into a new --project directory; never enable code automatically.")
    distributed.add_argument("--result", required=True, help="Absolute path for a new completed result ZIP.")
    distributed.add_argument("--workflow-export", help="Preparation only: new ZIP destination for the workflow's optional export step.")
    distributed.add_argument("--allow-runtime-differences", action="store_true",
                             help="Preparation only: explicitly accept and record differences from the coordinator runtime.")
    recovery = distributed.add_mutually_exclusive_group()
    recovery.add_argument("--resume", action="store_true", help="Explicitly resume an existing paused task job.")
    recovery.add_argument("--retry", action="store_true", help="Explicitly retry an existing failed task job after resolving its failure.")

    mcp = sub.add_parser("mcp", help="Serve scoped tools over MCP stdio (optional dependency).")
    mcp.add_argument("--project", dest="mcp_project", required=True, help="Absolute project directory.")
    mcp.add_argument("--tool-mode", choices=("operations", "compact"), default="operations",
                     help="Compact exposes bounded discovery plus shared read/mutate tools; operations retains direct operation tools with paginated discovery.")
    mcp.add_argument(
        "--allow-write", action="store_true",
        help="Expose project mutations and export. Without this flag tools are read-only.",
    )
    mcp.add_argument(
        "--allow-path", action="append", default=[], metavar="ABSOLUTE_PATH",
        help="Also permit imports/exports at this file or directory. Repeat as needed.",
    )
    mcp.add_argument(
        "--allow-plugins", action="store_true",
        help="Permit installing, enabling and executing trusted local Python plugins. Requires --allow-write.",
    )
    mcp.add_argument("--allow-omero-profile", action="append", default=[], metavar="PROFILE_ID", help="Permit read-only network operations using this configured OMERO profile; repeat per profile.")
    mcp.add_argument("--allow-omero-configuration", action="store_true", help="Permit host-local OMERO registry CAS changes with explicit local path grants; requires --allow-write.")
    mcp.add_argument("--allow-runtime-configuration", action="store_true", help="Permit host-local interpreter and exact-plugin-package bindings across projects; requires --allow-write and registry/path grants.")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = make_parser().parse_args(argv)
    try:
        configure_runtime(native_helper=args.native_helper, microscopy_node=args.microscopy_node,
                          microscopy_runtime=args.microscopy_runtime, omero_profiles=args.omero_profiles,
                          runtime_registry=args.runtime_registry)
    except Exception as exc:
        if args.command == "mcp":
            print("Workbench runtime configuration failed: " + str(exc), file=sys.stderr)
            return 1
        return _emit(failure("runtime-configuration", str(exc)))
    if args.command == "distributed-run":
        try:
            from _workbench_distribution_runner import run

            return _emit(run(args, run_request))
        except ImportError as exc:
            print(str(exc), file=sys.stderr)
            return _emit(failure("runtime_unavailable", "The distributed workbench runtime or a required dependency is unavailable.",
                                 {"operation": "distributed-run"}))
        except Exception as exc:
            print(f"Distributed runner failed: {type(exc).__name__}: {exc}", file=sys.stderr)
            return _emit(failure("internal_error", "The distributed runner could not complete. Inspect the retained task project before resuming.",
                                 {"operation": "distributed-run"}))
    if args.command == "mcp":
        try:
            from _workbench_mcp import serve

            serve(args.mcp_project, allow_write=args.allow_write, allowed_paths=args.allow_path,
                  allow_plugins=args.allow_plugins, allowed_omero_profiles=args.allow_omero_profile,
                  allow_omero_configuration=args.allow_omero_configuration,
                  allow_runtime_configuration=args.allow_runtime_configuration, tool_mode=args.tool_mode)
            return 0
        except ImportError as exc:
            print(
                "MCP support is unavailable. Install requirements-mcp.txt with Python 3.11 "
                f"or later in the workbench environment. ({exc})",
                file=sys.stderr,
            )
            return 1
        except (ValueError, OSError) as exc:
            print(f"Cannot start MCP: {exc}", file=sys.stderr)
            return 1

    request: Dict[str, Any] = {}
    try:
        if args.command == "request":
            if args.json is not None:
                text = args.json
            elif args.file:
                with Path(args.file).open("r", encoding="utf-8") as stream:
                    text = stream.read(MAX_REQUEST_BYTES + 1)
            else:
                text = sys.stdin.read(MAX_REQUEST_BYTES + 1)
            request = parse_json(text)
        else:
            request = {
                "schemaVersion": 1,
                "operation": "capabilities" if args.command == "capabilities" else args.operation,
                "requestId": (
                    args.request_id if args.command == "call" and args.request_id else str(uuid.uuid4())
                ),
                "actor": {"kind": "cli", "name": "CellCounter CLI"},
                "arguments": {} if args.command == "capabilities" else parse_json(args.args),
            }
            if args.project:
                request["projectPath"] = args.project
            if args.command == "call" and args.expected_revision is not None:
                request["expectedRevision"] = args.expected_revision
    except (ValueError, OSError, UnicodeError) as exc:
        return _emit(failure("invalid_request", str(exc), request))
    return _emit(run_request(request))


if __name__ == "__main__":
    raise SystemExit(main())
