"""Scientific 3D/time tests: raw values, exact voxels and shared dependency state."""
from __future__ import annotations

import base64
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid
import zipfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _fixtures import use_legacy_storage
from _workbench_core import dispatch
from _workbench_store import ProjectStore

try:
    import numpy as np
    import tifffile
    from PIL import Image
    import scipy
    import skimage
    SCIENCE = True
except ImportError:
    SCIENCE = False


@unittest.skipUnless(SCIENCE, "Install shared/python/requirements-analysis.txt")
class VolumeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "Project"
        self.revision = 0
        self.call("project.create", {"name": "Volume experiment"})
        self.raw = np.zeros((2, 2, 6, 12, 14), np.uint16)
        self.raw[0, 0, 1:3, 1:4, 2:6] = 100
        self.raw[1, 0, 1:3, 1:4, 3:7] = 100
        self.raw[:, 1, 2:5, 6:9, 8:11] = 4000
        path = self.root / "volume.ome.tif"
        tifffile.imwrite(path, self.raw, ome=True, photometric="minisblack", metadata={
            "axes": "TCZYX", "PhysicalSizeX": .5, "PhysicalSizeY": .25, "PhysicalSizeZ": 2,
            "PhysicalSizeXUnit": "µm", "PhysicalSizeYUnit": "µm", "PhysicalSizeZUnit": "µm",
            "TimeIncrement": 30, "TimeIncrementUnit": "s",
        })
        self.image_id = self.call("image.import", {"paths": [str(path)]})["result"]["importedImageIds"][0]
        self.params = {"method": "manual", "threshold": 50, "polarity": "bright",
                       "minVolumeVox": 1, "minDistanceVox": 100}

    def request(self, operation, args=None, **extra):
        request = {"schemaVersion": 1, "operation": operation, "requestId": str(uuid.uuid4()),
                   "projectPath": str(self.project), "arguments": args or {},
                   "actor": {"kind": "test", "name": "3D science tests"}}
        if operation != "project.create":
            request["expectedRevision"] = self.revision
        return {**request, **extra}

    def call(self, operation, args=None, **extra):
        response = dispatch(self.request(operation, args, **extra))
        self.assertTrue(response["ok"], response)
        self.revision = response.get("revision", self.revision)
        return response

    def args(self, time=0, channel=0, **extra):
        return {"imageId": self.image_id, "timeIndex": time, "channel": channel, **extra}

    def analyze(self, time=0, channel=0):
        return self.call("volume.analysis.run", self.args(time, channel, parameters=self.params))["result"]

    def test_anisotropic_ome_metadata_and_exact_3d_time_channel_measurements(self):
        info = self.call("volume.inspect", {"imageId": self.image_id})["result"]
        self.assertEqual(info["dimensions"], [14, 12, 6])
        self.assertEqual(info["timeCount"], 2)
        self.assertEqual(info["voxelSizeUm"], {"x": .5, "y": .25, "z": 2})
        self.assertEqual(info["timeStepSeconds"], 30)
        result = self.analyze()
        self.assertEqual(result["cellCount"], 1)
        cell = result["cells"][0]
        self.assertEqual(cell["voxelCount"], 24)
        self.assertEqual(cell["volumeUm3"], 6)
        self.assertEqual(cell["meanIntensity"], 100)
        self.assertEqual([cell["cx"], cell["cy"], cell["cz"]], [4, 2.5, 2])
        self.assertEqual(cell["centroidUm"], {"x": 2, "y": .625, "z": 4})
        self.assertEqual(cell["bbox"], {"min": [2, 1, 1], "max": [6, 4, 3]})
        later = self.analyze(time=1)["cells"][0]
        other = self.analyze(channel=1)["cells"][0]
        self.assertEqual(later["cx"], 5)
        self.assertEqual(other["voxelCount"], 27)
        self.assertEqual(other["meanIntensity"], 4000)
        frame = ProjectStore(str(self.project)).read()["images"][0]["volumeFrames"][0]
        labels = np.load(self.project / frame["labelsPath"], allow_pickle=False)
        self.assertEqual(labels.shape, (6, 12, 14))
        self.assertEqual(labels.dtype, np.uint32)
        self.assertEqual(np.count_nonzero(labels), 24)

    def test_preview_display_coordinates_labels_and_no_persistence(self):
        before = self.revision
        preview = self.call("volume.analysis.preview", self.args(parameters=self.params))["result"]
        self.assertEqual(self.revision, before)
        self.assertEqual(self.call("volume.inspect", {"imageId": self.image_id})["result"]["frames"], [])
        descriptor = preview["display"]
        self.assertEqual(descriptor["dimensions"], [14, 12, 6])
        self.assertEqual(descriptor["transform"], {"scale": [1, 1, 1], "offset": [0, 0, 0]})
        raw = np.frombuffer(base64.b64decode(descriptor["dataBase64"]), np.uint8).reshape(6, 12, 14)
        labels = np.frombuffer(base64.b64decode(descriptor["labelDataBase64"]), "<u4").reshape(6, 12, 14)
        self.assertEqual(raw[1, 1, 2], 255)
        self.assertEqual(np.count_nonzero(labels), 24)
        self.analyze()
        small = self.call("volume.display", self.args(maxDimension=8))["result"]
        self.assertEqual(small["dimensions"], [8, 6, 3])
        self.assertEqual(small["transform"], {"scale": [1.75, 2, 2], "offset": [.375, .5, .5]})
        sampled = np.frombuffer(base64.b64decode(small["labelDataBase64"]), "<u4").reshape(3, 6, 8)
        axes = [np.floor(np.arange(n) * scale + offset + .5).astype(int)
                for n, scale, offset in zip(small["dimensions"], small["transform"]["scale"], small["transform"]["offset"])]
        expected = labels[np.ix_(axes[2], axes[1], axes[0])]
        np.testing.assert_array_equal(sampled, expected)
        self.assertEqual(self.call("volume.measurements.get", self.args())["result"]["cells"][0]["voxelCount"], 24)

    def test_slices_use_full_resolution_axis_order_and_preserve_labels(self):
        self.analyze()
        expected = {"xy": (1, [14, 12]), "xz": (1, [14, 6]), "yz": (2, [12, 6])}
        for plane, (index, dimensions) in expected.items():
            value = self.call("volume.slice", self.args(plane=plane, index=index))["result"]
            self.assertEqual([value["width"], value["height"]], dimensions)
            pixels = Image.open(io.BytesIO(base64.b64decode(value["dataUrl"].split(",", 1)[1])))
            self.assertEqual(list(pixels.size), dimensions)
            self.assertEqual(value["contours"][0]["labelId"], 1)

    def test_slice_edit_brush_undo_and_calibration_use_authoritative_voxels(self):
        initial = self.analyze()
        label = initial["cells"][0]["labelId"]
        corrected = self.call("volume.mask.edit", self.args(
            action="polygon", plane="xy", index=1, labelId=label,
            polygon=[[2, 1], [4, 1], [4, 3], [2, 3]]))["result"]
        self.assertEqual(corrected["cells"][0]["voxelCount"], 16)
        self.call("volume.calibration.set", {"imageId": self.image_id, "voxelSizeUm": {"z": 4}})
        undone = self.call("volume.mask.undo", self.args())["result"]
        self.assertEqual(undone["cells"][0]["voxelCount"], 24)
        self.assertEqual(undone["cells"][0]["volumeUm3"], 12)
        brushed = self.call("volume.mask.edit", self.args(action="brush", center=[.5, .5, .5], radiusVox=.75))["result"]
        self.assertEqual(sorted(cell["voxelCount"] for cell in brushed["cells"]), [1, 24])
        self.call("volume.calibration.set", {"imageId": self.image_id, "voxelSizeUm": {"z": None},
                                            "timeStepSeconds": None})
        unknown = self.call("volume.measurements.get", self.args())["result"]
        self.assertTrue(all(cell["volumeUm3"] is None for cell in unknown["cells"]))
        self.assertIsNone(self.call("volume.inspect", {"imageId": self.image_id})["result"]["timeStepSeconds"])

    def test_tracks_are_bounded_one_to_one_editable_and_stale_after_geometry_change(self):
        first = self.analyze()
        self.analyze(time=1)
        args = {"imageId": self.image_id, "channel": 0, "maxDistance": 2, "units": "voxel"}
        tracks = self.call("tracks.run", args)["result"]
        self.assertEqual(tracks["status"], "current")
        self.assertEqual(len(tracks["tracks"]), 1)
        self.assertEqual(len(tracks["tracks"][0]["observations"]), 2)
        self.assertEqual(tracks["edges"][0]["distance"], 1)
        link = {"imageId": self.image_id, "channel": 0, "sourceTimeIndex": 0, "sourceLabelId": 1,
                "targetTimeIndex": 1, "targetLabelId": 1}
        self.assertEqual(len(self.call("tracks.unlink", link)["result"]["tracks"]), 2)
        self.assertEqual(self.call("tracks.link", link)["result"]["edges"][0]["origin"], "manual")
        self.call("volume.mask.edit", self.args(action="delete", labelIds=[first["cells"][0]["labelId"]]))
        self.assertEqual(self.call("tracks.get", {"imageId": self.image_id, "channel": 0})["result"]["status"], "stale")
        refused = dispatch(self.request("tracks.link", link))
        self.assertFalse(refused["ok"])

    def test_volume_workflows_checkpoint_each_time_and_export_full_resolution(self):
        use_legacy_storage(self.project)
        workflow = self.call("workflow.save", {"name": "3D time course", "steps": [
            {"type": "volume-analysis", "parameters": self.params, "channel": 0},
            {"type": "measurements"}, {"type": "summary"}, {"type": "export"}]})["result"]["workflow"]
        destination = self.root / "volume.zip"
        job = self.call("job.create", {"workflowId": workflow["id"], "imageIds": [self.image_id],
                                      "exportDestination": str(destination)})["result"]["job"]
        self.assertEqual(job["nextUnit"], {"type": "volume", "imageId": self.image_id, "timeIndex": 0, "channel": 0, "stepIndex": 0})
        self.assertEqual(job["progress"]["total"], 4)
        request = self.request("job.advance", {"jobId": job["id"]})
        first = dispatch(request)
        self.assertTrue(first["ok"], first)
        self.revision = first["revision"]
        self.assertEqual(dispatch(request), first)
        for _ in range(3):
            job = self.call("job.advance", {"jobId": job["id"]})["result"]["job"]
        self.assertEqual(job["status"], "completed")
        self.assertTrue(job["outputsCurrent"])
        self.assertEqual(job["summary"]["frameCount"], 2)
        self.assertEqual(job["summary"]["dimension"], 3)
        self.assertEqual(job["summary"]["cellCount"], 2)
        with zipfile.ZipFile(destination) as archive:
            project = json.loads(archive.read("project.json"))
            frames = project["images"][0]["volumeFrames"]
            self.assertEqual(len(frames), 2)
            for frame in frames:
                labels = np.load(io.BytesIO(archive.read(frame["labelsPath"])), allow_pickle=False)
                self.assertEqual(labels.shape, (6, 12, 14))
                self.assertEqual(np.count_nonzero(labels), 24)
            self.assertIn("volume-measurements.csv", archive.namelist())
            self.assertEqual(json.loads(archive.read("volume-summary.json"))["frameCount"], 2)
        self.call("volume.calibration.set", {"imageId": self.image_id, "voxelSizeUm": {"z": 1}})
        self.assertFalse(self.call("job.get", {"jobId": job["id"]})["result"]["job"]["outputsCurrent"])

    def test_stale_volume_computation_cannot_replace_calibration(self):
        import _workbench_volume as volume
        original = volume.segment
        request = self.request("volume.analysis.run", self.args(parameters=self.params))

        def race(raw, parameters, valid_support=None):
            self.call("volume.calibration.set", {"imageId": self.image_id, "voxelSizeUm": {"z": 1}})
            return original(raw, parameters, valid_support)

        with patch("_workbench_volume.segment", side_effect=race):
            response = dispatch(request)
        self.assertEqual(response["error"]["code"], "revision-conflict")
        info = self.call("volume.inspect", {"imageId": self.image_id})["result"]
        self.assertEqual(info["frames"], [])
        self.assertEqual(info["voxelSizeUm"]["z"], 1)

    def test_anisotropic_xy_calibration_updates_existing_2d_measurements(self):
        path = self.root / "plane.png"
        values = np.zeros((8, 8), np.uint8)
        values[1:3, 2:5] = 100
        Image.fromarray(values).save(path)
        image = self.call("image.import", {"paths": [str(path)]})["result"]["importedImageIds"][0]
        params = {"method": "manual", "threshold": 50, "minAreaPx": 1, "minDistancePx": 100}
        self.call("analysis.run", {"imageId": image, "parameters": params})
        self.call("volume.calibration.set", {"imageId": image, "voxelSizeUm": {"x": .5, "y": .25, "z": 2}})
        result = self.call("measurements.get", {"imageId": image})["result"]
        self.assertIsNone(result["pxPerUm"])
        self.assertTrue(result["calibrated"])
        self.assertEqual(result["cells"][0]["areaUm2"], .75)
        summary = self.call("summary.get")["result"]
        self.assertEqual(next(row for row in summary["images"] if row["imageId"] == image)["totalAreaUm2"], .75)
        self.call("volume.calibration.set", {"imageId": image, "voxelSizeUm": {"x": None}})
        self.assertIsNone(self.call("measurements.get", {"imageId": image})["result"]["cells"][0]["areaUm2"])

    def test_gap_tracking_spans_an_empty_time_point_only_with_explicit_gap_allowance(self):
        source = np.zeros((3, 4, 8, 9), np.uint8)
        source[0, 1:3, 2:4, 2:4] = 100
        source[2, 1:3, 2:4, 3:5] = 100
        path = self.root / "gap.tif"
        tifffile.imwrite(path, source, photometric="minisblack", metadata={"axes": "TZYX"})
        image = self.call("image.import", {"paths": [str(path)]})["result"]["importedImageIds"][0]
        for time in range(3):
            self.call("volume.analysis.run", {"imageId": image, "timeIndex": time,
                                              "channel": 0, "parameters": self.params})
        args = {"imageId": image, "channel": 0, "maxDistance": 2, "units": "voxel"}
        self.assertEqual(self.call("tracks.run", args)["result"]["edges"], [])
        tracked = self.call("tracks.run", {**args, "maxGapFrames": 1})["result"]
        self.assertEqual(len(tracked["edges"]), 1)
        self.assertEqual(tracked["edges"][0]["sourceTimeIndex"], 0)
        self.assertEqual(tracked["edges"][0]["targetTimeIndex"], 2)

    def test_explicit_single_z_time_series_and_volume_limit_before_decode(self):
        path = self.root / "time-planes.tif"
        source = np.zeros((2, 8, 9), np.uint8)
        source[:, 2:4, 2:4] = 100
        tifffile.imwrite(path, source, photometric="minisblack", metadata={"axes": "TYX"})
        image = self.call("image.import", {"paths": [str(path)]})["result"]["importedImageIds"][0]
        result = self.call("volume.analysis.run", {"imageId": image, "timeIndex": 1,
                                                  "channel": 0, "parameters": self.params})["result"]
        self.assertEqual(result["dimensions"], [9, 8, 1])
        self.assertEqual(result["cells"][0]["voxelCount"], 4)
        self.assertIsNone(result["cells"][0]["volumeUm3"])
        import _workbench_volume as volume
        with patch.object(volume, "MAX_VOLUME_VOXELS", 10), patch.object(volume.imaging, "load_array") as reader:
            rejected = dispatch(self.request("volume.analysis.run", self.args(parameters=self.params)))
        self.assertEqual(rejected["error"]["code"], "volume-too-large")
        reader.assert_not_called()

    def test_volume_workflow_never_overwrites_a_corrected_completed_frame_on_resume(self):
        workflow = self.call("workflow.save", {"name": "Frames", "steps": [
            {"type": "volume-analysis", "parameters": self.params, "channel": 0},
            {"type": "measurements"}, {"type": "summary"}]})["result"]["workflow"]
        job = self.call("job.create", {"workflowId": workflow["id"],
                                      "imageIds": [self.image_id]})["result"]["job"]
        self.call("job.advance", {"jobId": job["id"]})
        corrected = self.call("volume.mask.edit", self.args(action="delete", labelIds=[1]))["result"]
        blocked = self.call("job.advance", {"jobId": job["id"]})["result"]["job"]
        self.assertEqual(blocked["status"], "blocked")
        self.assertEqual(blocked["error"]["code"], "stale-job-input")
        measured = self.call("volume.measurements.get", self.args())["result"]
        self.assertEqual(measured["inputFingerprint"], corrected["inputFingerprint"])
        self.assertEqual(measured["cellCount"], 0)


if __name__ == "__main__":
    unittest.main()
