"""Exercise real CLI and MCP processes against one scientific project."""
from __future__ import annotations

import asyncio
import csv
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


RUNTIME = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RUNTIME))
from _fixtures import use_legacy_storage
DEPENDENCIES = ("numpy", "scipy", "PIL", "skimage", "tifffile", "mcp")
AVAILABLE = all(importlib.util.find_spec(name) is not None for name in DEPENDENCIES)


@unittest.skipUnless(AVAILABLE, "Install requirements-analysis.txt and requirements-mcp.txt")
class WorkbenchIntegrationTests(unittest.TestCase):
    def cli(self, request):
        process = subprocess.run(
            [sys.executable, str(RUNTIME / "workbench.py"), "request", "--stdin"],
            input=json.dumps(request), text=True, capture_output=True, timeout=60,
        )
        response = json.loads(process.stdout)
        self.assertEqual(process.returncode, 0 if response["ok"] else 1, process.stderr)
        self.assertTrue(response["ok"], response)
        if request["operation"] == "project.create": use_legacy_storage(request["projectPath"])
        return response

    def test_mcp_resumable_workflow_enforces_saved_export_scope(self):
        import numpy as np
        import tifffile
        from mcp import Client
        from mcp.client.stdio import StdioServerParameters

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            project = root / "Workflow.ccproject"
            source = root / "workflow-input.tif"
            destination = root / "workflow-output.zip"
            pixels = np.zeros((64, 80), dtype=np.uint16)
            yy, xx = np.indices(pixels.shape)
            pixels[(xx - 20) ** 2 + (yy - 20) ** 2 <= 8 ** 2] = 12000
            pixels[(xx - 60) ** 2 + (yy - 44) ** 2 <= 8 ** 2] = 24000
            tifffile.imwrite(source, pixels, metadata={"axes": "YX"})
            revision = 0
            sequence = 0

            def cli_operation(operation, arguments):
                nonlocal revision, sequence
                sequence += 1
                request = {
                    "schemaVersion": 1, "operation": operation,
                    "requestId": "workflow-setup-" + str(sequence),
                    "projectPath": str(project), "arguments": arguments,
                    "actor": {"kind": "cli", "name": "Workflow integration test"},
                }
                if operation != "project.create":
                    request["expectedRevision"] = revision
                response = self.cli(request)
                revision = response["revision"]
                return response["result"]

            cli_operation("project.create", {"name": "Workflow"})
            image_id = cli_operation("image.import", {"paths": [str(source)]})["importedImageIds"][0]
            workflow = cli_operation("workflow.save", {
                "name": "Count and export",
                "steps": [
                    {"type": "analysis", "parameters": {"method": "manual", "threshold": 5000,
                                                        "minDistancePx": 12}},
                    {"type": "measurements"}, {"type": "summary"},
                    {"type": "export", "destination": str(destination)},
                ],
            })["workflow"]
            job = cli_operation("job.create", {
                "workflowId": workflow["id"], "imageIds": [image_id],
            })["job"]
            self.assertEqual(revision, 3)
            job_id = job["id"]

            def server(allow_destination=False):
                args = [str(RUNTIME / "workbench.py"), "mcp",
                        "--project", str(project), "--allow-write"]
                if allow_destination:
                    args += ["--allow-path", str(destination)]
                return StdioServerParameters(command=sys.executable, args=args)

            async def execute():
                nonlocal revision
                first = {"requestId": "advance-first", "expectedRevision": revision,
                         "arguments": {"jobId": job_id}}
                async with Client(server()) as client:
                    denied = await client.call_tool("job_advance", first)
                    self.assertTrue(denied.is_error)
                    self.assertEqual(denied.structured_content["error"]["code"], "permission_denied")
                    inspected = await client.call_tool("job_get", {"arguments": {"jobId": job_id}})
                    self.assertEqual(inspected.structured_content["revision"], revision)
                    self.assertEqual(inspected.structured_content["result"]["job"]["status"], "pending")

                async with Client(server(True)) as client:
                    advanced = await client.call_tool("job_advance", first)
                    self.assertFalse(advanced.is_error, advanced)
                    revision = advanced.structured_content["revision"]
                    self.assertEqual(advanced.structured_content["result"]["job"]["progress"]["completed"], 1)
                    replay = await client.call_tool("job_advance", first)
                    self.assertEqual(replay.structured_content, advanced.structured_content)
                    paused = await client.call_tool("job_pause", {
                        "requestId": "pause", "expectedRevision": revision, "arguments": {"jobId": job_id},
                    })
                    self.assertFalse(paused.is_error, paused)
                    revision = paused.structured_content["revision"]
                    self.assertEqual(paused.structured_content["result"]["job"]["status"], "paused")

                # A fresh server process must see the completed image checkpoint
                # and resume finalization without repeating segmentation.
                async with Client(server(True)) as client:
                    inspected = await client.call_tool("job_get", {"arguments": {"jobId": job_id}})
                    persisted = inspected.structured_content["result"]["job"]
                    self.assertEqual(persisted["status"], "paused")
                    self.assertEqual(persisted["progress"]["completed"], 1)
                    self.assertEqual(persisted["nextUnit"]["type"], "summary")
                    resumed = await client.call_tool("job_resume", {
                        "requestId": "resume", "expectedRevision": revision, "arguments": {"jobId": job_id},
                    })
                    self.assertFalse(resumed.is_error, resumed)
                    revision = resumed.structured_content["revision"]
                    for unit in ("summary", "export"):
                        advanced = await client.call_tool("job_advance", {
                            "requestId": "advance-" + unit, "expectedRevision": revision,
                            "arguments": {"jobId": job_id},
                        })
                        self.assertFalse(advanced.is_error, advanced)
                        revision = advanced.structured_content["revision"]
                        job_result = advanced.structured_content["result"]["job"]
                    self.assertEqual(job_result["status"], "completed")
                    self.assertEqual(job_result["progress"], {"completed": 3, "total": 3})
                    measured = await client.call_tool("measurements_get", {"arguments": {"imageId": image_id}})
                    self.assertEqual(measured.structured_content["result"]["cellCount"], 2)

            asyncio.run(execute())
            self.assertTrue(destination.is_file())
            with zipfile.ZipFile(destination) as archive:
                self.assertEqual(json.loads(archive.read("summary.json"))["cellCount"], 2)
                rows = list(csv.DictReader(io.StringIO(archive.read("measurements.csv").decode("utf-8"))))
                self.assertEqual(len(rows), 2)

    def test_import_cli_analysis_mcp_correction_and_export_agree(self):
        import numpy as np
        import tifffile
        from _workbench_core import dispatch

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            project = root / "Round trip.ccproject"
            source = root / "raw-16-bit.tif"
            pixels = np.full((96, 128), 1000, dtype=np.uint16)
            yy, xx = np.indices(pixels.shape)
            objects = ((24, 24, 10000), (64, 48, 20000), (104, 72, 30000))
            object_area = None
            for x, y, intensity in objects:
                disk = (xx - x) ** 2 + (yy - y) ** 2 <= 8 ** 2
                pixels[disk] = intensity
                object_area = int(disk.sum())
            tifffile.imwrite(source, pixels, metadata={"axes": "YX"})

            def request(operation, arguments=None, revision=None, identity=None):
                result = {
                    "schemaVersion": 1, "operation": operation,
                    "requestId": identity or operation,
                    "projectPath": str(project),
                    "actor": {"kind": "cli", "name": "Integration test"},
                    "arguments": arguments or {},
                }
                if revision is not None:
                    result["expectedRevision"] = revision
                return result

            created = self.cli(request("project.create", {"name": "Round trip"}))
            self.assertEqual(created["revision"], 0)
            imported = self.cli(request(
                "image.import", {"paths": [str(source)], "pxPerUm": 2}, 0,
            ))
            image_id = imported["result"]["importedImageIds"][0]
            self.assertEqual(imported["revision"], 1)
            parameters = {
                "method": "manual", "threshold": 5000, "polarity": "bright",
                "minAreaPx": 20, "minDistancePx": 12, "channel": 0, "zProjection": "max",
            }
            preview = self.cli(request(
                "analysis.preview", {"imageId": image_id, "parameters": parameters},
            ))
            self.assertEqual(preview["revision"], 1)
            self.assertEqual(preview["result"]["cellCount"], 3)
            self.assertTrue(preview["result"]["dataUrl"].startswith("data:image/png;base64,"))
            self.assertTrue(preview["result"]["overlayDataUrl"].startswith("data:image/png;base64,"))
            self.assertEqual(dispatch(request("project.inspect"))["result"]["images"][0]["status"], "imported")
            analyzed = self.cli(request(
                "analysis.run", {"imageId": image_id, "parameters": parameters}, 1,
            ))
            self.assertEqual(analyzed["revision"], 2)
            self.assertEqual(analyzed["result"]["cellCount"], 3)
            self.assertEqual(
                sorted(cell["meanIntensity"] for cell in analyzed["result"]["cells"]),
                [10000, 20000, 30000],
            )
            for cell in analyzed["result"]["cells"]:
                self.assertEqual(cell["areaPx"], object_area)
                self.assertEqual(cell["areaUm2"], object_area / 4)
            removed_label = analyzed["result"]["cells"][0]["labelId"]

            # The actual SDK negotiates and calls a separate stdio server process.
            # The second exact call must replay before checking its old revision.
            async def edit_over_mcp():
                from mcp import Client
                from mcp.client.stdio import StdioServerParameters

                server = StdioServerParameters(
                    command=sys.executable,
                    args=[str(RUNTIME / "workbench.py"), "mcp",
                          "--project", str(project), "--allow-write"],
                )
                async with Client(server) as client:
                    tool_names, cursor = set(), None
                    while True:
                        page = await client.list_tools(cursor=cursor)
                        tool_names.update(tool.name for tool in page.tools)
                        cursor = page.next_cursor
                        if cursor is None: break
                    self.assertIn("mask_edit", tool_names)
                    payload = {
                        "requestId": "mcp-delete-one", "expectedRevision": 2,
                        "arguments": {"imageId": image_id, "action": "delete",
                                      "labelIds": [removed_label]},
                    }
                    edited = await client.call_tool("mask_edit", payload)
                    self.assertFalse(edited.is_error, edited)
                    self.assertEqual(edited.structured_content["revision"], 3)
                    self.assertEqual(edited.structured_content["result"]["cellCount"], 2)
                    replay = await client.call_tool("mask_edit", payload)
                    self.assertEqual(replay.structured_content, edited.structured_content)
                    return edited.structured_content

            edited = asyncio.run(edit_over_mcp())
            snapshot = dispatch(request("project.inspect"))
            self.assertTrue(snapshot["ok"], snapshot)
            self.assertEqual(snapshot["revision"], 3)
            self.assertEqual(snapshot["result"]["images"][0]["cellCount"], 2)
            self.assertEqual(
                sum(entry["requestId"] == "mcp-delete-one" for entry in snapshot["result"]["history"]), 1,
            )
            measured = dispatch(request("measurements.get", {"imageId": image_id}))
            self.assertEqual(measured["result"]["cells"], edited["result"]["cells"])

            stale_gui = request(
                "calibration.set", {"imageId": image_id, "pxPerUm": 3}, 2, "stale-gui",
            )
            stale_gui["actor"] = {"kind": "human", "name": "Graphical workbench"}
            rejected = dispatch(stale_gui)
            self.assertFalse(rejected["ok"], rejected)
            self.assertEqual(rejected["error"]["code"], "revision-conflict")
            self.assertEqual(dispatch(request("project.inspect"))["revision"], 3)

            calibrated = self.cli(request(
                "calibration.set", {"imageId": image_id, "pxPerUm": 4}, 3,
            ))
            self.assertEqual(calibrated["revision"], 4)
            self.assertEqual(calibrated["result"]["analysisRevision"], 3)
            self.assertEqual(calibrated["result"]["measurementRevision"], 4)
            for cell in calibrated["result"]["cells"]:
                self.assertEqual(cell["areaPx"], object_area)
                self.assertEqual(cell["areaUm2"], object_area / 16)
            summary = dispatch(request("summary.get"))
            self.assertEqual(summary["result"]["cellCount"], 2)
            self.assertEqual(summary["result"]["images"][0]["totalAreaUm2"], 2 * object_area / 16)

            destination = root / "analysis.zip"
            exported = self.cli(request("project.export", {"destination": str(destination)}, 4))
            self.assertEqual(exported["revision"], 5)
            self.assertEqual(exported["result"]["sourceRevision"], 4)
            self.assertEqual(
                exported["result"]["sha256"], hashlib.sha256(destination.read_bytes()).hexdigest(),
            )
            with zipfile.ZipFile(destination) as archive:
                document = json.loads(archive.read("project.json"))
                export_summary = json.loads(archive.read("summary.json"))
                provenance = json.loads(archive.read("provenance.json"))
                manifest = json.loads(archive.read("manifest.json"))
                for name, digest in manifest["files"].items():
                    self.assertEqual(hashlib.sha256(archive.read(name)).hexdigest(), digest, name)
                image = document["images"][0]
                self.assertEqual(archive.read(image["sourcePath"]), source.read_bytes())
                labels = np.load(io.BytesIO(archive.read(image["analysis"]["labelsPath"])), allow_pickle=False)
                label_ids = set(int(value) for value in np.unique(labels)) - {0}
                self.assertEqual(len(label_ids), 2)
                self.assertNotIn(removed_label, label_ids)
                rows = list(csv.DictReader(io.StringIO(archive.read("measurements.csv").decode("utf-8"))))
                self.assertEqual(len(rows), 2)
                self.assertEqual({int(row["label_id"]) for row in rows}, label_ids)
                for row in rows:
                    self.assertEqual(int(row["area_px"]), int((labels == int(row["label_id"])).sum()))
                    self.assertEqual(float(row["area_um2"]), object_area / 16)
                    self.assertGreater(float(row["mean_intensity_raw"]), 255)
                self.assertEqual(export_summary, summary["result"])
                self.assertEqual(provenance["sourceRevision"], 4)
                self.assertEqual(document["revision"], 4)

            async def inspect_read_only():
                from mcp import Client
                from mcp.client.stdio import StdioServerParameters

                server = StdioServerParameters(
                    command=sys.executable,
                    args=[str(RUNTIME / "workbench.py"), "mcp", "--project", str(project)],
                )
                async with Client(server) as client:
                    names, cursor = set(), None
                    while True:
                        page = await client.list_tools(cursor=cursor)
                        names.update(tool.name for tool in page.tools)
                        cursor = page.next_cursor
                        if not cursor: break
                    self.assertIn("measurements_get", names)
                    self.assertNotIn("mask_edit", names)
                    self.assertNotIn("project_export", names)
                    inspected = await client.call_tool("project_inspect", {"arguments": {}})
                    self.assertEqual(inspected.structured_content["revision"], 5)
                    denied = await client.call_tool("mask_edit", {
                        "requestId": "denied", "expectedRevision": 5,
                        "arguments": {"imageId": image_id, "action": "delete", "labelIds": [1]},
                    })
                    self.assertTrue(denied.is_error)
                    self.assertEqual(denied.structured_content["error"]["code"], "permission_denied")

            asyncio.run(inspect_read_only())
            self.assertEqual(dispatch(request("project.inspect"))["revision"], 5)


if __name__ == "__main__":
    unittest.main()
