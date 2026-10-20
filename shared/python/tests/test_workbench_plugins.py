"""Real subprocess extensions, exact scientific output and trust boundaries."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import _workbench_plugins as plugins
from _fixtures import use_legacy_storage
from _workbench_core import dispatch
from _workbench_schema import WorkbenchError
from _workbench_store import ProjectStore

try:
    import numpy as np
    from PIL import Image
    import tifffile
    import scipy
    import skimage
    SCIENCE_AVAILABLE = True
except ImportError:
    SCIENCE_AVAILABLE = False


SEGMENTER = """
import json, pathlib, sys
import numpy as np
request = json.loads(pathlib.Path(sys.argv[1]).read_text())
pixels = np.load(request["input"]["pixelsPath"], allow_pickle=False)
labels = np.where(pixels >= request["parameters"]["threshold"], 4294967295, 0).astype(np.uint32)
np.save(pathlib.Path(request["outputDirectory"]) / "labels.npy", labels, allow_pickle=False)
pathlib.Path(sys.argv[2]).write_text(json.dumps({"schemaVersion": 1, "labelsPath": "labels.npy"}))
"""

MEASUREMENT = """
import json, pathlib, sys
import numpy as np
request = json.loads(pathlib.Path(sys.argv[1]).read_text())
pixels = np.load(request["input"]["pixelsPath"], allow_pickle=False)
labels = np.load(request["input"]["labelsPath"], allow_pickle=False)
rows = [{"labelId": int(label), "values": {"meanRaw": float(pixels[labels == label].mean())}}
        for label in np.unique(labels) if label]
response = {"schemaVersion": 1, "measurements": rows, "summary": {"objects": len(rows)},
            "units": {"meanRaw": "raw-source", "objects": "count"}}
