# CellCounter Workbench for Python

The Python package provides `WorkbenchClient` and the `cellcounter-workbench`
command. Both use the desktop Workbench's versioned scientific operation
runtime, including project revisions, exact masks, measurements, workflows and
export provenance. MCP clients use the same dispatcher.

[Workbench guide](../../docs/WORKBENCH.md) · [CLI examples](../../docs/WORKBENCH.md#cli-example) · [MCP setup](../../docs/WORKBENCH.md#mcp-connection) · [Main project](../../README.md)

## Installation

Python 3.11 or later is required. A dedicated Python 3.11 environment is
recommended for the pinned scientific dependencies. Download the **0.1.0 wheel**
from the [1.1.0 release](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.1.0),
then install the local file:

```sh
python -m pip install ./cellcounter_workbench-0.1.0-py3-none-any.whl
cellcounter-workbench capabilities
```

Alternatively, from the repository root:

```sh
python -m pip install './shared/python[mcp,zarr]'
```

The optional `mcp`, `zarr` and `reporting` extras supply MCP, local OME-Zarr and
report rendering dependencies. OMERO requirements are supplied separately for
an explicitly configured isolated environment. The package works outside the
repository directory after installation.

The distribution contains the canonical Python runtime. It does not contain
model checkpoints, learned-model environments or the separately packaged Node
microscopy engine. SDK operations never install dependencies implicitly.

## Use an existing project

Replace the example paths and image ID with values from your project:

```python
from workbench_sdk import WorkbenchClient, WorkbenchOperationError

client = WorkbenchClient(
    "/absolute/experiment.ccproject",
    actor={"kind": "agent", "name": "Local analysis script"},
)
snapshot = client.inspect()
request = client.prepare(
    "image.metadata.set",
    {"imageId": "saved-image-id", "tags": ["control"]},
    request_id="tag-control-1",
)
try:
    response = request.execute()
except WorkbenchOperationError as error:
    print(error.code, error.details)
```

`inspect()` explicitly adopts the observed project revision. Successful mutations
advance the client's known revision. Conflicts return structured errors and do
not silently rebase scientific changes. A prepared request retains its actor,
arguments, request ID and expected revision for an explicit exact retry. Local
session writes have separate revisions and do not advance scientific state.

Use `client.create("Experiment")` for a new project path that does not exist.
Use `client.discover(prefix="analysis.", include_schemas=True)` to read a bounded
operation page with exact argument schemas. The [SDK reference](../../docs/WORKBENCH.md#python-sdk)
explains full request envelopes, errors and custom transports.

## Desktop and agent integration

Installed desktop applications expose a stable `--workbench` command route using
their configured runtime. For scoped, read-only-default MCP connections, follow
[the connection guide](../../docs/WORKBENCH.md#mcp-connection). Writes, executable
operations and external source access require the applicable explicit grants.

Current source builds also expose `navigation.catalog`, a project-free read
operation for the shared **Images**, **Segmentation**, **Measurements**,
**Review**, **Workflows** and **Results & export** tasks:

```sh
python shared/python/workbench.py call navigation.catalog
```

Run this example from the repository root. After installing a current source
build, the equivalent command is `cellcounter-workbench call navigation.catalog`.
The published 0.1.0 wheel and desktop releases predate this operation; check
`capabilities` or `operations.discover` before using it with an installed runtime.

Canonical operation descriptors include their explicit `navigationTask` when
assigned. The catalogue preserves their execution/revision requirements;
optional dependencies and MCP permissions still require their usual checks.
Task discovery does not navigate a GUI or run an analysis.

To request navigation in an open graphical session, read `session.list` and
`session.get`, then send `session.navigate` with `selection={"task":"review"}`,
the current `expectedSessionRevision` and `observedProjectRevision`. Supported
task IDs are `preparation`, `segmentation`, `measurements`, `review`, `workflows`
and `export`. Task-only requests preserve spatial selection and drafts, and
require the host's applied/deferred/refused acknowledgement. Task changes do
not advance the scientific revision. Requests that omit `task` remain compatible.
See [shared sessions and task navigation](../../docs/WORKBENCH.md#shared-project-sessions-and-agent-navigation)
for complete examples and stale-selection handling.

Optional Node, plugin and OMERO bindings are configured on the host. Credentials,
interpreter paths and execution permissions are not portable project data. See
[runtime configuration](../../docs/WORKBENCH.md#runtime-configuration-and-plugin-environments)
for the shared SDK/CLI configuration behavior.

## License

CellCounter is MIT licensed. Optional models and dependencies may use different
terms; see [LICENSE](../../LICENSE) and
[third-party notices](../../THIRD_PARTY_LICENSES.md).
