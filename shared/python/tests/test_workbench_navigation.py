"""Task discovery and host navigation retain science, spatial context and access boundaries."""
from __future__ import annotations

from contextlib import redirect_stdout
import copy
import io
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

RUNTIME = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RUNTIME))
from _workbench_core import dispatch
from _workbench_mcp import ProjectScope
from _workbench_navigation import TASKS, catalogue, task_for_operation
from _workbench_schema import OPERATIONS, operation_descriptor
from _workbench_store import ProjectStore
import workbench


class NavigationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name) / "Navigation.ccproject"
        # Metadata-only fixture: navigation never needs to decode image bytes.
        self.document = {"schemaVersion": 1, "id": "project", "name": "Navigation", "revision": 0,
                         "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
                         "images": [{"id": "image", "name": "Volume", "channels": 3, "timeCount": 4,
                                     "zCount": 5, "width": 16, "height": 12, "sourceHash": "source"}],
                         "workspaces": [{"id": "workspace"}], "history": []}
        self.seed()

    def seed(self):
        request = self.request("project.create", {"name": "Navigation"})
        ProjectStore.create(str(self.project), copy.deepcopy(self.document), request,
                            {"schemaVersion": 1, "ok": True, "operation": "project.create", "requestId": request["requestId"], "revision": 0})

    def request(self, operation, arguments=None, **extra):
        return {"schemaVersion": 1, "operation": operation, "requestId": str(uuid.uuid4()),
                "projectPath": str(self.project), "arguments": arguments or {}, **extra}

    def call(self, operation, arguments=None):
        response = dispatch(self.request(operation, arguments))
        self.assertTrue(response["ok"], response)
        return response["result"]

    def session(self):
        return self.call("session.open", {"name": "Graphical host", "clientKind": "desktop"})["session"]

    def change(self, session, operation, **arguments):
        return self.call(operation, {"sessionId": session["id"], "expectedSessionRevision": session["sessionRevision"],
                                     "observedProjectRevision": 0, **arguments})["session"]

    def test_catalogue_cli_discovery_and_unknown_operations_are_project_free(self):
        request = {"schemaVersion": 1, "operation": "navigation.catalog", "requestId": "catalogue", "arguments": {}}
        with patch("_workbench_imaging.dependencies", side_effect=AssertionError("Navigation must not probe runtimes")):
            result = dispatch(request)
        self.assertTrue(result["ok"], result)
        self.assertNotIn("revision", result)
        self.assertEqual(result["result"]["defaultTask"], "preparation")
        canonical = {entry["name"]: entry for entry in OPERATIONS}
        references = [name for task in result["result"]["tasks"] for name in task["operationNames"]]
        self.assertEqual(len(references), len(set(references)))
        self.assertTrue(set(references) <= set(canonical))
        for entry in result["result"]["operations"]:
            self.assertEqual(entry["mutating"], canonical[entry["name"]]["mutating"])
            self.assertEqual(entry["requiresProject"], canonical[entry["name"]]["requiresProject"])
        self.assertEqual(task_for_operation("calibration.set"), "preparation")
        self.assertEqual(task_for_operation("temporal.track.run"), "measurements")
        self.assertEqual(task_for_operation("tiled.analysis.objects"), "measurements")
        self.assertEqual(task_for_operation("tiled.analysis.tiles"), "measurements")
        self.assertEqual(task_for_operation("tiled.analysis.labels.region"), "export")
        self.assertIsNone(task_for_operation("analysis.future-operation"))
        self.assertIsNone(task_for_operation("plugin.run"))
        future = catalogue([{"name": "analysis.future-operation", "mutating": False, "requiresProject": False}])
        self.assertEqual(future["unassignedOperationNames"], ["analysis.future-operation"])
        output = io.StringIO()
        with redirect_stdout(output):
            status = workbench.main(["call", "navigation.catalog"])
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output.getvalue())["result"], result["result"])
        discovery = dispatch({**request, "operation": "operations.discover", "arguments": {"prefix": "navigation."}})
        self.assertEqual([entry["name"] for entry in discovery["result"]["operations"]], ["navigation.catalog"])
        scope = ProjectScope(str(self.project))
        self.assertIsNone(scope.check(operation_descriptor("navigation.catalog"), {}))
        self.assertIsNotNone(scope.check(operation_descriptor("session.navigate"), {}))

    def test_typescript_tasks_and_runtime_manifest_match(self):
        source = (RUNTIME.parent / "workbench" / "navigation.ts").read_text(encoding="utf-8")
        match = re.search(r"export const WORKBENCH_TASKS = (\[.*?\]) as const;", source, re.S)
        self.assertIsNotNone(match)
        self.assertEqual(json.loads(match[1]), list(TASKS))
        manifest = (RUNTIME / "runtime-files.txt").read_text(encoding="utf-8").splitlines()
        self.assertIn("_workbench_navigation.py", manifest)

    def test_task_only_navigation_preserves_spatial_selection_and_science(self):
        session = self.session()
        spatial = {"imageId": "image", "target": "volume", "channel": 2, "timeIndex": 3, "plane": "xz", "index": 7}
        session = self.change(session, "session.update", selection={"task": "segmentation", **spatial})
        request = self.request("session.navigate", {"sessionId": session["id"], "expectedSessionRevision": session["sessionRevision"],
                               "observedProjectRevision": 0, "selection": {"task": "review"}})
        pending = dispatch(request)
        self.assertTrue(pending["ok"], pending)
        self.assertEqual(dispatch(request), pending)
        session = pending["result"]["session"]
        self.assertEqual(session["navigation"]["selection"], {"task": "review"})
        self.assertEqual(session["selection"], {"task": "segmentation", **spatial})
        session = self.change(session, "session.navigation.ack", navigationId=session["navigation"]["id"], outcome="applied")
        self.assertEqual(session["selection"], {"task": "review", **spatial})
        document = ProjectStore(str(self.project)).read()
        try:
            self.assertEqual(document["revision"], 0)
            self.assertEqual(list(document["history"]), [])
            self.assertEqual(list(document["images"]), self.document["images"])
        finally:
            if hasattr(document, "view"): document.view.close()

    def test_task_only_update_and_old_client_selection_are_compatible(self):
        session = self.session()
        session = self.change(session, "session.update", selection={"imageId": "image", "channel": 2})
        session = self.change(session, "session.update", selection={"task": "measurements"})
        self.assertEqual(session["selection"], {"task": "measurements", "imageId": "image", "channel": 2})
        # Old clients replace spatial coordinates, retaining optional new task state.
        session = self.change(session, "session.update", selection={"imageId": "image", "channel": 1})
        self.assertEqual(session["selection"], {"task": "measurements", "imageId": "image", "channel": 1})
        session = self.change(session, "session.update", selection={})
        self.assertEqual(session["selection"], {"task": "measurements"})

    def test_task_without_image_and_invalid_task_validation(self):
        session = self.session()
        session = self.change(session, "session.update", selection={"task": "export"})
        self.assertEqual(session["selection"], {"task": "export"})
        rejected = dispatch(self.request("session.navigate", {"sessionId": session["id"], "expectedSessionRevision": session["sessionRevision"],
                            "observedProjectRevision": 0, "selection": {"task": "unknown"}}))
        self.assertFalse(rejected["ok"])
        self.assertEqual(rejected["error"]["code"], "invalid-arguments")
        self.assertEqual(self.call("session.get", {"sessionId": session["id"]})["session"]["sessionRevision"], session["sessionRevision"])

    def test_navigation_cas_and_deferred_draft_do_not_apply_task(self):
        session = self.session()
        old_revision = session["sessionRevision"]
        session = self.change(session, "session.navigate", selection={"task": "workflows"})
        conflict = dispatch(self.request("session.update", {"sessionId": session["id"], "expectedSessionRevision": old_revision,
                            "observedProjectRevision": 0, "selection": {"task": "preparation"}}))
        self.assertEqual(conflict["error"]["code"], "session-conflict")
        session = self.change(session, "session.navigation.ack", navigationId=session["navigation"]["id"], outcome="deferred", reason="A draft needs review.")
        self.assertEqual(session["selection"], {})
        self.assertEqual(session["navigation"]["status"], "deferred")
        session = self.change(session, "session.navigation.ack", navigationId=session["navigation"]["id"], outcome="refused")
        self.assertEqual(session["selection"], {})

    def test_task_only_merge_rejects_removed_spatial_context_without_advancing_session(self):
        for collection in ("images", "workspaces"):
            with self.subTest(collection=collection):
                self.project = Path(self.temp.name) / (collection + ".ccproject")
                self.seed()
                session = self.session()
                selection = {"task": "segmentation", "imageId": "image", "workspaceId": "workspace"}
                session = self.change(session, "session.update", selection=selection)
                connection = ProjectStore(str(self.project)).connection()
                try:
                    connection.execute("DELETE FROM records WHERE collection=?", (collection,))
                    header = json.loads(connection.execute("SELECT document FROM state WHERE id=1").fetchone()[0])
                    header["revision"] = 1
                    connection.execute("UPDATE state SET revision=1,document=? WHERE id=1", (json.dumps(header),))
                    connection.commit()
                finally:
                    connection.close()
                control = {"sessionId": session["id"], "expectedSessionRevision": session["sessionRevision"],
                           "observedProjectRevision": 1}
                rejected = dispatch(self.request("session.update", {**control, "selection": {"task": "review"}}))
                self.assertEqual(rejected["error"]["code"], "selection-unavailable")
                unchanged = self.call("session.get", {"sessionId": session["id"]})["session"]
                self.assertEqual(unchanged["sessionRevision"], session["sessionRevision"])
                self.assertEqual(unchanged["observedProjectRevision"], 0)
                pending = self.call("session.navigate", {**control, "selection": {"task": "review"}})["session"]
                rejected = dispatch(self.request("session.navigation.ack", {
                    **control, "expectedSessionRevision": pending["sessionRevision"],
                    "navigationId": pending["navigation"]["id"], "outcome": "applied"}))
                self.assertEqual(rejected["error"]["code"], "selection-unavailable")
                unchanged = self.call("session.get", {"sessionId": session["id"]})["session"]
                self.assertEqual(unchanged["sessionRevision"], pending["sessionRevision"])
                self.assertEqual(unchanged["selection"], selection)
                self.assertEqual(unchanged["navigation"]["status"], "pending")


if __name__ == "__main__":
    unittest.main()
