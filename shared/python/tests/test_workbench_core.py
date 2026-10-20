"""Behavioral tests for the shared scientific and persistence boundary."""
from __future__ import annotations

import csv
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import _workbench_imaging as imaging
from _fixtures import use_legacy_storage
from _workbench_core import dispatch
from _workbench_store import ProjectStore

try:
    import numpy as np
    from PIL import Image
    import tifffile
    import skimage
    import scipy
    SCIENCE_AVAILABLE = True
except ImportError:
    SCIENCE_AVAILABLE = False


@unittest.skipUnless(SCIENCE_AVAILABLE, "Install shared/python/requirements-analysis.txt")
class WorkbenchCoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "Experiment"
        self.revision = 0
        self.actor = {"kind": "test", "name": "Core behavior tests"}
        created = self.call("project.create", {"name": "Example experiment"})
        self.assertEqual(created["revision"], 0)
        self.source = self.root / "source.png"
        values = np.zeros((12, 15), dtype=np.uint8)
        values[1:3, 1:4] = 100  # 6 exact pixels.
        values[6:9, 8:12] = 200  # 12 exact pixels.
        Image.fromarray(values).save(self.source)
        self.parameters = {"method": "manual", "threshold": 50, "polarity": "bright",
                           "minAreaPx": 1, "minDistancePx": 100, "channel": 0, "zProjection": "max"}

    def request(self, operation, arguments=None, **kwargs):
        request = {"schemaVersion": 1, "operation": operation, "requestId": str(uuid.uuid4()),
                   "projectPath": str(self.project), "actor": self.actor, "arguments": arguments or {}}
        if operation not in ("project.create", "capabilities"):
            request["expectedRevision"] = self.revision
        request.update(kwargs)
        return request

    def call(self, operation, arguments=None, **kwargs):
        response = dispatch(self.request(operation, arguments, **kwargs))
        self.assertTrue(response["ok"], response)
        self.revision = response.get("revision", self.revision)
        return response

    def imported(self, scale=2):
        arguments = {"paths": [str(self.source)]}
        if scale is not None:
            arguments["pxPerUm"] = scale
        response = self.call("image.import", arguments)
        return response["result"]["importedImageIds"][0]

    def analyzed(self, scale=2):
        image_id = self.imported(scale)
        response = self.call("analysis.run", {"imageId": image_id, "parameters": self.parameters})
        return image_id, response["result"]

    def test_complete_flow_exact_pixels_raw_intensity_and_export(self):
        use_legacy_storage(self.project)
        image_id, result = self.analyzed()
        self.assertEqual(result["cellCount"], 2)
        cells = sorted(result["cells"], key=lambda cell: cell["areaPx"])
        self.assertEqual([cell["areaPx"] for cell in cells], [6, 12])
        self.assertEqual([cell["areaUm2"] for cell in cells], [1.5, 3])
        self.assertEqual([cell["meanIntensity"] for cell in cells], [100, 200])
        self.assertEqual(cells[0]["cx"], 2.5)
        self.assertEqual(cells[0]["cy"], 2.0)
        measured = self.call("measurements.get", {"imageId": image_id})["result"]
        self.assertEqual(result["inputFingerprint"], measured["inputFingerprint"])
        summary = self.call("summary.get")["result"]
        self.assertEqual(summary["cellCount"], 2)
        self.assertEqual(summary["images"][0]["totalAreaPx"], 18)
        destination = self.root / "analysis.zip"
        exported = self.call("project.export", {"destination": str(destination)})
        with zipfile.ZipFile(destination) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            for path, digest in manifest["files"].items():
                self.assertEqual(hashlib.sha256(archive.read(path)).hexdigest(), digest)
            project = json.loads(archive.read("project.json"))
            image = project["images"][0]
            labels = np.load(io.BytesIO(archive.read(image["analysis"]["labelsPath"])), allow_pickle=False)
            self.assertEqual(int(np.count_nonzero(labels)), 18)
            self.assertEqual(archive.read(image["sourcePath"]), self.source.read_bytes())
            rows = list(csv.DictReader(io.StringIO(archive.read("measurements.csv").decode())))
            self.assertEqual(sorted(int(row["area_px"]) for row in rows), [6, 12])
            self.assertEqual(json.loads(archive.read("summary.json"))["sourceRevision"], exported["result"]["sourceRevision"])

    def test_preview_is_read_only_and_raw_display_has_separate_overlay(self):
        image_id = self.imported()
        before = self.revision
        preview = self.call("analysis.preview", {"imageId": image_id, "parameters": self.parameters})
        self.assertEqual(preview["revision"], before)
        self.assertEqual(preview["result"]["cellCount"], 2)
        self.assertTrue(preview["result"]["dataUrl"].startswith("data:image/png;base64,"))
        self.assertNotEqual(preview["result"]["dataUrl"], preview["result"]["overlayDataUrl"])
        inspected = self.call("project.inspect")["result"]
        self.assertEqual(inspected["images"][0]["status"], "imported")

    def test_same_count_polygon_edit_changes_area_intensity_and_fingerprint(self):
        image_id, original = self.analyzed()
        first = min(original["cells"], key=lambda cell: cell["areaPx"])
        edited = self.call("mask.edit", {
            "imageId": image_id, "action": "polygon", "labelId": first["labelId"],
            "polygon": [[1, 1], [3, 1], [3, 3], [1, 3]],
        })["result"]
        self.assertEqual(edited["cellCount"], original["cellCount"])
        self.assertEqual(sorted(cell["areaPx"] for cell in edited["cells"]), [4, 12])
        self.assertNotEqual(edited["inputFingerprint"], original["inputFingerprint"])
        self.assertEqual(self.call("summary.get")["result"]["images"][0]["totalAreaPx"], 16)
        restored = self.call("mask.undo", {"imageId": image_id})["result"]
        self.assertEqual(sorted(cell["areaPx"] for cell in restored["cells"]), [6, 12])

    def test_calibration_preserves_masks_and_updates_all_physical_measurements(self):
        image_id, original = self.analyzed()
        store = ProjectStore(str(self.project))
        label_hash = store.read()["images"][0]["analysis"]["labelsHash"]
        updated = self.call("calibration.set", {"imageId": image_id, "pxPerUm": 4})["result"]
        self.assertEqual(store.read()["images"][0]["analysis"]["labelsHash"], label_hash)
        for before, after in zip(original["cells"], updated["cells"]):
            self.assertEqual(before["areaPx"], after["areaPx"])
            self.assertEqual(before["areaUm2"] / 4, after["areaUm2"])
            self.assertEqual(before["diameterUm"] / 2, after["diameterUm"])
        self.assertEqual(original["analysisRevision"], updated["analysisRevision"])
        self.assertGreater(updated["measurementRevision"], original["measurementRevision"])
        self.assertNotEqual(updated["inputFingerprint"], original["inputFingerprint"])

    def test_unknown_calibration_never_becomes_one_micrometre_per_pixel(self):
        image_id, result = self.analyzed(None)
        self.assertFalse(result["calibrated"])
        self.assertTrue(all(cell["areaUm2"] is None and cell["diameterUm"] is None for cell in result["cells"]))
        self.assertIsNone(self.call("summary.get")["result"]["images"][0]["totalAreaUm2"])
        self.assertEqual(self.call("calibration.set", {"imageId": image_id, "pxPerUm": 2})["result"]["cellCount"], 2)

    def test_idempotent_mutation_replays_exact_result_but_payload_reuse_fails(self):
        image_id = self.imported()
        request = self.request("analysis.run", {"imageId": image_id, "parameters": self.parameters})
        first = dispatch(request)
        self.assertTrue(first["ok"], first)
        self.assertEqual(dispatch(request), first)
        request["arguments"]["parameters"] = {**self.parameters, "threshold": 150}
        conflict = dispatch(request)
        self.assertFalse(conflict["ok"])
        self.assertEqual(conflict["error"]["code"], "request-conflict")
        self.assertEqual(ProjectStore(str(self.project)).read()["revision"], first["revision"])

    def test_stale_async_result_cannot_replace_concurrent_calibration(self):
        image_id = self.imported()
        stale_request = self.request("analysis.run", {"imageId": image_id, "parameters": self.parameters})
        actual_segment = imaging.segment

        def concurrent_change(plane, parameters, valid_support=None):
            changed = dispatch(self.request("calibration.set", {"imageId": image_id, "pxPerUm": 4}))
            self.assertTrue(changed["ok"], changed)
            return actual_segment(plane, parameters, valid_support)

        with patch.object(imaging, "segment", side_effect=concurrent_change):
            result = dispatch(stale_request)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "revision-conflict")
        document = ProjectStore(str(self.project)).read()
        self.assertEqual(document["images"][0]["pxPerUm"], 4)
        self.assertNotIn("analysis", document["images"][0])

    def test_merge_preserves_exact_union_and_undo_uses_current_calibration(self):
        image_id, original = self.analyzed()
        ids = [cell["labelId"] for cell in original["cells"]]
        merged = self.call("mask.edit", {"imageId": image_id, "action": "merge", "labelIds": ids})["result"]
        self.assertEqual(merged["cellCount"], 1)
        self.assertEqual(merged["cells"][0]["areaPx"], 18)
        self.call("calibration.set", {"imageId": image_id, "pxPerUm": 4})
        undone = self.call("mask.undo", {"imageId": image_id})["result"]
        self.assertEqual(sorted(cell["areaUm2"] for cell in undone["cells"]), [6 / 16, 12 / 16])
        self.assertEqual(undone["pxPerUm"], 4)

    def test_empty_analysis_keeps_label_grid_for_manual_polygon(self):
        image_id = self.imported()
        empty = self.call("analysis.run", {"imageId": image_id,
                                          "parameters": {**self.parameters, "threshold": 255}})
        self.assertEqual(empty["result"]["cellCount"], 0)
        added = self.call("mask.edit", {"imageId": image_id, "action": "polygon",
                                       "polygon": [[1, 1], [3, 1], [3, 3], [1, 3]]})
        self.assertEqual(added["result"]["cells"][0]["areaPx"], 4)

    def test_overlap_and_stale_edits_fail_without_modifying_results(self):
        image_id, original = self.analyzed()
        result = dispatch(self.request("mask.edit", {
            "imageId": image_id, "action": "polygon",
            "polygon": [[0, 0], [5, 0], [5, 5], [0, 5]],
        }))
        self.assertEqual(result["error"]["code"], "label-overlap")
        stale = dispatch(self.request("mask.edit", {"imageId": image_id, "action": "delete",
                                                   "labelIds": [original["cells"][0]["labelId"]]},
                                      expectedRevision=self.revision - 1))
        self.assertEqual(stale["error"]["code"], "revision-conflict")
        self.assertEqual(self.call("measurements.get", {"imageId": image_id})["result"]["cellCount"], 2)

    def test_tiff_selection_preserves_channel_raw_values_and_stored_preview(self):
        values = np.zeros((2, 12, 15), dtype=np.uint16)
        values[0, 1:3, 1:4] = 100
        values[1, 6:9, 8:12] = 4000
        source = self.root / "channels.tiff"
        tifffile.imwrite(source, values, photometric="minisblack", metadata={"axes": "CYX"})
        image_id = self.call("image.import", {"paths": [str(source)]})["result"]["importedImageIds"][0]
        parameters = {**self.parameters, "channel": 1}
        analyzed = self.call("analysis.run", {"imageId": image_id, "parameters": parameters})["result"]
        self.assertEqual(analyzed["cells"][0]["areaPx"], 12)
        self.assertEqual(analyzed["cells"][0]["meanIntensity"], 4000)
        preview = self.call("image.preview", {"imageId": image_id})["result"]
        self.assertEqual(preview["parameters"]["channel"], 1)
        self.assertEqual(preview["displayRange"], [0, 4000])
        self.assertFalse(preview["overlayIncluded"])
        invalid = dispatch(self.request("analysis.preview", {"imageId": image_id,
                                                            "parameters": {**self.parameters, "channel": 3}}))
        self.assertEqual(invalid["error"]["code"], "channel-unavailable")

    def test_multitime_can_be_imported_but_not_silently_analyzed_at_time_zero(self):
        source = self.root / "time.tiff"
        tifffile.imwrite(source, np.zeros((2, 1, 12, 15), dtype=np.uint8), photometric="minisblack",
                         metadata={"axes": "TZYX"})
        image_id = self.call("image.import", {"paths": [str(source)]})["result"]["importedImageIds"][0]
        result = dispatch(self.request("analysis.run", {"imageId": image_id, "parameters": self.parameters}))
        self.assertEqual(result["error"]["code"], "unsupported-time-selection")

    def test_exports_never_overwrite_and_identical_request_replays(self):
        self.analyzed()
        destination = self.root / "export.zip"
        request = self.request("project.export", {"destination": str(destination)})
        first = dispatch(request)
        self.assertTrue(first["ok"], first)
        content = destination.read_bytes()
        self.assertEqual(dispatch(request), first)
        self.revision = first["revision"]
        second = dispatch(self.request("project.export", {"destination": str(destination)}))
        self.assertEqual(second["error"]["code"], "destination-exists")
        self.assertEqual(destination.read_bytes(), content)

    def test_tampered_sources_are_not_exported_as_current_results(self):
        self.analyzed()
        store = ProjectStore(str(self.project))
        image = store.read()["images"][0]
        (self.project / image["sourcePath"]).write_bytes(b"tampered")
        result = dispatch(self.request("project.export", {"destination": str(self.root / "bad.zip")}))
        self.assertEqual(result["error"]["code"], "artifact-changed")
        self.assertFalse((self.root / "bad.zip").exists())

    def test_artifact_crash_before_publish_leaves_no_partial_hash_path(self):
        store = ProjectStore(str(self.project))
        data = b"an immutable artifact"
        expected = self.project / "artifacts" / (hashlib.sha256(data).hexdigest() + ".test")
        with patch("_workbench_store.os.link", side_effect=OSError("simulated failure")):
            with self.assertRaises(OSError):
                store.put_bytes(data, ".test")
        self.assertFalse(expected.exists())
        relative, _ = store.put_bytes(data, ".test")
        self.assertEqual((self.project / relative).read_bytes(), data)

    def saved_workflow(self, export=False, **extra):
        steps = [{"type": "analysis", "parameters": self.parameters},
                 {"type": "measurements"}, {"type": "summary"}]
        if export:
            steps.append({"type": "export"})
        return self.call("workflow.save", {"name": "Cell analysis", "steps": steps, **extra})["result"]["workflow"]

    def test_workflow_versions_are_immutable_and_jobs_checkpoint_atomically(self):
        image_id = self.imported()
        workflow = self.saved_workflow()
        job = self.call("job.create", {"workflowId": workflow["id"], "imageIds": [image_id]})["result"]["job"]
        updated = self.call("workflow.save", {"workflowId": workflow["id"], "name": "Changed threshold",
            "steps": [{"type": "analysis", "parameters": {**self.parameters, "threshold": 150}},
                      {"type": "measurements"}, {"type": "summary"}]})["result"]["workflow"]
        self.assertEqual(updated["version"], 2)
        self.assertEqual(job["workflow"]["version"], 1)
        request = self.request("job.advance", {"jobId": job["id"]})
        first = dispatch(request)
        self.assertTrue(first["ok"], first)
        self.revision = first["revision"]
        checkpoint = first["result"]["job"]
        self.assertEqual(checkpoint["checkpoints"][0]["cellCount"], 2)
        self.assertEqual(checkpoint["progress"], {"completed": 1, "total": 2})
        self.assertEqual(dispatch(request), first)
        self.call("job.pause", {"jobId": job["id"]})
        rejected = dispatch(self.request("job.advance", {"jobId": job["id"]}))
        self.assertEqual(rejected["error"]["code"], "invalid-job-state")
        self.call("job.resume", {"jobId": job["id"]})
        completed = self.call("job.advance", {"jobId": job["id"]})["result"]["job"]
        self.assertEqual(completed["status"], "completed")
        self.assertEqual(completed["summary"]["cellCount"], 2)
        self.assertEqual(completed["progress"], {"completed": 2, "total": 2})
        self.assertIsNone(completed["nextUnit"])
        self.assertEqual(self.call("job.get", {"jobId": job["id"]})["result"]["job"], completed)

    def test_job_blocked_by_same_count_correction_preserves_manual_work(self):
        image_id, result = self.analyzed()
        workflow = self.saved_workflow()
        job = self.call("job.create", {"workflowId": workflow["id"], "imageIds": [image_id]})["result"]["job"]
        first_label = min(result["cells"], key=lambda cell: cell["areaPx"])["labelId"]
        corrected = self.call("mask.edit", {"imageId": image_id, "action": "polygon", "labelId": first_label,
                             "polygon": [[1, 1], [3, 1], [3, 3], [1, 3]]})["result"]
        blocked = self.call("job.advance", {"jobId": job["id"]})["result"]["job"]
        self.assertEqual(blocked["status"], "blocked")
        self.assertEqual(blocked["error"]["code"], "stale-job-input")
        measured = self.call("measurements.get", {"imageId": image_id})["result"]
        self.assertEqual(measured["inputFingerprint"], corrected["inputFingerprint"])
        self.assertEqual(sum(cell["areaPx"] for cell in measured["cells"]), 16)
        rejected = dispatch(self.request("job.retry", {"jobId": job["id"]}))
        self.assertEqual(rejected["error"]["code"], "invalid-job-state")

    def test_completed_checkpoint_changes_block_summary_and_export(self):
        image_id = self.imported()
        workflow = self.saved_workflow(export=True)
        destination = self.root / "workflow.zip"
        job = self.call("job.create", {"workflowId": workflow["id"], "imageIds": [image_id],
                                      "exportDestination": str(destination)})["result"]["job"]
        self.call("job.advance", {"jobId": job["id"]})
        self.call("calibration.set", {"imageId": image_id, "pxPerUm": 4})
        blocked = self.call("job.advance", {"jobId": job["id"]})["result"]["job"]
        self.assertEqual(blocked["status"], "blocked")
        self.assertFalse(destination.exists())
        self.assertNotIn("summary", blocked)
        self.assertEqual(blocked["checkpoints"][0]["status"], "completed")

    def test_failed_job_can_retry_without_partial_analysis_or_repeating_checkpoints(self):
        from _workbench_schema import WorkbenchError
        image_id = self.imported()
        workflow = self.saved_workflow()
        job = self.call("job.create", {"workflowId": workflow["id"], "imageIds": [image_id]})["result"]["job"]
        with patch("_workbench_imaging.segment", side_effect=WorkbenchError("temporary-failure", "Try again")):
            failed = self.call("job.advance", {"jobId": job["id"]})["result"]["job"]
        self.assertEqual(failed["status"], "failed")
        self.assertEqual(failed["progress"]["completed"], 0)
        self.assertEqual(self.call("project.inspect")["result"]["images"][0]["status"], "imported")
        self.call("job.retry", {"jobId": job["id"]})
        result = self.call("job.advance", {"jobId": job["id"]})["result"]["job"]
        self.assertEqual(result["checkpoints"][0]["cellCount"], 2)
        cancelled = self.call("job.cancel", {"jobId": job["id"]})["result"]["job"]
        self.assertEqual(cancelled["status"], "cancelled")
        self.assertEqual(self.call("measurements.get", {"imageId": image_id})["result"]["cellCount"], 2)

    def test_job_async_calibration_conflict_never_commits_checkpoint(self):
        image_id = self.imported()
        workflow = self.saved_workflow()
        job = self.call("job.create", {"workflowId": workflow["id"], "imageIds": [image_id]})["result"]["job"]
        original_segment = imaging.segment
        request = self.request("job.advance", {"jobId": job["id"]})

        def racing_segment(plane, parameters, valid_support=None):
            self.call("calibration.set", {"imageId": image_id, "pxPerUm": 4})
            return original_segment(plane, parameters, valid_support)

        with patch("_workbench_imaging.segment", side_effect=racing_segment):
            response = dispatch(request)
        self.assertEqual(response["error"]["code"], "revision-conflict")
        persisted = self.call("job.get", {"jobId": job["id"]})["result"]["job"]
        self.assertEqual(persisted["status"], "pending")
        self.assertEqual(persisted["checkpoints"][0]["status"], "pending")
        image = self.call("project.inspect")["result"]["images"][0]
        self.assertEqual(image["pxPerUm"], 4)
        self.assertEqual(image["status"], "imported")

    def test_workflow_exports_are_complete_and_reusable_with_new_destination(self):
        use_legacy_storage(self.project)
        image_id = self.imported()
        workflow = self.saved_workflow(export=True)
        missing = dispatch(self.request("job.create", {"workflowId": workflow["id"], "imageIds": [image_id]}))
        self.assertEqual(missing["error"]["code"], "export-destination-required")
        for index in range(2):
            destination = self.root / f"workflow-{index}.zip"
            job = self.call("job.create", {"workflowId": workflow["id"], "imageIds": [image_id],
                                          "exportDestination": str(destination)})["result"]["job"]
            for _ in range(3):
                job = self.call("job.advance", {"jobId": job["id"]})["result"]["job"]
            self.assertEqual(job["status"], "completed")
            self.assertEqual(job["export"]["scope"], "complete-project")
            with zipfile.ZipFile(destination) as archive:
                self.assertEqual(json.loads(archive.read("summary.json"))["cellCount"], 2)
                self.assertIn("experiment-summary.json", archive.namelist())
                manifest = json.loads(archive.read("manifest.json"))
                for name, checksum in manifest["files"].items():
                    self.assertEqual(hashlib.sha256(archive.read(name)).hexdigest(), checksum)

    def test_workflow_rejects_unexecutable_step_order(self):
        response = dispatch(self.request("workflow.save", {"name": "Invalid",
            "steps": [{"type": "measurements"}, {"type": "analysis"}, {"type": "summary"}]}))
        self.assertEqual(response["error"]["code"], "invalid-workflow")
        self.assertEqual(self.call("workflow.list")["result"]["workflows"], [])

    def test_disconnected_merged_masks_and_holes_keep_all_display_boundaries(self):
        image_id, original = self.analyzed()
        merged = self.call("mask.edit", {"imageId": image_id, "action": "merge",
            "labelIds": [cell["labelId"] for cell in original["cells"]]})["result"]
        self.assertEqual(merged["cells"][0]["areaPx"], 18)
        self.assertEqual(len(merged["cells"][0]["contoursPx"]), 2)
        labels = np.ones((7, 7), dtype=np.uint32)
        labels[2:5, 2:5] = 0
        cell = imaging.measure(labels, np.ones((7, 7)), 1)[0]
        self.assertEqual(cell["areaPx"], 40)
        self.assertEqual(len(cell["contoursPx"]), 2)

    def test_minimum_object_area_applies_after_watershed_splitting(self):
        plane = np.zeros((64, 64), dtype=np.float64)
        plane[10:50, 10:40] = 200
        plane[35:45, 40:52] = 200
        labels, _ = imaging.segment(plane, {**self.parameters, "threshold": 100,
                                          "minAreaPx": 300, "minDistancePx": 3})
        cells = imaging.measure(labels, plane, None)
        self.assertTrue(cells)
        self.assertTrue(all(cell["areaPx"] >= 300 for cell in cells), cells)

    def test_completed_job_reads_mark_later_corrections_stale_without_erasing_history(self):
        image_id = self.imported()
        workflow = self.saved_workflow()
        job = self.call("job.create", {"workflowId": workflow["id"], "imageIds": [image_id]})["result"]["job"]
        self.call("job.advance", {"jobId": job["id"]})
        complete = self.call("job.advance", {"jobId": job["id"]})["result"]["job"]
        self.assertTrue(complete["outputsCurrent"])
        self.call("calibration.set", {"imageId": image_id, "pxPerUm": 4})
        historical = self.call("job.get", {"jobId": job["id"]})["result"]["job"]
        self.assertEqual(historical["status"], "completed")
        self.assertFalse(historical["outputsCurrent"])
        self.assertEqual(historical["staleImageIds"], [image_id])
        self.assertEqual(historical["summary"], complete["summary"])
        inspected = self.call("project.inspect")["result"]
        self.assertFalse(inspected["jobs"][0]["outputsCurrent"])
        self.assertEqual(inspected["workflows"], [workflow])

    def test_identical_pixels_from_distinct_acquisitions_remain_distinct_images(self):
        first = self.imported()
        second_path = self.root / "independent-control-well.png"
        second_path.write_bytes(self.source.read_bytes())
        second_import = self.call("image.import", {"paths": [str(second_path)]})["result"]
        second = second_import["importedImageIds"][0]
        self.assertNotEqual(first, second)
        images = ProjectStore(str(self.project)).read()["images"]
        self.assertEqual(images[0]["sourcePath"], images[1]["sourcePath"])
        self.assertNotEqual(images[0]["importedFrom"], images[1]["importedFrom"])
        repeated = self.call("image.import", {"paths": [str(second_path)]})["result"]
        self.assertEqual(repeated["importedImageIds"], [])
        self.assertEqual(repeated["duplicateImageIds"], [second])
        self.assertEqual(repeated["imageCount"], 2)
        self.assertEqual([image["id"] for image in repeated["images"]], [second])

    def crashed_export(self, request, after_publish=True):
        script = """
import json, os, sys
import _workbench_core as core
original = core._prepare_export
def interrupted(*args):
    result, publish, temporary = original(*args)
    def crash():
        if sys.argv[2] == 'after':
            publish()
        os._exit(99)
    return result, crash, temporary
core._prepare_export = interrupted
core.dispatch(json.loads(sys.argv[1]))
"""
        completed = subprocess.run([sys.executable, "-c", script, json.dumps(request),
                                    "after" if after_publish else "before"],
                                   env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[1])},
                                   capture_output=True, timeout=30)
        self.assertEqual(completed.returncode, 99, completed.stderr)

    def test_export_recovers_exact_response_after_process_exit_between_publish_and_commit(self):
        destination = self.root / "recovered.zip"
        request = self.request("project.export", {"destination": str(destination)})
        self.crashed_export(request)
        self.assertTrue(destination.is_file())
        saved_bytes = destination.read_bytes()
        # A read performs recovery, so every GUI sees the committed export revision.
        inspected = dispatch(self.request("project.inspect", expectedRevision=None))
        self.assertTrue(inspected["ok"], inspected)
        self.assertEqual(inspected["revision"], self.revision + 1)
        recovered = dispatch(request)
        self.assertTrue(recovered["ok"], recovered)
        self.assertEqual(recovered["revision"], inspected["revision"])
        self.assertEqual(recovered["result"]["sourceRevision"], self.revision)
        self.assertEqual(destination.read_bytes(), saved_bytes)
        self.assertEqual(dispatch(request), recovered)
        self.assertFalse((self.project / ".pending-publication.json").exists())

    def test_export_recovery_never_accepts_an_unrelated_destination(self):
        destination = self.root / "changed.zip"
        request = self.request("project.export", {"destination": str(destination)})
        self.crashed_export(request)
        destination.write_bytes(b"unrelated content")
        response = dispatch(request)
        self.assertEqual(response["error"]["code"], "publication-conflict")
        self.assertEqual(destination.read_bytes(), b"unrelated content")
        self.assertTrue((self.project / ".pending-publication.json").exists())

    def test_export_interruption_before_publication_is_safe_to_retry(self):
        destination = self.root / "before.zip"
        request = self.request("project.export", {"destination": str(destination)})
        self.crashed_export(request, after_publish=False)
        self.assertFalse(destination.exists())
        recovered = dispatch(request)
        self.assertTrue(recovered["ok"], recovered)
        self.assertEqual(recovered["revision"], self.revision + 1)
        self.assertTrue(destination.is_file())

    def test_export_hashes_bytes_actually_written_and_rejects_mid_copy_changes(self):
        use_legacy_storage(self.project)
        self.analyzed()
        image = ProjectStore(str(self.project)).read()["images"][0]
        destination = self.root / "racing.zip"
        original_open = zipfile.ZipFile.open

        def racing_open(archive, name, mode="r", *args, **kwargs):
            if mode == "w" and name == image["sourcePath"]:
                (self.project / image["sourcePath"]).write_bytes(b"changed during export")
            return original_open(archive, name, mode, *args, **kwargs)

        with patch("zipfile.ZipFile.open", new=racing_open):
            result = dispatch(self.request("project.export", {"destination": str(destination)}))
        self.assertEqual(result["error"]["code"], "artifact-changed")
        self.assertFalse(destination.exists())

    def test_export_rollback_never_deletes_a_replacement_destination(self):
        from _workbench_core import _prepare_export
        store = ProjectStore(str(self.project))
        destination = self.root / "replaced.zip"
        _, publish, temporary = _prepare_export(
            store, store.read(), self.request("project.export", {"destination": str(destination)}))
        try:
            cleanup = publish()
            replacement = self.root / "other.zip"
            replacement.write_bytes(b"unrelated replacement")
            replacement.replace(destination)
            cleanup()
            self.assertEqual(destination.read_bytes(), b"unrelated replacement")
        finally:
            temporary.unlink(missing_ok=True)

    def test_export_recovery_rejects_changed_intent_and_destination_symlink(self):
        destination = self.root / "intent.zip"
        request = self.request("project.export", {"destination": str(destination)})
        self.crashed_export(request)
        intent_path = self.project / ".pending-publication.json"
        original = intent_path.read_bytes()
        intent = json.loads(original)
        intent["delta"]["header"]["name"] = "Unexpected change"
        intent_path.write_text(json.dumps(intent), encoding="utf-8")
        result = dispatch(request)
        self.assertEqual(result["error"]["code"], "project-corrupt")
        intent_path.write_bytes(original)
        renamed = self.root / "renamed.zip"
        destination.rename(renamed)
        destination.symlink_to(renamed)
        result = dispatch(request)
        self.assertEqual(result["error"]["code"], "publication-conflict")
        self.assertTrue(destination.is_symlink())

    def test_exported_job_currentness_includes_the_complete_project_and_design(self):
        image_id = self.imported()
        workflow = self.saved_workflow(export=True)
        job = self.call("job.create", {"workflowId": workflow["id"], "imageIds": [image_id],
            "exportDestination": str(self.root / "complete-project.zip")})["result"]["job"]
        for _ in range(3):
            job = self.call("job.advance", {"jobId": job["id"]})["result"]["job"]
        self.assertTrue(job["outputsCurrent"])
        self.call("specimen.set", {"name": "Specimen", "experiment": "Experiment",
                                  "condition": "Control", "role": "control"})
        historical = self.call("job.get", {"jobId": job["id"]})["result"]["job"]
        self.assertEqual(historical["status"], "completed")
        self.assertFalse(historical["outputsCurrent"])
        self.assertFalse(historical["exportInputsCurrent"])
        self.assertEqual(historical["staleImageIds"], [])


class WorkbenchValidationTests(unittest.TestCase):
    def test_error_envelope_and_finite_parameter_validation(self):
        for request in (None, {}, {"schemaVersion": 2}):
            response = dispatch(request)
            self.assertFalse(response["ok"])
            self.assertEqual(response["schemaVersion"], 1)
            self.assertIn("code", response["error"])
        response = dispatch({"schemaVersion": 1, "operation": "analysis.run", "requestId": "bad",
                             "projectPath": "/tmp/not-a-project", "expectedRevision": 0,
                             "arguments": {"imageId": "image", "parameters": {"threshold": float("nan")}}})
        self.assertEqual(response["error"]["code"], "invalid-arguments")

    def test_capabilities_do_not_require_project(self):
        response = dispatch({"schemaVersion": 1, "operation": "capabilities", "requestId": "caps", "arguments": {}})
        self.assertTrue(response["ok"], response)
        operations = response["result"]["operations"]
        self.assertIn("mask.edit", [entry["name"] for entry in operations])
        self.assertTrue(all("inputSchema" in entry and "mutating" in entry for entry in operations))


if __name__ == "__main__":
    unittest.main()
