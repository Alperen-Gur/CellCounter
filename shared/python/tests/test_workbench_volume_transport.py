"""Real-process 3D workflow and image transport, across CLI and MCP clients."""
from __future__ import annotations

import asyncio
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
import zipfile

RUNTIME = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RUNTIME))
from _fixtures import use_legacy_storage
AVAILABLE = all(importlib.util.find_spec(name) for name in ("numpy", "tifffile", "scipy", "skimage", "mcp"))


@unittest.skipUnless(AVAILABLE, "Install the analysis and MCP requirements")
class VolumeTransportTests(unittest.TestCase):
    def test_volume_workflow_restart_preview_correction_and_export(self):
        import numpy as np
        import tifffile
        from mcp import Client
        from mcp.client.stdio import StdioServerParameters
        from mcp.types import ImageContent, TextContent

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            project = root / "Volumes.ccproject"
            source = root / "time.ome.tif"
            destination = root / "volume-results.zip"
            raw = np.zeros((2, 6, 12, 14), np.uint16)
            raw[0, 1:3, 1:4, 2:6] = 1000
            raw[1, 1:3, 1:4, 3:7] = 1000
            tifffile.imwrite(source, raw, ome=True, photometric="minisblack", metadata={
                "axes": "TZYX", "PhysicalSizeX": .5, "PhysicalSizeY": .25, "PhysicalSizeZ": 2,
                "PhysicalSizeXUnit": "µm", "PhysicalSizeYUnit": "µm", "PhysicalSizeZUnit": "µm",
            })
            revision = 0

            def cli(operation, arguments):
                nonlocal revision
                request = {"schemaVersion": 1, "operation": operation, "requestId": str(uuid.uuid4()),
                           "projectPath": str(project), "arguments": arguments,
                           "actor": {"kind": "cli", "name": "Volume transport test"}}
                if operation != "project.create":
                    request["expectedRevision"] = revision
                process = subprocess.run(
                    [sys.executable, str(RUNTIME / "workbench.py"), "request", "--stdin"],
                    input=json.dumps(request), text=True, capture_output=True, timeout=60,
                )
                self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
                response = json.loads(process.stdout)
                self.assertTrue(response["ok"], response)
                revision = response["revision"]
                return response["result"]

            cli("project.create", {"name": "Volumes"})
            use_legacy_storage(project)
            image_id = cli("image.import", {"paths": [str(source)]})["importedImageIds"][0]
            parameters = {"method": "manual", "threshold": 500, "minDistanceVox": 100, "minVolumeVox": 1}
            workflow = cli("workflow.save", {"name": "Time series", "steps": [
                {"type": "volume-analysis", "parameters": parameters, "channel": 0},
                {"type": "measurements"}, {"type": "summary"},
            ]})["workflow"]
            job = cli("job.create", {"workflowId": workflow["id"], "imageIds": [image_id]})["job"]
            first = cli("job.advance", {"jobId": job["id"]})["job"]
            self.assertEqual(first["progress"]["completed"], 1)
            server = StdioServerParameters(command=sys.executable, args=[
                str(RUNTIME / "workbench.py"), "mcp", "--project", str(project),
                "--allow-write", "--allow-path", str(destination),
            ])

            async def exercise():
                nonlocal revision
                async with Client(server) as client:
                    async def call(operation, arguments, mutation=False):
                        nonlocal revision
                        payload = {"arguments": arguments, "expectedRevision": revision}
                        if mutation:
                            payload["requestId"] = str(uuid.uuid4())
                        reply = await client.call_tool(operation.replace(".", "_"), payload)
                        self.assertFalse(reply.is_error, reply)
                        revision = reply.structured_content["revision"]
                        return reply

                    persisted = await call("job.get", {"jobId": job["id"]})
                    self.assertEqual(persisted.structured_content["result"]["job"]["nextUnit"]["timeIndex"], 1)
                    await call("job.advance", {"jobId": job["id"]}, True)
                    finished = await call("job.advance", {"jobId": job["id"]}, True)
                    self.assertEqual(finished.structured_content["result"]["job"]["status"], "completed")
                    selection = {"imageId": image_id, "timeIndex": 1, "channel": 0}
                    for operation, args in [
                        ("volume.slice", {**selection, "plane": "xz", "index": 1}),
                        ("volume.analysis.preview", {**selection, "parameters": parameters}),
                    ]:
                        preview = await call(operation, args)
                        self.assertTrue(any(isinstance(item, ImageContent) for item in preview.content))
                        text = "".join(item.text for item in preview.content if isinstance(item, TextContent))
                        for binary_key in ("dataBase64", "labelDataBase64", "dataUrl", "overlayDataUrl"):
                            self.assertNotIn(f'"{binary_key}"', text)
                        self.assertLess(len(text), 10000)
                    display = await call("volume.display", selection)
                    descriptor = display.structured_content["result"]
                    self.assertEqual(len(base64.b64decode(descriptor["dataBase64"])), 6 * 12 * 14)
                    measured = await call("volume.measurements.get", selection)
                    cell = measured.structured_content["result"]["cells"][0]
                    self.assertEqual(cell["volumeUm3"], 6)
                    await call("volume.mask.edit", {**selection, "action": "delete", "labelIds": [cell["labelId"]]}, True)
                    stale = await call("job.get", {"jobId": job["id"]})
                    self.assertFalse(stale.structured_content["result"]["job"]["outputsCurrent"])
                    await call("volume.mask.undo", selection, True)
                    await call("tracks.run", {"imageId": image_id, "channel": 0, "maxDistance": 2, "units": "voxel"}, True)
                    await call("project.export", {"destination": str(destination)}, True)

            asyncio.run(exercise())
            with zipfile.ZipFile(destination) as archive:
                summary = json.loads(archive.read("volume-summary.json"))
                self.assertEqual(summary["frameCount"], 2)
                self.assertEqual([frame["volumeUm3"] for frame in summary["frames"]], [6, 6])
                self.assertIn("volume-measurements.csv", archive.namelist())


if __name__ == "__main__":
    unittest.main()
