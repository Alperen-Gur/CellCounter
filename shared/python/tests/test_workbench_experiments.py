import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _workbench_experiments import apply, describe, summarize
from _workbench_schema import WorkbenchError


class ExperimentTests(unittest.TestCase):
    def setUp(self):
        def image(identifier, count, scale=2):
            return {"id": identifier, "pxPerUm": scale, "analysis": {
                "inputFingerprint": identifier,
                "cells": [{"areaPx": 4, "areaUm2": 1 if scale else None, "meanIntensity": 100}
                          for _ in range(count)]}}
        self.document = {"id": "project", "revision": 1, "images": [
            image("a", 2), image("b", 8), image("c", 20), image("d", 3, None),
            {"id": "pending", "pxPerUm": None}]}
        self.first = self.specimen("Donor 1")
        self.second = self.specimen("Donor 2")

    def specimen(self, name):
        return apply(self.document, "specimen.set", {
            "name": name, "experiment": "Experiment 1", "condition": "Vehicle", "role": "control"})["id"]

    def assign(self, specimen, images, **kwargs):
        return apply(self.document, "image.assign", {"specimenId": specimen, "imageIds": images, **kwargs})

    def test_replicate_means_weight_specimens_equally_not_images_or_objects(self):
        self.assign(self.first, ["a", "b"])
        self.assign(self.second, ["c"])
        result = summarize(self.document)
        group = result["conditions"][0]
        self.assertEqual(group["biologicalN"], 2)
        self.assertEqual(group["meanObjectsPerImage"], 12.5)  # mean((2+8)/2, 20)
        self.assertAlmostEqual(group["sdObjectsPerImage"], 10.6066017178)
        self.assertEqual(result["unassignedImageCount"], 2)

    def test_incomplete_specimens_and_missing_calibration_are_explicit(self):
        self.assign(self.first, ["a", "pending"])
        self.assign(self.second, ["c", "d"])
        result = summarize(self.document)
        group = result["conditions"][0]
        self.assertEqual(group["biologicalN"], 1)
        self.assertEqual(group["excludedIncompleteSpecimens"], 1)
        self.assertEqual(group["physicalBiologicalN"], 0)
        self.assertIsNone(group["meanObjectAreaUm2"])
        self.assertIsNone(group["sdObjectsPerImage"])

    def test_editing_assignment_or_analysis_changes_summary_fingerprint(self):
        self.assign(self.first, ["a"])
        previous = summarize(self.document)["inputFingerprint"]
        self.assign(self.first, ["b"])
        changed = summarize(self.document)["inputFingerprint"]
        self.assertNotEqual(changed, previous)
        self.document["images"][0]["analysis"]["inputFingerprint"] = "new-mask"
        self.assertNotEqual(changed, summarize(self.document)["inputFingerprint"])

    def test_well_bounds_and_one_specimen_per_well_are_atomic(self):
        plate = apply(self.document, "plate.set", {"name": "Plate 1", "rows": 8, "columns": 12})["id"]
        self.assign(self.first, ["a"], plateId=plate, wellRow=1, wellColumn=1)
        before = copy.deepcopy(self.document)
        with self.assertRaises(WorkbenchError):
            self.assign(self.second, ["b"], plateId=plate, wellRow=1, wellColumn=1)
        self.assertEqual(self.document, before)
        with self.assertRaises(WorkbenchError):
            self.assign(self.first, ["b"], plateId=plate, wellRow=9, wellColumn=1)
        with self.assertRaises(WorkbenchError):
            self.assign(self.first, ["b"], plateId=plate)
        self.assign(self.first, ["b"], plateId=plate, wellRow=8, wellColumn=12)
        before = copy.deepcopy(self.document)
        with self.assertRaises(WorkbenchError):
            apply(self.document, "plate.set", {"plateId": plate, "name": "Plate 1", "rows": 1, "columns": 1})
        self.assertEqual(self.document, before)

    def test_unique_specimens_and_unassignment_preserve_images(self):
        with self.assertRaises(WorkbenchError):
            self.specimen("donor 1")
        self.assign(self.first, ["a", "b"])
        before = copy.deepcopy(self.document["images"])
        apply(self.document, "image.unassign", {"imageIds": ["a"]})
        self.assertEqual(self.document["images"], before)
        self.assertEqual([item["imageId"] for item in describe(self.document)["assignments"]], ["b"])


if __name__ == "__main__":
    unittest.main()
