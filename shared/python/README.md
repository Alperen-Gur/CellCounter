# CellCounter Workbench Python runtime

This package provides `from workbench_sdk import WorkbenchClient` and the
`cellcounter-workbench` command. Both use the same versioned local operation
boundary as the desktop application and MCP server. Python 3.11 or later is
required. Scientific dependencies are pinned; MCP, local OME-Zarr and report
rendering are optional `mcp`, `zarr` and `reporting` extras. OMERO requirements
are supplied separately for an explicitly configured isolated environment.

From a source checkout, install this directory with
`python -m pip install './shared/python[mcp,zarr]'`. A built wheel can be installed
without requiring the repository as the current working directory. No runtime
installation is performed when an operation is called. This source package does
not contain model checkpoints, model environments or the separately packaged
Node microscopy engine.

```python
from workbench_sdk import WorkbenchClient

client = WorkbenchClient('/absolute/experiment.ccproject',
                         actor={'kind': 'agent', 'name': 'analysis assistant'})
snapshot = client.inspect()
request = client.prepare('image.metadata.set',
                         {'imageId': 'saved-image-id', 'tags': ['control']})
response = request.execute()
```

Prepared requests preserve actor, request ID and expected revision for explicit
exact retries. Revision conflicts are returned as structured errors; the SDK
does not silently rebase scientific changes. Local session writes have separate
session revisions and do not advance the client's scientific revision.

Installed desktop applications additionally expose their stable `--workbench`
command route, using their own bundled runtime. See the application's Workbench
documentation for scoped, read-only-default MCP connection configuration.
