"""Indexed committed changes and host-local view sessions, separate from science."""
from __future__ import annotations

import copy
import hashlib
import importlib.metadata
import json
import os
import platform
import shutil
import sys
import uuid

MAX_EVENTS = 10000
MAX_SESSIONS = 200


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def operations():
    from _workbench_schema import _object, _op, _ID
    from _workbench_navigation import TASK_IDS
    revision = {"type": "integer", "minimum": 0}
    index = {"type": "integer", "minimum": 0, "maximum": 64000000}
    selection = _object({"task": {"type": "string", "enum": list(TASK_IDS)},
                         "imageId": _ID, "workspaceId": _ID,
                         "target": {"type": "string", "enum": ["plane", "volume"]},
                         "channel": index, "timeIndex": index,
                         "plane": {"type": "string", "enum": ["xy", "xz", "yz"]}, "index": index})
    identity = {"sessionId": _ID}
    control = {**identity, "expectedSessionRevision": revision}
    selected = {**control, "observedProjectRevision": revision, "selection": selection}
    result = [
        _op("project.changes", "Read bounded committed effects after a revision; unchanged reads avoid loading project data.",
            _object({"afterRevision": revision, "limit": {"type": "integer", "minimum": 1, "maximum": 500, "default": 100}}, ["afterRevision"])),
        _op("resource.report", "Report observed host capacity and configured runtimes without probing or claiming GPU acceleration.", _object(), project=False),
        _op("session.open", "Register a host-local view session without changing scientific project revision.",
            _object({"name": {"type": "string", "minLength": 1, "maxLength": 200},
                     "clientKind": {"type": "string", "enum": ["native", "desktop", "cli", "mcp", "sdk"]}}, ["name", "clientKind"]), True),
        _op("session.list", "Read self-declared local client selections; these records do not authenticate clients or prove liveness.",
            _object({"includeClosed": {"type": "boolean", "default": False}})),
        _op("session.get", "Read one client selection and pending explicit navigation request.", _object(identity, identity)),
        _op("session.update", "Publish a client selection with independent session CAS and an observed scientific revision.",
            _object(selected, selected), True),
        _op("session.close", "Close one view session without changing project data.", _object(control, control), True),
        _op("session.navigate", "Request explicit navigation in a concrete GUI session; the host may defer or refuse to preserve drafts.",
            _object(selected, selected), True),
        _op("session.navigation.ack", "Acknowledge a navigation request, applying it only with current selection and project identities.",
            _object({**control, "navigationId": _ID, "observedProjectRevision": revision,
                     "outcome": {"type": "string", "enum": ["applied", "deferred", "refused"]},
                     "reason": {"type": "string", "minLength": 1, "maxLength": 1000}},
                    [*control, "navigationId", "observedProjectRevision", "outcome"]), True),
    ]
    for entry in result:
        if entry["name"].startswith("session."):
            entry["affectsProjectRevision"] = False
            entry["requiresExpectedRevision"] = False
    return result


def effect_basis(document):
    """Small metadata signatures only: never read image bytes or hash cell arrays."""
    from _workbench_store import canonical
    def digest(value):
        return hashlib.sha256(canonical(value).encode()).hexdigest()
    images = {}
    for image in document.get("images", []):
        analysis = image.get("analysis") or {}
        images[image["id"]] = {
            "source": digest({key: image.get(key) for key in ("sourceHash", "width", "height", "channels", "axes", "shape", "validSupport", "sourceArtifactGeneration")}),
            "labels": digest({"plane": analysis.get("labelsHash"), "volume": [(frame["timeIndex"], frame["channel"], frame["labelsHash"]) for frame in image.get("volumeFrames", [])]}),
            "calibration": digest({key: image.get(key) for key in ("pxPerUm", "voxelSizeUm", "timeStepSeconds")}),
            "metadata": digest({"name": image.get("name"), "metadataRevision": image.get("metadataRevision"), "planeRevision": analysis.get("analysisRevision"),
                                "measurementRevision": analysis.get("measurementRevision"),
                                "parameters": analysis.get("parameters"),
                                "volumeRevisions": [(frame["timeIndex"], frame["channel"], frame.get("analysisRevision"), frame.get("measurementRevision")) for frame in image.get("volumeFrames", [])],
                                "preferredSourceParameters": image.get("preferredSourceParameters"),
                                "preferredVolumeSelection": image.get("preferredVolumeSelection")}),
        }
    return {"revision": document["revision"], "images": images}


