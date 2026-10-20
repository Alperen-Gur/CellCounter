"""Reference approval, specimen holdouts and real paired plugin evaluation."""
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _workbench_core import dispatch
from _workbench_store import ProjectStore
from _workbench_metrics import evaluate_masks, aggregate_metrics

try:
    import numpy as np
    import tifffile
    import scipy
    import skimage
    SCIENCE = True
except ImportError:
    SCIENCE = False


@unittest.skipUnless(SCIENCE, "Install analysis requirements")
class AdaptationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "References.ccproject"
        self.revision = 0
        self.call("project.create", {"name": "References"})
        self.images, self.specimens = [], []
        for index in range(3):
            raw = np.zeros((20, 24), np.uint16)
            raw[3:8, 4:10] = (index + 1) * 100
            path = self.root / f"image-{index}.tif"
            tifffile.imwrite(path, raw, metadata={"axes": "YX"})
            image_id = self.call("image.import", {"paths": [str(path)]})["importedImageIds"][0]
            self.images.append(image_id)
            self.call("analysis.run", {"imageId": image_id, "parameters": {
                "method": "manual", "threshold": 50, "minDistancePx": 50, "minAreaPx": 1,
            }})
            specimen_id = self.call("specimen.set", {
                "name": f"Specimen {index}", "experiment": "Study", "condition": "Control", "role": "control",
            })["id"]
            self.specimens.append(specimen_id)
            self.call("image.assign", {"imageIds": [image_id], "specimenId": specimen_id})
            self.call("adaptation.reference.set", {"imageId": image_id, "approved": True})

    def request(self, operation, arguments):
        return {"schemaVersion": 1, "operation": operation, "requestId": str(uuid.uuid4()),
                "projectPath": str(self.project), "arguments": arguments,
                "actor": {"kind": "human", "name": "Reference reviewer"},
                **({"expectedRevision": self.revision} if operation != "project.create" else {})}

    def call(self, operation, arguments):
        response = dispatch(self.request(operation, arguments))
        self.assertTrue(response["ok"], response)
        self.revision = response.get("revision", self.revision)
        return response["result"]

    def dataset(self):
        return self.call("adaptation.dataset.create", {
            "name": "Frozen references", "imageIds": self.images,
            "validationSpecimenIds": [self.specimens[1]], "testSpecimenIds": [self.specimens[2]],
        })["dataset"]

    def install(self):
        folder = self.root / "plugin"
        folder.mkdir()
        (folder / "segment.py").write_text(
            "import json, sys\n"
            "from pathlib import Path\n"
            "import numpy as np\n"
            "request=json.loads(Path(sys.argv[1]).read_text())\n"
            "raw=np.load(request['input']['pixelsPath'],allow_pickle=False)\n"
            "labels=(raw>request['parameters']['threshold']).astype(np.uint32)\n"
            "np.save(Path(request['outputDirectory'])/'labels.npy',labels,allow_pickle=False)\n"
            "Path(sys.argv[2]).write_text(json.dumps({'schemaVersion':1,'labelsPath':'labels.npy'}))\n"
        )
        manifest = {"schemaVersion": 1, "id": "org.example.threshold", "version": "1",
                    "name": "Threshold fixture", "kind": "segmentation", "entryPoint": "segment.py",
                    "supportedDimensions": [2],
                    "parameters": {"type": "object", "properties": {
                        "threshold": {"type": "number", "minimum": 0, "maximum": 10000, "default": 50}},
                        "required": [], "additionalProperties": False}}
        path = folder / "manifest.json"
        path.write_text(json.dumps(manifest))
        plugin = self.call("plugin.install", {"manifestPath": str(path)})["plugin"]
        self.call("plugin.setEnabled", {"pluginId": plugin["pluginId"], "enabled": True})
        return plugin["pluginId"]

    def test_approval_tracks_geometry_and_frozen_dataset_survives_later_edits(self):
        dataset = self.dataset()
        self.assertEqual(dataset["counts"], {"train": 1, "validation": 1, "test": 1})
        self.call("mask.edit", {"imageId": self.images[2], "action": "delete", "labelIds": [1]})
        saved = self.call("adaptation.dataset.get", {"datasetId": dataset["id"]})["dataset"]
        self.assertFalse(saved["samples"][2]["currentReference"])
        sample = saved["samples"][2]
        labels = np.load(self.project / sample["labelsPath"], allow_pickle=False)
        self.assertEqual(np.count_nonzero(labels), 30)
        bad = dispatch(self.request("adaptation.dataset.create", {
            "name": "Stale", "imageIds": self.images, "validationSpecimenIds": [self.specimens[1]],
            "testSpecimenIds": [self.specimens[2]],
        }))
        self.assertEqual(bad["error"]["code"], "reference-required")

    def test_frozen_test_specimens_excluded_even_after_reassignment(self):
        self.dataset()
        suggestion = self.call("adaptation.suggest", {"limit": 20})
        self.assertEqual({item["imageId"] for item in suggestion["suggestions"]}, set(self.images[:2]))
        # Reassignment cannot turn the same held-out acquisition into training data.
        self.call("image.assign", {"imageIds": [self.images[2]], "specimenId": self.specimens[0]})
        again = self.call("adaptation.suggest", {"limit": 20})
        self.assertNotIn(self.images[2], {item["imageId"] for item in again["suggestions"]})
        self.assertEqual(suggestion["method"], "deterministic-diversity-and-heuristic-difficulty")

    def test_real_plugins_compare_same_untouched_reference_and_retain_predictions(self):
        dataset = self.dataset()
        plugin_id = self.install()
        before = ProjectStore(str(self.project)).read()["images"]
        report = self.call("adaptation.evaluate", {
            "datasetId": dataset["id"], "baseline": {"pluginId": plugin_id, "parameters": {"threshold": 500}},
            "candidate": {"pluginId": plugin_id, "parameters": {"threshold": 50}},
        })["evaluation"]
        self.assertEqual(report["baseline"]["falseNegatives"], 1)
        self.assertEqual(report["candidate"]["f1"], 1)
        self.assertEqual(report["candidate"]["ap50"], 1)
        self.assertEqual(report["delta"]["f1"], 1)
        self.assertEqual(report["biologicalTestN"], 1)
        self.assertEqual(report["evaluationNumber"], 1)
        self.assertEqual(before, ProjectStore(str(self.project)).read()["images"])
        retained = report["images"][0]["predictions"]["candidate"]
        self.assertEqual(np.count_nonzero(np.load(self.project / retained["labelsPath"], allow_pickle=False)), 30)
        inspected = self.call("adaptation.dataset.get", {"datasetId": dataset["id"]})["dataset"]
        self.assertEqual(inspected["fingerprint"], dataset["fingerprint"])
        self.assertEqual(len(inspected["evaluations"]), 1)

    def test_split_overlap_and_changed_reference_artifact_fail(self):
        invalid = dispatch(self.request("adaptation.dataset.create", {
            "name": "Leaked", "imageIds": self.images, "validationSpecimenIds": [self.specimens[1]],
            "testSpecimenIds": [self.specimens[1]],
        }))
        self.assertEqual(invalid["error"]["code"], "split-overlap")
        dataset = self.dataset()
        plugin_id = self.install()
        sample = dataset["samples"][2]
        (self.project / sample["labelsPath"]).write_bytes(b"changed")
        response = dispatch(self.request("adaptation.evaluate", {
            "datasetId": dataset["id"], "baseline": {"pluginId": plugin_id}, "candidate": {"pluginId": plugin_id},
        }))
        self.assertFalse(response["ok"])
        self.assertIn(response["error"]["code"], ("artifact-changed", "invalid-dataset"))

    def test_instance_metrics_ignore_ids_support_negatives_and_stream_aggregation(self):
        truth = np.array([[9, 9, 0], [0, 0, 50]], np.uint32)
        predicted = np.array([[4000000000, 4000000000, 0], [0, 0, 7]], np.uint32)
        empty = np.zeros_like(truth)
        perfect = evaluate_masks([predicted], [truth])
        negative = evaluate_masks([empty], [empty], allow_empty_reference=True)
        false_positive = evaluate_masks([predicted], [empty], allow_empty_reference=True)
        self.assertEqual(perfect["f1"], 1)
        self.assertEqual(negative["ap50"], 1)
        self.assertEqual(false_positive["falsePositives"], 2)
        combined = aggregate_metrics([perfect, negative, false_positive])
        direct = evaluate_masks([predicted, empty, predicted], [truth, empty, empty], allow_empty_reference=True)
        self.assertEqual(combined, direct)


if __name__ == "__main__":
    unittest.main()
