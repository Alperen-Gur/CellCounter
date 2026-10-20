"""Transport invariants independent of optional learned-model dependencies."""
from __future__ import annotations

import asyncio
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import types


RUNTIME = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RUNTIME))
import workbench
from _workbench_mcp import ProjectScope, build_server


CATALOG = [
    {
        "name": "project.inspect", "description": "Inspect the project.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "mutating": False, "requiresProject": True,
    },
    {
        "name": "image.import", "description": "Import chosen images.",
        "inputSchema": {
            "type": "object", "properties": {
                "paths": {"type": "array", "items": {"type": "string"}, "minItems": 1}
            }, "required": ["paths"], "additionalProperties": False,
        },
        "mutating": True, "requiresProject": True,
    },
    {
        "name": "project.export", "description": "Export the current project.",
        "inputSchema": {
            "type": "object", "properties": {"destination": {"type": "string"}},
            "required": ["destination"], "additionalProperties": False,
        },
        "mutating": True, "requiresProject": True,
    },
]


def success(request):
    return {
        "schemaVersion": 1, "ok": True, "operation": request["operation"],
        "requestId": request["requestId"], "revision": 3, "result": request,
    }


class CliTests(unittest.TestCase):
    def test_help_without_site_packages(self):
        result = subprocess.run(
            [sys.executable, "-S", str(RUNTIME / "workbench.py"), "--help"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("mcp", result.stdout)

    def test_invalid_json_has_one_structured_error(self):
        result = subprocess.run(
            [sys.executable, str(RUNTIME / "workbench.py"), "request", "--stdin"],
            input='{"schemaVersion": 1, "schemaVersion": 2}', capture_output=True, text=True,
        )
        response = json.loads(result.stdout)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(response["error"]["code"], "invalid_request")

    def test_nonfinite_arguments_rejected(self):
        with self.assertRaises(ValueError):
            workbench.parse_json('{"calibration":NaN}')

    def test_request_uses_shared_dispatch_and_clean_stdout(self):
        module = types.ModuleType("_workbench_core")

        def dispatch(request):
            print("Scientific-runtime diagnostic")
            return success(request)

        module.dispatch = dispatch
        request = {"schemaVersion": 1, "operation": "project.inspect",
                   "requestId": "native-request", "arguments": {}}
        output = io.StringIO()
        with patch.dict(sys.modules, {"_workbench_core": module}), redirect_stdout(output):
            code = workbench.main(["request", "--json", json.dumps(request)])
        self.assertEqual(code, 0)
        response = json.loads(output.getvalue())
        self.assertEqual(response["result"], request)
        self.assertNotIn("diagnostic", output.getvalue())

    def test_cli_call_preserves_revision_and_request_identity(self):
        with patch.object(workbench, "run_request", side_effect=success):
            output = io.StringIO()
            with redirect_stdout(output):
                code = workbench.main([
                    "--project", "/tmp/example", "call", "mask.edit",
                    "--args", '{"imageId":"a"}', "--expected-revision", "4",
                    "--request-id", "retry-same-command",
                ])
        request = json.loads(output.getvalue())["result"]
        self.assertEqual(code, 0)
        self.assertEqual(request["expectedRevision"], 4)
        self.assertEqual(request["requestId"], "retry-same-command")
        self.assertEqual(request["arguments"]["imageId"], "a")


class ScopeTests(unittest.TestCase):
    def test_scope_blocks_escape_and_symlink(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            project = base / "project"
            project.mkdir()
            outside = base / "outside"
            outside.mkdir()
            (project / "linked").symlink_to(outside, target_is_directory=True)
            scope = ProjectScope(str(project), allow_write=True)
            self.assertTrue(scope._allows_path(str(project / "exports" / "run.zip")))
            self.assertFalse(scope._allows_path(str(project / ".." / "outside" / "run.zip")))
            self.assertFalse(scope._allows_path(str(project / "linked" / "run.zip")))
            self.assertFalse(scope._allows_path("relative.tif"))
            allowed = ProjectScope(str(project), True, [str(outside)])
            self.assertTrue(allowed._allows_path(str(outside / "chosen.tif")))

    def test_default_is_read_only(self):
        with tempfile.TemporaryDirectory() as folder:
            scope = ProjectScope(folder)
            self.assertIsNotNone(scope.check(CATALOG[1], {"paths": [folder + "/image.tif"]}))
            self.assertIsNotNone(scope.check(CATALOG[2], {"destination": folder + "/out.zip"}))

    def test_workflow_templates_and_job_destinations_are_scoped(self):
        with tempfile.TemporaryDirectory() as folder:
            project = Path(folder) / "project"
            project.mkdir()
            outside = str(Path(folder) / "outside.zip")
            scope = ProjectScope(str(project), allow_write=True)
            descriptor = {"name": "workflow.save", "mutating": True}
            self.assertIsNone(scope.check(descriptor, {"steps": [{"type": "export"}]}))
            self.assertIsNotNone(scope.check(descriptor, {
                "steps": [{"type": "export", "destination": outside}],
            }))
            self.assertIsNotNone(scope.check_workflow(
                {"steps": [{"type": "export"}]}, require_destinations=True,
            ))
            self.assertIsNotNone(scope.check(
                {"name": "job.create", "mutating": True}, {"exportDestination": outside},
            ))
            allowed = ProjectScope(str(project), True, [folder])
            self.assertIsNone(allowed.check(descriptor, {
                "steps": [{"type": "export", "destination": outside}],
            }))


@unittest.skipUnless(importlib.util.find_spec("mcp"), "Optional MCP SDK is not installed")
class McpTests(unittest.IsolatedAsyncioTestCase):
    async def test_job_execution_checks_immutable_workflow_before_dispatch(self):
        from mcp import Client

        arguments_schema = {
            "type": "object", "properties": {"jobId": {"type": "string"}},
            "required": ["jobId"], "additionalProperties": False,
        }
        catalog = [{
            "name": "job.advance", "description": "Execute the next saved job unit.",
            "inputSchema": arguments_schema, "mutating": True, "requiresProject": True,
        }]
        calls = []
        workflow = {"steps": [{"type": "export", "destination": "/ungranted/results.zip"}]}

        def dispatch(request):
            calls.append(request)
            result = success(request)
            if request["operation"] == "job.get":
                result["revision"] = 10
                result["result"] = {"job": {"workflow": workflow}}
            return result

        with tempfile.TemporaryDirectory() as folder:
            server = build_server(folder, allow_write=True, dispatcher=dispatch, catalog=catalog)
            async with Client(server) as client:
                payload = {"arguments": {"jobId": "job-1"}, "requestId": "advance-1", "expectedRevision": 3}
                denied = await client.call_tool("job_advance", payload)
                self.assertTrue(denied.is_error)
                self.assertEqual(denied.structured_content["error"]["code"], "permission_denied")
                self.assertEqual([call["operation"] for call in calls], ["job.get"])
                workflow["steps"][0]["destination"] = str(Path(folder) / "results.zip")
                accepted = await client.call_tool("job_advance", payload)
                self.assertFalse(accepted.is_error)
                self.assertEqual([call["operation"] for call in calls], ["job.get", "job.get", "job.advance"])
                # A current read authorizes an immutable snapshot, while the
                # mutation retains the old revision needed for an exact replay.
                self.assertNotIn("expectedRevision", calls[-2])
                self.assertEqual(calls[-1]["expectedRevision"], 3)
                self.assertEqual(calls[-1]["requestId"], "advance-1")

    async def test_refresh_replay_requires_only_its_frozen_external_source_grants(self):
        from mcp import Client
        from _workbench_store import ProjectStore
        from _workbench_recompute import external_source_paths

        schema = {"type": "object", "properties": {"refreshId": {"type": "string"}},
                  "required": ["refreshId"], "additionalProperties": False}
        catalog = [{"name": name, "description": "Refresh a retained dependency.", "inputSchema": schema,
                    "mutating": True, "requiresProject": True} for name in ("refresh.advance", "refresh.worker.start")]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); project = root / "project"; project.mkdir()
            external = root / "selected.zarr"; external.mkdir()
            unrelated = root / "unrelated.zarr"; unrelated.mkdir()
            origin = {"kind": "workspace", "resolvedInputs": [], "parentPlanes": [{"path": "parent", "hash": "a",
                "provenance": {"sourceBindings": [{"sourceKind": "zarr", "sourceId": "needed"}]}}]}
            document = {"images": [{"id": "derived", "derivation": origin},
                                   {"id": "unrelated", "derivation": {"kind": "workspace", "resolvedInputs": [{"sourceKind": "zarr", "sourceId": "other"}]}}],
                        "zarrSources": [{"id": "needed", "path": str(external)}, {"id": "other", "path": str(unrelated)}],
                        "refreshJobs": [{"id": "refresh", "definition": {"dependencyMode": "transitive-1"},
                                         "units": [{"kind": "derived-image", "imageId": "derived", "status": "pending"}]}]}
            self.assertEqual(external_source_paths(document, {}, refresh_id="refresh"), [str(external)])
            with patch("_workbench_recompute._selected_records", return_value=([{"kind": "derived-image", "imageId": "derived"}], {}, {})):
                self.assertEqual(external_source_paths(document, {}), [str(external)])
            calls = []
            def dispatch(request):
                calls.append(request["operation"])
                response = success(request)
                if request["operation"] == "refresh.get": response["result"] = {"refresh": document["refreshJobs"][0]}
                return response
            with patch.object(ProjectStore, "__init__", return_value=None), patch.object(ProjectStore, "read", return_value=document):
                for name in ("refresh.advance", "refresh.worker.start"):
                    payload = {"arguments": {"refreshId": "refresh"}, "requestId": name, "expectedRevision": 3}
                    server = build_server(str(project), allow_write=True, dispatcher=dispatch, catalog=catalog)
                    async with Client(server) as client:
                        result = await client.call_tool(name.replace(".", "_"), payload)
                        self.assertEqual(result.structured_content["error"]["code"], "permission_denied")
                        self.assertNotIn(name, calls)
                    allowed = build_server(str(project), allow_write=True, allowed_paths=[str(external)], dispatcher=dispatch, catalog=catalog)
                    async with Client(allowed) as client:
                        result = await client.call_tool(name.replace(".", "_"), payload)
                        self.assertFalse(result.is_error, result.structured_content)
                        self.assertEqual(calls[-1], name)
                    calls.clear()
            document["refreshJobs"][0]["units"][0]["status"] = "completed"
            self.assertEqual(external_source_paths(document, {}, refresh_id="refresh"), [])

    async def test_preview_emits_image_content_without_base64_in_text(self):
        from mcp import Client
        from mcp.types import ImageContent, TextContent

        catalog = [{
            "name": "image.preview", "description": "Read an image preview.",
            "inputSchema": {"type": "object", "properties": {}},
            "mutating": False, "requiresProject": True,
        }]

        def preview(request):
            result = success(request)
            result["result"] = {"dataUrl": "data:image/png;base64,iVBORw0KGgo=", "width": 10, "height": 20}
            return result

        with tempfile.TemporaryDirectory() as folder:
            server = build_server(folder, dispatcher=preview, catalog=catalog)
            async with Client(server) as client:
                result = await client.call_tool("image_preview", {"arguments": {}})
                self.assertFalse(result.is_error)
                self.assertTrue(any(isinstance(item, ImageContent) for item in result.content))
                texts = [item.text for item in result.content if isinstance(item, TextContent)]
                self.assertNotIn("iVBORw0KGgo=", "".join(texts))
                self.assertIn("dataUrl", result.structured_content["result"])

    async def test_real_sdk_stdio_subprocess(self):
        from mcp import Client
        from mcp.client.stdio import StdioServerParameters

        with tempfile.TemporaryDirectory() as folder:
            script = Path(folder) / "server.py"
            script.write_text(
                "import sys, anyio\n"
                f"sys.path.insert(0, {str(RUNTIME)!r})\n"
                f"sys.path.insert(0, {str(RUNTIME / 'tests')!r})\n"
                "from _workbench_mcp import build_server\n"
                "from test_workbench_protocol import CATALOG, success\n"
                "from mcp.server.stdio import stdio_server\n"
                f"server = build_server({folder!r}, dispatcher=success, catalog=CATALOG)\n"
                "async def run():\n"
                "    async with stdio_server() as (reader, writer):\n"
                "        await server.run(reader, writer, server.create_initialization_options())\n"
                "anyio.run(run)\n",
                encoding="utf-8",
            )
            async with Client(StdioServerParameters(command=sys.executable, args=[str(script)])) as client:
                tools = (await client.list_tools()).tools
                self.assertEqual([tool.name for tool in tools], ["project_inspect"])
                result = await client.call_tool("project_inspect", {"arguments": {}})
                self.assertFalse(result.is_error)
                self.assertEqual(result.structured_content["revision"], 3)

    async def test_sdk_handshake_read_only_and_structured_output(self):
        from mcp import Client

        with tempfile.TemporaryDirectory() as folder:
            server = build_server(folder, dispatcher=success, catalog=CATALOG)
            async with Client(server) as client:
                tools = (await client.list_tools()).tools
                self.assertEqual([tool.name for tool in tools], ["project_inspect"])
                result = await client.call_tool("project_inspect", {"arguments": {}})
                self.assertFalse(result.is_error)
                self.assertEqual(result.structured_content["revision"], 3)
                self.assertEqual(result.structured_content["result"]["projectPath"], str(Path(folder).resolve()))
                denied = await client.call_tool("image_import", {
                    "arguments": {"paths": [folder + "/a.tif"]}, "requestId": "x",
                    "expectedRevision": 0,
                })
                self.assertTrue(denied.is_error)

    async def test_write_schema_scope_and_dispatch(self):
        from mcp import Client

        calls = []

        def dispatch(request):
            calls.append(request)
            return success(request)

        with tempfile.TemporaryDirectory() as folder:
            project = Path(folder) / "project"
            server = build_server(str(project), allow_write=True, dispatcher=dispatch, catalog=CATALOG)
            async with Client(server) as client:
                missing = await client.call_tool("image_import", {"arguments": {"paths": [str(project / "a.tif")]}})
                self.assertTrue(missing.is_error)
                escaped = await client.call_tool("image_import", {
                    "arguments": {"paths": [str(Path(folder) / "outside.tif")]},
                    "requestId": "import-1", "expectedRevision": 0,
                })
                self.assertTrue(escaped.is_error)
                self.assertEqual(escaped.structured_content["error"]["code"], "permission_denied")
                imported = await client.call_tool("image_import", {
                    "arguments": {"paths": [str(project / "a.tif")]},
                    "requestId": "import-1", "expectedRevision": 0,
                })
                self.assertFalse(imported.is_error)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["actor"]["kind"], "agent")
        self.assertEqual(calls[0]["expectedRevision"], 0)


if __name__ == "__main__":
    unittest.main()