def event_for(before, document, request, actor):
    after = effect_basis(document)
    effects = []
    old_images = before.get("images", {})
    for image_id in sorted(set(old_images) | set(after["images"])):
        old, new = old_images.get(image_id, {}), after["images"].get(image_id, {})
        flags = {key + "Changed": old.get(key) != new.get(key) for key in ("source", "labels", "calibration", "metadata")}
        if any(flags.values()):
            effects.append({"imageId": image_id, **flags})
    return {"revision": document["revision"], "operation": request["operation"], "requestId": request["requestId"],
            "actor": copy.deepcopy(actor), "at": document["updatedAt"], "imageEffects": effects,
            "domains": [request["operation"].split(".")[0]]}


def save_event(connection, event):
    from _workbench_store import canonical
    connection.execute("CREATE TABLE IF NOT EXISTS commit_events (revision INTEGER PRIMARY KEY, event TEXT NOT NULL)")
    connection.execute("INSERT OR REPLACE INTO commit_events VALUES(?,?)", (event["revision"], canonical(event)))
    connection.execute("DELETE FROM commit_events WHERE revision <= ?", (event["revision"] - MAX_EVENTS,))


def changes(store, args):
    if store._publication_path().exists():
        store.read()  # Reconcile only the exceptional interrupted-publication case.
    connection = store.connection()
    try:
        connection.execute("BEGIN")
        row = connection.execute("SELECT revision FROM state WHERE id=1").fetchone()
        if row is None:
            fail("project-corrupt", "Project revision is missing.")
        current, after = row[0], args["afterRevision"]
        result = {"projectRevision": current, "nextRevision": after, "events": [], "hasMore": False, "resetRequired": False}
        if after == current:
            return result
        if after > current:
            return {**result, "nextRevision": current, "resetRequired": True}
        exists = connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='commit_events'").fetchone()
        if not exists:
            return {**result, "nextRevision": current, "resetRequired": True}
        rows = connection.execute("SELECT revision,event FROM commit_events WHERE revision>? ORDER BY revision LIMIT ?", (after, args.get("limit", 100))).fetchall()
        if not rows or rows[0][0] != after + 1 or any(row[0] != after + index + 1 for index, row in enumerate(rows)):
            return {**result, "nextRevision": current, "resetRequired": True}
        next_revision = rows[-1][0]
        return {**result, "nextRevision": next_revision, "events": [json.loads(row[1]) for row in rows], "hasMore": next_revision < current}
    finally:
        connection.close()


def _tables(connection):
    connection.execute("CREATE TABLE IF NOT EXISTS view_sessions (id TEXT PRIMARY KEY, document TEXT NOT NULL)")
    connection.execute("CREATE TABLE IF NOT EXISTS session_requests (request_id TEXT PRIMARY KEY, digest TEXT NOT NULL, response TEXT NOT NULL, created_at TEXT NOT NULL)")
    connection.commit()


def _validate_selection(document, selection):
    if not selection:
        return
    image_id = selection.get("imageId")
    if any(key in selection for key in ("target", "channel", "timeIndex", "plane", "index")) and image_id is None:
        fail("invalid-selection", "Image selection coordinates require an imageId.")
    if image_id is not None:
        image = next((image for image in document["images"] if image["id"] == image_id), None)
        if image is None:
            fail("selection-unavailable", "The selected acquisition is unavailable.", {"imageId": image_id})
        if selection.get("channel", 0) >= image["channels"] or selection.get("timeIndex", 0) >= image["timeCount"]:
            fail("selection-unavailable", "The selected channel or time point is unavailable.")
        target = selection.get("target", "plane")
        if target == "plane" and any(key in selection for key in ("plane", "index")):
            fail("invalid-selection", "Orthogonal slice coordinates require target volume.")
        if target == "volume":
            axis = selection.get("plane", "xy")
            length = {"xy": image["zCount"], "xz": image["height"], "yz": image["width"]}[axis]
            if selection.get("index", 0) >= length:
                fail("selection-unavailable", "The selected orthogonal source slice is unavailable.")
    if "workspaceId" in selection and not any(item["id"] == selection["workspaceId"] for item in document.get("workspaces", [])):
        fail("selection-unavailable", "The selected layer workspace is unavailable.")


def _merge_selection(current, selected):
    """Task-only changes keep spatial context; older clients keep their task."""
    if set(selected) == {"task"}:
        return {**copy.deepcopy(current), **copy.deepcopy(selected)}
    task = {"task": current["task"]} if "task" in current else {}
    return {**task, **copy.deepcopy(selected)}


def _describe(session, document):
    from _workbench_schema import WorkbenchError
    result = copy.deepcopy(session)
    try:
        _validate_selection(document, session["selection"])
        valid = True
    except WorkbenchError:
        valid = False
    result["selectionCurrent"] = valid and session["observedProjectRevision"] == document["revision"]
    result["selectionAvailable"] = valid
    result["projectRevision"] = document["revision"]
    result["identityIsSelfDeclared"] = True
    return result


