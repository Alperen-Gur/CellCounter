# CellCounter Workbench for Python

Use `WorkbenchClient` or the `cellcounter-workbench` command to work with
CellCounter projects from Python and the terminal. Both share the desktop
Workbench's operations for masks, measurements, workflows and export. The MCP
server uses the same runtime.

[Workbench guide](../../docs/WORKBENCH.md) · [CLI examples](../../docs/WORKBENCH.md#cli-example) · [MCP setup](../../docs/WORKBENCH.md#mcp-connection) · [Main project](../../README.md)

## Installation

Use Python 3.11 or later. Download the **0.1.0 wheel** from the
[1.1.0 release](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.1.0),
then install it:

```sh
python -m pip install ./cellcounter_workbench-0.1.0-py3-none-any.whl
cellcounter-workbench capabilities
```

From a checkout, run this in the repository root:

```sh
python -m pip install './shared/python[mcp,zarr]'
```

Optional extras provide MCP (`mcp`), local OME-Zarr (`zarr`) and report rendering
(`reporting`). Set up learned models, the Node microscopy engine and OMERO in
their own environments as described in the [Workbench guide](../../docs/WORKBENCH.md).

## Use an existing project

Replace the paths and image ID with your own:

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

`inspect()` reads the current project revision. Writes advance it; conflicts
return structured errors. A prepared request keeps its arguments, request ID,
actor and revision for retrying after a connection interruption.

For a new project path, call `client.create("Experiment")`. Use
`client.discover(prefix="analysis.", include_schemas=True)` to find operations
and their arguments. See the [SDK reference](../../docs/WORKBENCH.md#python-sdk)
for request envelopes, errors and custom transports.

## Desktop and agent integration

Installed desktop apps accept `--workbench` commands through their configured
runtime. Follow the [MCP guide](../../docs/WORKBENCH.md#mcp-connection) to grant
access to a project, external files and executable plugins or models.

Current source builds include a shared task catalogue:

```sh
python shared/python/workbench.py call navigation.catalog
```

Run that from the repository root, or use
`cellcounter-workbench call navigation.catalog` after installing from source.
Use `capabilities` or `operations.discover` to check an installed runtime.

The task IDs are `preparation`, `segmentation`, `measurements`, `review`,
`workflows` and `export`. Operation descriptors include their `navigationTask`.
To navigate an open desktop session, read `session.list` and `session.get`, then
call `session.navigate` with `selection={"task":"review"}`, the current
`expectedSessionRevision` and `observedProjectRevision`. The desktop responds
with `applied`, `deferred` or `refused`. Task-only navigation keeps the image,
spatial selection and drafts.

See [shared sessions](../../docs/WORKBENCH.md#shared-project-sessions-and-agent-navigation)
and [runtime configuration](../../docs/WORKBENCH.md#runtime-configuration-and-plugin-environments)
for examples and host setup.

## License

CellCounter is MIT licensed. See [LICENSE](../../LICENSE) and
[third-party notices](../../THIRD_PARTY_LICENSES.md) for dependencies and models.