pathlib.Path(sys.argv[2]).write_text(json.dumps(response))
"""


@unittest.skipUnless(SCIENCE_AVAILABLE, "Install shared/python/requirements-analysis.txt")
class PluginTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project = self.root / "project"
        self.revision = 0
        self.call("project.create", {"name": "Plugin experiment"})
        self.source = self.root / "source.png"
        raw = np.zeros((12, 15), dtype=np.uint8)
        raw[1:3, 2:5] = 100
        raw[7:10, 9:13] = 200
        Image.fromarray(raw).save(self.source)
        self.raw = raw
        self.image_id = self.call("image.import", {"paths": [str(self.source)], "pxPerUm": 2})["importedImageIds"][0]

    def request(self, operation, arguments=None):
        request = {"schemaVersion": 1, "operation": operation, "requestId": str(uuid.uuid4()),
                   "projectPath": str(self.project), "arguments": arguments or {},
                   "actor": {"kind": "test", "name": "Plugin subprocess tests"}}
        if operation != "project.create":
            request["expectedRevision"] = self.revision
        return request

    def call(self, operation, arguments=None):
        response = dispatch(self.request(operation, arguments))
        self.assertTrue(response["ok"], response)
        self.revision = response.get("revision", self.revision)
        return response["result"]

    def failure(self, operation, arguments, code):
        response = dispatch(self.request(operation, arguments))
        self.assertFalse(response["ok"], response)
        self.assertEqual(response["error"]["code"], code, response)
        self.assertEqual(ProjectStore(str(self.project)).read()["revision"], self.revision)
        return response

    def make_plugin(self, name="segment", code=SEGMENTER, kind="segmentation", **updates):
        directory = self.root / (name + "-" + str(uuid.uuid4()))
        directory.mkdir()
        (directory / "main.py").write_text(code)
        manifest = {"schemaVersion": 1, "id": "org.test." + name, "version": "1.0.0",
                    "name": name, "kind": kind, "entryPoint": "main.py", "supportedDimensions": [2, 3],
                    "parameters": {"type": "object", "properties": {
                        "threshold": {"type": "number", "minimum": 0, "maximum": 65535, "default": 50}},
                        "required": [], "additionalProperties": False}}
        manifest.update(updates)
        path = directory / "plugin.json"
        path.write_text(json.dumps(manifest))
        return path

    def install(self, path, enable=True):
        plugin_id = self.call("plugin.install", {"manifestPath": str(path)})["plugin"]["pluginId"]
        if enable:
            self.call("plugin.setEnabled", {"pluginId": plugin_id, "enabled": True})
        return plugin_id

    def run_plugin(self, plugin_id, **kwargs):
        return self.call("plugin.run", {"pluginId": plugin_id, "imageId": self.image_id, **kwargs})

    def test_install_never_executes_retains_source_and_requires_explicit_enable(self):
        marker = self.root / "executed"
        path = self.make_plugin(code=f"open({str(marker)!r}, 'w').write('executed')\n" + SEGMENTER)
        plugin_id = self.install(path, enable=False)
        self.assertFalse(marker.exists())
        self.failure("plugin.run", {"pluginId": plugin_id, "imageId": self.image_id}, "plugin-disabled")
        self.assertFalse(marker.exists())
        # Moving/changing the original does not change retained version bytes.
        path.with_name("main.py").write_text("raise Exception('unretained source')\n")
        self.call("plugin.setEnabled", {"pluginId": plugin_id, "enabled": True})
        result = self.run_plugin(plugin_id)
        self.assertTrue(marker.exists())
        self.assertEqual(result["analysis"]["cells"][0]["labelId"], 4294967295)
        self.assertEqual(result["analysis"]["cells"][0]["areaPx"], 18)
        self.assertEqual(result["analysis"]["cells"][0]["areaUm2"], 4.5)
        self.assertEqual(result["analysis"]["cells"][0]["meanIntensity"], (6 * 100 + 12 * 200) / 18)
        self.assertEqual(result["run"]["sourceHash"], ProjectStore(str(self.project)).read()["images"][0]["sourceHash"])
        self.assertNotEqual(result["run"]["pluginSourceHash"], result["run"]["sourceHash"])

    def test_version_collision_tamper_disable_and_idempotent_install(self):
        path = self.make_plugin()
        plugin_id = self.install(path)
        self.assertTrue(self.call("plugin.install", {"manifestPath": str(path)})["alreadyInstalled"])
        path.with_name("main.py").write_text(SEGMENTER + "\n# changed source\n")
        self.failure("plugin.install", {"manifestPath": str(path)}, "plugin-version-conflict")
        self.call("plugin.setEnabled", {"pluginId": plugin_id, "enabled": False})
        self.failure("plugin.run", {"pluginId": plugin_id, "imageId": self.image_id}, "plugin-disabled")
        store = ProjectStore(str(self.project))
        record = store.read()["plugins"][0]
        (self.project / record["sourcePath"]).write_text("raise Exception('tampered')")
        listing = self.call("plugin.list")
        self.assertFalse(listing["plugins"][0]["available"])
        self.failure("plugin.setEnabled", {"pluginId": plugin_id, "enabled": True}, "artifact-changed")

    def test_measurements_become_stale_after_calibration_and_mask_changes(self):
        segmenter = self.install(self.make_plugin())
        self.run_plugin(segmenter)
        measurement = self.install(self.make_plugin("mean", MEASUREMENT, "measurement"))
        run = self.run_plugin(measurement)["run"]
        read = self.call("plugin.results", {"runId": run["runId"]})["runs"][0]
        self.assertFalse(read["stale"])
        self.assertEqual(read["output"]["measurements"][0]["values"]["meanRaw"], (6 * 100 + 12 * 200) / 18)
        self.call("calibration.set", {"imageId": self.image_id, "pxPerUm": 4})
        self.assertTrue(self.call("plugin.results", {"runId": run["runId"]})["runs"][0]["stale"])
        refreshed = self.run_plugin(measurement)["run"]
        self.call("mask.edit", {"imageId": self.image_id, "action": "delete", "labelIds": [4294967295]})
        self.assertTrue(self.call("plugin.results", {"runId": refreshed["runId"]})["runs"][0]["stale"])
        self.assertIn(refreshed["inputLabelsPath"], plugins.artifact_references(ProjectStore(str(self.project)).read()))

    def test_parameter_defaults_types_unknowns_and_pure_prediction(self):
        plugin_id = self.install(self.make_plugin())
        store = ProjectStore(str(self.project))
        document = store.read()
        before = copy.deepcopy(document)
        labels, provenance = plugins.predict(store, document, plugin_id, self.raw, {"threshold": 150})
        self.assertEqual(np.count_nonzero(labels), 12)
        self.assertEqual(provenance["parameters"], {"threshold": 150})
        self.assertEqual(document, before)
        self.assertEqual(store.read(), before)
        for values in ({"threshold": True}, {"threshold": -1}, {"unknown": 1}, {"threshold": float("inf")}):
            with self.assertRaises(WorkbenchError):
                plugins.predict(store, document, plugin_id, self.raw, values)

    def test_volumetric_segmentation_and_measurements_use_exact_voxels(self):
        source = self.root / "volume.tif"
        raw = np.zeros((4, 8, 10), dtype=np.uint16)
        raw[1:3, 2:5, 3:7] = 300
        tifffile.imwrite(source, raw, photometric="minisblack", metadata={"axes": "ZYX"})
        image_id = self.call("image.import", {"paths": [str(source)]})["importedImageIds"][0]
        self.call("volume.calibration.set", {"imageId": image_id, "voxelSizeUm": {"x": .5, "y": .25, "z": 2}})
        segmenter = self.install(self.make_plugin())
        result = self.call("plugin.run", {"pluginId": segmenter, "imageId": image_id,
                                         "target": "volume", "timeIndex": 0, "channel": 0})
        self.assertEqual(result["analysis"]["cells"][0]["voxelCount"], 24)
        self.assertEqual(result["analysis"]["cells"][0]["volumeUm3"], 6)
        measurement = self.install(self.make_plugin("mean", MEASUREMENT, "measurement"))
        run = self.call("plugin.run", {"pluginId": measurement, "imageId": image_id,
                                      "target": "volume", "timeIndex": 0, "channel": 0})["run"]
        output = self.call("plugin.results", {"runId": run["runId"]})["runs"][0]["output"]
        self.assertEqual(output["measurements"][0]["values"]["meanRaw"], 300)
        self.call("volume.calibration.set", {"imageId": image_id, "voxelSizeUm": {"z": 3}})
        self.assertTrue(self.call("plugin.results", {"runId": run["runId"]})["runs"][0]["stale"])

    def test_bad_dtype_shape_path_and_measurement_label_are_rejected(self):
        cases = [
            ("dtype", SEGMENTER.replace(".astype(np.uint32)", ".astype(np.float32)")),
            ("shape", SEGMENTER.replace("np.save(", "labels = labels[:1]\nnp.save(")),
            ("escape", SEGMENTER.replace('"labelsPath": "labels.npy"', '"labelsPath": "../pixels.npy"')),
        ]
        for name, code in cases:
            plugin_id = self.install(self.make_plugin(name, code))
            self.failure("plugin.run", {"pluginId": plugin_id, "imageId": self.image_id}, "invalid-plugin-output")
        self.run_plugin(self.install(self.make_plugin()))
        bad = MEASUREMENT.replace('"labelId": int(label)', '"labelId": 1234')
        plugin_id = self.install(self.make_plugin("badmetric", bad, "measurement"))
        self.failure("plugin.run", {"pluginId": plugin_id, "imageId": self.image_id}, "invalid-plugin-output")

    def test_timeouts_log_caps_and_failed_processes_do_not_commit(self):
        for name, code, timeout, expected in [
            ("timeout", "import time\ntime.sleep(10)", .1, "plugin-timeout"),
            ("logs", "print('x' * 100000)", 30, "plugin-output-limit"),
            ("failure", "raise RuntimeError('intentional failure')", 30, "plugin-failed"),
        ]:
            plugin_id = self.install(self.make_plugin(name, code, timeoutSeconds=timeout))
            self.failure("plugin.run", {"pluginId": plugin_id, "imageId": self.image_id}, expected)
        self.assertEqual(self.call("plugin.results")["total"], 0)

    def test_invalid_manifests_and_source_symlinks_never_execute(self):
        self.failure("plugin.install", {"manifestPath": str(self.make_plugin(kind="trainer"))}, "unsupported-plugin-kind")
        self.failure("plugin.install", {"manifestPath": str(self.make_plugin(entryPoint="../main.py"))}, "invalid-plugin")
        path = self.make_plugin("symlink")
        path.with_name("main.py").unlink()
        path.with_name("main.py").symlink_to(self.source)
        self.failure("plugin.install", {"manifestPath": str(path)}, "invalid-plugin")
        nested = {"type": "object", "properties": {"bad": {"type": "array"}},
                  "required": [], "additionalProperties": False}
        self.failure("plugin.install", {"manifestPath": str(self.make_plugin(parameters=nested))}, "invalid-plugin")

    def test_export_retains_plugin_versions_and_exact_run_artifacts(self):
        use_legacy_storage(self.project)
        segmenter = self.install(self.make_plugin())
        self.run_plugin(segmenter)
        measure = self.install(self.make_plugin("mean", MEASUREMENT, "measurement"))
        self.run_plugin(measure)
        document = ProjectStore(str(self.project)).read()
        destination = self.root / "export.zip"
        self.call("project.export", {"destination": str(destination)})
        with zipfile.ZipFile(destination) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            for path, expected in plugins.artifact_references(document).items():
                self.assertIn(path, archive.namelist())
                self.assertEqual(manifest["files"][path], expected)


if __name__ == "__main__":
    unittest.main()