def read_sessions(store, request):
    # Session observation must not deserialize a large unchanged scientific
    # document on every host refresh. Stale availability is explicitly unknown.
    if store._publication_path().exists():
        store.read()
    connection = store.connection()
    try:
        connection.execute("BEGIN")
        actual = connection.execute("SELECT revision FROM state WHERE id=1").fetchone()[0]
        exists = connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='view_sessions'").fetchone()
        args = request["arguments"]
        if request["operation"] == "session.list":
            rows = connection.execute("SELECT document FROM view_sessions ORDER BY id").fetchall() if exists else []
        else:
            rows = connection.execute("SELECT document FROM view_sessions WHERE id=?", (args["sessionId"],)).fetchall() if exists else []
            if not rows:
                fail("session-not-found", "The selected local client session is unavailable.")
        sessions = []
        for row in rows:
            value = json.loads(row[0])
            if request["operation"] == "session.list" and value["closed"] and not args.get("includeClosed", False):
                continue
            current = value["observedProjectRevision"] == actual
            value.update({"selectionCurrent": current, "selectionAvailable": True if current else None,
                          "projectRevision": actual, "identityIsSelfDeclared": True})
            sessions.append(value)
        result = {"sessions": sessions} if request["operation"] == "session.list" else {"session": sessions[0]}
        return {"schemaVersion": 1, "ok": True, "operation": request["operation"], "requestId": request["requestId"], "revision": actual, "result": result}
    finally:
        connection.close()


