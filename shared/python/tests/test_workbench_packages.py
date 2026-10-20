"""Archive integrity, safe restoration and retained scientific state."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid
import warnings
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _fixtures import use_legacy_storage
from _workbench_core import dispatch
from _workbench_store import ProjectStore
import _workbench_packages as packages
from _workbench_schema import validate_value, WorkbenchError

try:
    import numpy as np
    from PIL import Image
    import scipy
    import skimage
    SCIENCE = True
except ImportError:
    SCIENCE = False


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "Original"
        self.revision = 0
        self.call("project.create", {"name": "Retained experiment"})
        use_legacy_storage(self.project)

    def request(self, operation, arguments=None, **extra):
        value = {"schemaVersion": 1, "operation": operation, "requestId": str(uuid.uuid4()),
                 "projectPath": str(self.project), "arguments": arguments or {},
                 "actor": {"kind": "test", "name": "Package tests"}}
        if operation not in ("project.create", "package.inspect", "package.restore"):
            value["expectedRevision"] = self.revision
        return {**value, **extra}

    def call(self, operation, arguments=None, **extra):
        response = dispatch(self.request(operation, arguments, **extra))
        self.assertTrue(response["ok"], response)
        self.revision = response.get("revision", self.revision)
        return response["result"]

    def export(self):
        path = self.root / (str(uuid.uuid4()) + ".zip")
        self.call("project.export", {"destination": str(path)})
        return path

    def modified(self, original, change):
        with zipfile.ZipFile(original) as archive:
            entries = [(info, archive.read(info)) for info in archive.infolist()]
        entries = change(entries)
        path = self.root / (str(uuid.uuid4()) + ".zip")
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w") as archive:
                for name, data in entries:
                    archive.writestr(name, data)
        return path

    def assert_rejected(self, path, code=None):
        target = self.root / ("Restored-" + str(uuid.uuid4()))
        response = dispatch(self.request("package.restore", {"path": str(path)}, projectPath=str(target)))
        self.assertFalse(response["ok"], response)
        if code:
            self.assertEqual(response["error"]["code"], code, response)
        self.assertFalse(target.exists(), "Verification failure must not publish a destination")
        self.assertEqual(list(self.root.glob(".cellcounter-restore-*")), [])
        return response

    def test_empty_package_inspection_without_project_and_restore_idempotency(self):
        path = self.export()
        report = self.call("package.inspect", {"path": str(path)}, projectPath="")
        self.assertTrue(report["integrity"]["verified"])
        self.assertEqual(report["package"]["imageCount"], 0)
        original = ProjectStore(str(self.project)).read()
        target = self.root / "Restored"
        request = self.request("package.restore", {"path": str(path), "name": "Reopened"}, projectPath=str(target))
        first = dispatch(request)
        self.assertTrue(first["ok"], first)
        self.assertEqual(dispatch(request), first)
        restored = ProjectStore(str(target)).read()
        self.assertEqual(restored["revision"], 0)
        self.assertNotEqual(restored["id"], original["id"])
        self.assertEqual(restored["name"], "Reopened")
        self.assertEqual(restored["history"][0]["operation"], "package.restore")
        self.assertEqual(restored["restoredHistory"][0]["operation"], "project.create")
        collision = dispatch({**request, "requestId": str(uuid.uuid4())})
        self.assertFalse(collision["ok"])
        self.assertEqual(collision["error"]["code"], "project-exists")

    @unittest.skipUnless(SCIENCE, "Install shared/python/requirements-analysis.txt")
    def test_exact_sources_labels_undo_workflows_and_measurements_survive_restore(self):
        raw = np.zeros((24, 24), dtype=np.uint16)
        raw[4:10, 5:13] = 2000
        path = self.root / "image.tif"
        Image.fromarray(raw).save(path)
        image_id = self.call("image.import", {"paths": [str(path)], "pxPerUm": 2})["importedImageIds"][0]
        parameters = {"method": "manual", "threshold": 1000, "minAreaPx": 1, "minDistancePx": 100}
        initial = self.call("analysis.run", {"imageId": image_id, "parameters": parameters})
        self.call("mask.edit", {"imageId": image_id, "action": "polygon", "labelId": 1,
                               "polygon": [[5, 4], [9, 4], [9, 10], [5, 10]]})
        saved = self.call("workflow.save", {"name": "Replay", "steps": [
            {"type": "analysis", "parameters": parameters}, {"type": "measurements"}, {"type": "summary"}]})
        self.call("job.create", {"workflowId": saved["workflow"]["id"], "imageIds": [image_id]})
        archive = self.export()
        source_document = ProjectStore(str(self.project)).read()
        target = self.root / "Restored images"
        result = self.call("package.restore", {"path": str(archive)}, projectPath=str(target))
        self.assertEqual(result["images"][0]["cellCount"], 1)
        restored = ProjectStore(str(target)).read()
        self.assertEqual(restored["jobs"][0]["status"], "paused")
        def scientific(value):
            if isinstance(value, dict): return {key: scientific(item) for key, item in value.items() if key != "measurementTable"}
            if isinstance(value, (list, tuple)) or type(value).__name__ == "CellRows": return [scientific(item) for item in value]
            return value
        self.assertEqual(scientific(restored["images"][0]), scientific(source_document["images"][0]))
        for name, digest in packages.artifact_references(restored).items():
            self.assertEqual(hashlib.sha256((target / name).read_bytes()).hexdigest(), digest)
        undone = dispatch(self.request("mask.undo", {"imageId": image_id},
                                       projectPath=str(target), expectedRevision=0))
        self.assertTrue(undone["ok"], undone)
        self.assertEqual(undone["result"]["cells"], initial["cells"])

    def test_hash_mismatch_and_unmanifested_file_rejected_before_target_creation(self):
        archive = self.export()
        changed = self.modified(archive, lambda entries: [
            (info, b"changed" if info.filename == "summary.json" else data) for info, data in entries])
        self.assert_rejected(changed, "package-integrity")
        extra = self.modified(archive, lambda entries: [*entries, ("undeclared.py", b"print('never')")])
        self.assert_rejected(extra, "invalid-package")

    def test_traversal_duplicate_and_symlink_members_rejected(self):
        archive = self.export()
        traversal = self.modified(archive, lambda entries: [*entries, ("../escaped", b"bad")])
        self.assert_rejected(traversal, "invalid-package")
        duplicate = self.modified(archive, lambda entries: [*entries, ("project.json", b"{}")])
        self.assert_rejected(duplicate, "invalid-package")
        link = zipfile.ZipInfo("linked")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        symlink = self.modified(archive, lambda entries: [*entries, (link, b"/tmp/other")])
        self.assert_rejected(symlink, "invalid-package")
        self.assertFalse((self.root / "escaped").exists())

    def test_size_budget_and_missing_dependencies_do_not_execute_or_mutate(self):
        archive = self.export()
        with patch.object(packages, "MAX_EXPANDED_BYTES", 1):
            self.assert_rejected(archive, "package-too-large")
        versions = {"python": "3.11.0", "packages": {name: None for name in packages.RUNTIME_PACKAGES}}
        with patch.object(packages, "runtime_versions", return_value=versions):
            report = self.call("package.inspect", {"path": str(archive)}, projectPath="")
            self.assertFalse(report["dependencies"]["canReexecute"])
            result = self.call("package.restore", {"path": str(archive)}, projectPath=str(self.root / "No dependencies"))
            self.assertFalse(result["dependencies"]["canReexecute"])

    def test_restored_plugin_is_disabled_without_execution_and_retained_exactly(self):
        marker = self.root / "plugin-executed"
        source = f"from pathlib import Path\nPath({str(marker)!r}).write_text('executed')\n"
        (self.root / "main.py").write_text(source)
        manifest = {"schemaVersion": 1, "id": "org.test.restore", "version": "1.0",
                    "name": "Retained plugin", "kind": "measurement", "entryPoint": "main.py",
                    "supportedDimensions": [2]}
        path = self.root / "plugin.json"
        path.write_text(json.dumps(manifest))
        plugin_id = self.call("plugin.install", {"manifestPath": str(path)})["plugin"]["pluginId"]
        self.call("plugin.setEnabled", {"pluginId": plugin_id, "enabled": True})
        archive = self.export()
        report = self.call("package.inspect", {"path": str(archive)})
        self.assertEqual(report["dependencies"]["plugins"][0]["id"], plugin_id)
        result = self.call("package.restore", {"path": str(archive)}, projectPath=str(self.root / "Plugin restore"))
        self.assertFalse(result["plugins"][0]["enabled"])
        self.assertFalse(marker.exists())

    def test_scalar_union_and_bounded_generic_parameter_schema(self):
        scalar = {"type": ["number", "boolean", "string"], "minLength": 0, "maxLength": 32}
        for value in (1.5, True, False, "", "selection"):
            validate_value(value, scalar)
        for value in (None, float("nan"), [], {}):
            with self.assertRaises(WorkbenchError):
                validate_value(value, scalar)
        generic = {"type": "object", "properties": {}, "additionalProperties": True}
        validate_value({"nested": {"values": [0, None, ""]}}, generic)
        with self.assertRaises(WorkbenchError):
            validate_value({"bad": {"value": float("inf")}}, generic)
        with self.assertRaises(WorkbenchError):
            validate_value({str(key): key for key in range(65)}, generic)


if __name__ == "__main__":
    unittest.main()
