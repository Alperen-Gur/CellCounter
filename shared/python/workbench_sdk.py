"""Supported in-process Python client for the canonical workbench dispatcher.

The SDK owns no scientific algorithms or storage. A prepared request retains its
actor, idempotency key and expected revision, including when retried after a
transport interruption. Conflicts never update the client's known revision.
"""
from __future__ import annotations

import copy
from pathlib import Path
import uuid
from typing import Any, Callable, Dict, Optional

_UNSET = object()


class WorkbenchOperationError(RuntimeError):
    """A canonical failed envelope, with stable machine-readable code/details."""

    def __init__(self, response: Dict[str, Any]):
        self.response = copy.deepcopy(response)
        self.code = response.get("error", {}).get("code", "invalid-response")
        self.details = copy.deepcopy(response.get("error", {}).get("details"))
        self.operation = response.get("operation")
        self.request_id = response.get("requestId")
        super().__init__(response.get("error", {}).get("message", "The operation did not return a valid envelope."))


class PreparedOperation:
    """An immutable request snapshot suitable for explicit exact retries."""

    def __init__(self, client: "WorkbenchClient", request: Dict[str, Any]):
        self._client = client
        self._request = copy.deepcopy(request)

    @property
    def request(self) -> Dict[str, Any]:
        return copy.deepcopy(self._request)

    @property
    def request_id(self) -> str:
        return self._request["requestId"]

    def execute(self, *, raise_on_error: bool = True) -> Dict[str, Any]:
        return self._client.send(self._request, raise_on_error=raise_on_error, adopt_success_revision=True)