def execute(store, request, actor):
    from _workbench_store import canonical, request_hash, utc_now
    operation, args = request["operation"], request["arguments"]
    mutating = operation not in ("session.list", "session.get")
    if not mutating:
        return read_sessions(store, request)
    # Read/reconcile scientific state once. The transaction below then confirms
    # its revision; a session never silently adopts a newer scientific snapshot.
    document = store.read()
    connection = store.connection()
    try:
        _tables(connection)
        connection.execute("BEGIN IMMEDIATE" if mutating else "BEGIN")
        if mutating:
            replay = connection.execute("SELECT digest,response FROM session_requests WHERE request_id=?", (request["requestId"],)).fetchone()
            if replay:
                if replay[0] != request_hash(request):
                    fail("request-conflict", "requestId was already used for a different session command.")
                return json.loads(replay[1])
            scientific = connection.execute("SELECT 1 FROM requests WHERE request_id=?", (request["requestId"],)).fetchone()
            if scientific:
                fail("request-conflict", "requestId was already used for a scientific project command.")
        actual = connection.execute("SELECT revision FROM state WHERE id=1").fetchone()[0]
        if actual != document["revision"]:
            fail("revision-conflict", "Project changed while the session selection was read. Refresh before retrying.", {"actualRevision": actual, "expectedRevision": document["revision"]})
        if operation == "session.list":
            sessions = [json.loads(row[0]) for row in connection.execute("SELECT document FROM view_sessions ORDER BY id")]
            result = {"sessions": [_describe(item, document) for item in sessions if args.get("includeClosed", False) or not item["closed"]]}
        else:
            now = utc_now()
            if operation == "session.open":
                count = connection.execute("SELECT COUNT(*) FROM view_sessions").fetchone()[0]
                if count >= MAX_SESSIONS:
                    # Closed view rows have no scientific provenance role.
                    rows = connection.execute("SELECT id,document FROM view_sessions").fetchall()
                    closed = sorted((json.loads(row[1])["updatedAt"], row[0]) for row in rows if json.loads(row[1])["closed"])
                    if not closed:
                        fail("session-limit", "Close an inactive client session before opening another (maximum 200).")
                    connection.execute("DELETE FROM view_sessions WHERE id=?", (closed[0][1],))
                session = {"id": str(uuid.uuid4()), "name": args["name"], "clientKind": args["clientKind"], "sessionRevision": 0,
                           "observedProjectRevision": actual, "selection": {}, "closed": False, "updatedAt": now, "actor": copy.deepcopy(actor)}
            else:
                row = connection.execute("SELECT document FROM view_sessions WHERE id=?", (args["sessionId"],)).fetchone()
                if row is None:
                    fail("session-not-found", "The selected local client session is unavailable.")
                session = json.loads(row[0])
                if mutating:
                    if args["expectedSessionRevision"] != session["sessionRevision"]:
                        fail("session-conflict", "The client selection changed. Read the session before making another request.", {"expectedSessionRevision": args["expectedSessionRevision"], "actualSessionRevision": session["sessionRevision"]})
                    if session["closed"]:
                        fail("session-closed", "The selected client session has closed.")
                    if "observedProjectRevision" in args and args["observedProjectRevision"] != actual:
                        fail("revision-conflict", "Navigation or selection refers to an older project snapshot. Refresh before retrying.", {"expectedRevision": args["observedProjectRevision"], "actualRevision": actual})
                    if operation in ("session.update", "session.navigate"):
                        _validate_selection(document, args["selection"])
                        if operation == "session.update":
                            selection = _merge_selection(session["selection"], args["selection"])
                            _validate_selection(document, selection)
                            session["selection"] = selection
                            session["observedProjectRevision"] = actual
                        else:
                            if session["clientKind"] not in ("native", "desktop"):
                                fail("navigation-unavailable", "Only a concrete graphical client session can receive navigation requests.")
                            prior = session.get("navigation")
                            if prior and prior["status"] in ("pending", "deferred"):
                                fail("navigation-pending", "The host has an unresolved navigation request; read its status before issuing another.")
                            session["navigation"] = {"id": str(uuid.uuid4()), "status": "pending", "selection": copy.deepcopy(args["selection"]),
                                                     "requestedAt": now, "actor": copy.deepcopy(actor), "observedProjectRevision": actual}
                    elif operation == "session.navigation.ack":
                        navigation = session.get("navigation")
                        if navigation is None or navigation["id"] != args["navigationId"] or navigation["status"] not in ("pending", "deferred"):
                            fail("navigation-unavailable", "This navigation request is absent or has already been resolved.")
                        if args["outcome"] == "applied":
                            _validate_selection(document, navigation["selection"])
                            if navigation["observedProjectRevision"] != actual:
                                fail("navigation-stale", "Scientific state changed after this navigation request. Refuse it and request a current selection.")
                            selection = _merge_selection(session["selection"], navigation["selection"])
                            _validate_selection(document, selection)
                            session["selection"] = selection
                            session["observedProjectRevision"] = actual
                        navigation.update({"status": args["outcome"], "acknowledgedAt": now, "acknowledgedBy": copy.deepcopy(actor)})
                        if args.get("reason"):
                            navigation["reason"] = args["reason"]
                    elif operation == "session.close":
                        session["closed"] = True
                    session["sessionRevision"] += 1
                    session["updatedAt"] = now
            result = {"session": _describe(session, document)}
            if mutating:
                connection.execute("INSERT OR REPLACE INTO view_sessions VALUES(?,?)", (session["id"], canonical(session)))
        response = {"schemaVersion": 1, "operation": operation, "requestId": request["requestId"], "ok": True, "revision": actual, "result": result}
        if mutating:
            connection.execute("INSERT INTO session_requests VALUES(?,?,?,?)", (request["requestId"], request_hash(request), canonical(response), utc_now()))
            connection.execute("DELETE FROM session_requests WHERE request_id IN (SELECT request_id FROM session_requests ORDER BY created_at DESC LIMIT -1 OFFSET 10000)")
        connection.commit()
        return response
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def resource_report():
    import _workbench_microscopy_runtime as runtime
    packages = {}
    for name in ("numpy", "scipy", "scikit-image", "Pillow", "tifffile", "mcp", "zarr", "numcodecs"):
        try:
            packages[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            packages[name] = None
    memory = None
    try:
        memory = int(os.sysconf("SC_PHYS_PAGES")) * int(os.sysconf("SC_PAGE_SIZE"))
    except (AttributeError, OSError, ValueError):
        pass
    try:
        affinity = len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        affinity = None
    disk = shutil.disk_usage(os.getcwd())
    return {"python": {"version": platform.python_version(), "implementation": platform.python_implementation()},
            "platform": {"system": platform.system(), "machine": platform.machine()},
            "cpu": {"logicalCount": os.cpu_count(), "affinityCount": affinity},
            "memory": {"physicalBytes": memory, "availableBytes": None},
            "storage": {"scope": "runtime-working-directory", "freeBytes": disk.free, "totalBytes": disk.total},
            "accelerators": {"cuda": "not-probed", "mps": "not-probed", "verifiedAcceleration": False},
            "packages": packages, "microscopyRuntime": runtime.describe(),
            "runtimeConfiguration": __import__("workbench").runtime_configuration(),
            "limits": {"planePixels": 16000000, "volumeVoxels": 8000000, "decodeBytes": 256 * 1024 ** 2, "responseBytes": 24 * 1024 ** 2},
            "notes": ["Package metadata and host capacity are observations, not proof of algorithm compatibility or GPU acceleration.",
                      "Model probing and explicit execution report their own actual backend/device; this report imports no model or GPU framework.",
                      "Session actors and client kinds are self-declared local coordination identities, not authentication."]}