class WorkbenchClient:
    """Versioned local operations with explicit project revision ownership.

    ``inspect()`` deliberately adopts the inspected revision. Ordinary reads do
    not silently adopt another client's newer revision. Successful mutations
    advance the known revision; errors, including conflicts, leave it unchanged.
    ``transport`` may wrap the same API over another host, but must return the
    canonical envelope. There is no automatic retry or executable installation.
    """

    def __init__(self, project_path: Optional[str] = None, *, actor: Optional[Dict[str, str]] = None,
                 revision: Optional[int] = None, configuration_hash: Optional[str] = None,
                 transport: Optional[Callable[[Dict[str, Any]], Dict[str, Any]]] = None):
        if project_path is not None and not Path(project_path).is_absolute():
            raise ValueError("project_path must be absolute.")
        if revision is not None and (type(revision) is not int or revision < 0):
            raise ValueError("revision must be a nonnegative integer or None.")
        self.project_path = project_path
        self.actor = copy.deepcopy(actor if actor is not None else {"kind": "api", "name": "Python SDK"})
        self.revision = revision
        self._transport = transport
        if transport is None:
            self.configuration_hash = configuration_hash if configuration_hash is not None else runtime_configuration()["hash"]
        else:
            if configuration_hash is not None:
                raise ValueError("A custom transport owns its remote runtime binding; a local configuration_hash cannot validate it.")
            self.configuration_hash = None
        self._catalogue = None
        self._descriptors = {}

    def operations(self) -> list:
        """Read shared argument schemas, execution flags and platform metadata."""
        if self._catalogue is None:
            if self._transport is None:
                from _workbench_schema import operation_catalog
                self._catalogue = operation_catalog()
            else:
                response = self.send({"schemaVersion": 1, "operation": "capabilities",
                                      "requestId": str(uuid.uuid4()), "actor": copy.deepcopy(self.actor), "arguments": {}})
                self._catalogue = response["result"]["operations"]
        return copy.deepcopy(self._catalogue)

    def _descriptor(self, operation: str) -> Optional[Dict[str, Any]]:
        if operation not in self._descriptors:
            if self._transport is None:
                from _workbench_schema import operation_descriptor
                descriptor = operation_descriptor(operation)
            else:
                descriptor = next((entry for entry in self.discover(prefix=operation, include_schemas=True)["operations"]
                                   if entry["name"] == operation), None)
            if descriptor is not None: self._descriptors[operation] = descriptor
        return copy.deepcopy(self._descriptors.get(operation))

    def discover(self, *, prefix: str = "", query: str = "", mutating: Optional[bool] = None,
                 include_schemas: bool = False, limit: int = 25, cursor: Optional[str] = None) -> Dict[str, Any]:
        """Read one bounded catalogue page without fetching every schema."""
        arguments = {"prefix": prefix, "query": query, "includeSchemas": include_schemas, "limit": limit}
        if mutating is not None: arguments["mutating"] = mutating
        if cursor is not None: arguments["cursor"] = cursor
        return self.send({"schemaVersion": 1, "operation": "operations.discover", "requestId": str(uuid.uuid4()),
                          "actor": copy.deepcopy(self.actor), "arguments": arguments})["result"]

    def prepare(self, operation: str, arguments: Optional[Dict[str, Any]] = None, *,
                request_id: Optional[str] = None, expected_revision: Any = _UNSET) -> PreparedOperation:
        descriptor = self._descriptor(operation)
        if descriptor is None:
            raise ValueError("Unknown operation. Use operations() to inspect the shared catalogue: " + operation)
        request = {"schemaVersion": 1, "operation": operation, "requestId": request_id if request_id is not None else str(uuid.uuid4()),
                   "actor": copy.deepcopy(self.actor), "arguments": copy.deepcopy(arguments if arguments is not None else {})}
        if descriptor.get("requiresProject"):
            if self.project_path is None:
                raise ValueError("This operation requires a project_path.")
            request["projectPath"] = self.project_path
        needs_revision = (descriptor.get("mutating") and descriptor.get("requiresExpectedRevision", True)
                          and operation not in ("project.create", "package.restore"))
        value = self.revision if expected_revision is _UNSET and needs_revision else expected_revision
        if needs_revision and (value is None or value is _UNSET):
            raise ValueError("Inspect the project or pass expected_revision explicitly before this mutation.")
        if value is not _UNSET and value is not None:
            request["expectedRevision"] = value
        return PreparedOperation(self, request)

    def call(self, operation: str, arguments: Optional[Dict[str, Any]] = None, *,
             request_id: Optional[str] = None, expected_revision: Any = _UNSET,
             raise_on_error: bool = True) -> Dict[str, Any]:
        return self.prepare(operation, arguments, request_id=request_id,
                            expected_revision=expected_revision).execute(raise_on_error=raise_on_error)

    def send(self, request: Dict[str, Any], *, raise_on_error: bool = True,
             adopt_success_revision: bool = False) -> Dict[str, Any]:
        """Send an exact caller envelope; no argument, actor or ID substitution."""
        if self._transport is None:
            from workbench import run_request
            response = run_request(copy.deepcopy(request), configuration_hash=self.configuration_hash)
        else:
            response = self._transport(copy.deepcopy(request))
        if (not isinstance(response, dict) or type(response.get("ok")) is not bool
                or response.get("schemaVersion") != 1 or response.get("operation") != request.get("operation")
                or response.get("requestId") != request.get("requestId")):
            raise WorkbenchOperationError({"schemaVersion": 1, "ok": False,
                "operation": request.get("operation"), "requestId": request.get("requestId"),
                "error": {"code": "invalid-response", "message": "Transport returned a mismatched or invalid operation envelope."}})
        if not response["ok"]:
            if raise_on_error:
                raise WorkbenchOperationError(response)
            return response
        if adopt_success_revision and request.get("projectPath") == self.project_path and "revision" in response:
            descriptor = self._descriptor(request["operation"]) or {}
            if descriptor.get("mutating") and descriptor.get("affectsProjectRevision", True):
                # An exact replay may return an older successful revision after
                # this client has since advanced. Never roll its state backwards.
                revision = response["revision"]
                if self.revision is None or revision >= self.revision:
                    self.revision = revision
        return response

    def inspect(self, *, request_id: Optional[str] = None) -> Dict[str, Any]:
        """Explicitly refresh the project and adopt its current revision."""
        response = self.call("project.inspect", request_id=request_id)
        self.revision = response["revision"]
        return response

    def create(self, name: str, *, request_id: Optional[str] = None) -> Dict[str, Any]:
        return self.call("project.create", {"name": name}, request_id=request_id)


def configure_runtime(**bindings: Any) -> Dict[str, Any]:
    """Bind explicit local runtimes using the same guarded configuration as CLI startup."""
    from workbench import configure_runtime as configure
    return configure(**bindings)


def runtime_configuration() -> Dict[str, Any]:
    from workbench import runtime_configuration as describe
    return describe()


__all__ = ["WorkbenchClient", "PreparedOperation", "WorkbenchOperationError", "configure_runtime", "runtime_configuration"]
