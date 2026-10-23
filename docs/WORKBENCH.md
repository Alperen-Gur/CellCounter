# CellCounter Workbench

The Workbench uses one local project format and one operation dispatcher for the
desktop interface, command line, Python SDK and Model Context Protocol (MCP)
clients. A mask edit from one client changes the measurements read by the others.
Project revisions prevent a client with an old view from silently overwriting a
later edit. This guide covers the desktop Workbench; the
[browser preview](WEB.md) has a separate, smaller capability set.

Start with the [desktop workflow](#desktop-workflow), [CLI example](#cli-example),
[Python SDK](#python-sdk) or [MCP connection](#mcp-connection).

- **Analysis:** [channel displays](#multi-channel-fluorescence-display),
  [tracking and lineage](#tracking-and-lineage),
  [preprocessing and assays](#preprocessing-independent-masks-and-assays), and
  [annotations](#annotations-and-intensity-profiles).
- **Reproducible workflows:** [saved jobs](#saved-workflows-and-resumable-jobs),
  [branching workflows](#branching-workflows), [parameter sweeps](#parameter-sweeps),
  [review](#review-and-quality-control) and [result refresh](#refreshing-results-after-corrections).
- **Experiments and reporting:** [biological replicates](#experiments-and-biological-replicates),
  [statistical designs](#experimental-designs-and-statistical-reports),
  [experimental layouts](#reusable-experimental-layouts-and-exclusions) and
  [exports](#saved-data-and-export).
- **Data and integrations:** [library migration](#import-an-existing-cellcounter-library),
  [large TIFF regions](#large-tiff-sources-and-regions),
  [OMERO](#read-only-omero-import), [plugins and models](#plugins-and-local-learned-models),
  [layer workspaces](#layer-workspaces-and-semantic-journals),
  [streamed packages](#large-libraries-and-streamed-packages) and
  [portable distributed tasks](#portable-distributed-tasks).
- **Reference:** [runtime setup](#standalone-runtime),
  [runtime configuration](#runtime-configuration-and-plugin-environments),
  [agent discovery](#operation-discovery-and-compact-mcp),
  [current scope and troubleshooting](#current-scope-and-troubleshooting).

## Desktop workflow

Open **Workbench**, create a project folder, then import images. Choose a channel
and, for supported stacks, a Z projection. Use **Preview** to inspect segmentation
without saving it; **Run analysis** saves the exact label mask and measurements.
Choose a supported classical threshold method, or a manual threshold in the source image's intensity units.

Select objects to delete or merge them, draw a polygon to add an object, and undo
a correction when needed. Corrections immediately recompute measurements. Enter
calibration in **pixels per micrometre** to calculate physical area and equivalent
diameter; without calibration, physical values remain unknown. Applying a new
calibration updates physical measurements without changing the mask.

Use **Summary** for descriptive counts and per-image measurements, and **Export**
to write a new ZIP. Open the same project folder in another client or use
**Refresh** to load changes made elsewhere. The desktop interfaces also refresh
when they regain focus if there are no active edits. An explicit refresh discards
an unsaved segmentation preview.

Choose **3D / time** for individual volumes in a stack or time series. The linked
XY, XZ and YZ views navigate a shared crosshair. The WebGL volume view supports
rotation, zoom, intensity windowing and opacity; orthogonal previews remain
available if the graphics context is unavailable. Rendering uses at most 128
samples along each dimension. Scientific measurements and edits use the original
voxels, not the reduced display.

Run 3D threshold/watershed segmentation for the selected time and channel, then
correct labels with source-slice polygons or a spherical brush. Delete and merge
operate on whole 3D objects. Replacing a polygon changes only the selected plane
of an object. Undo restores geometry and uses the current calibration.
X, Y and Z voxel sizes are independent; physical volume requires all three.
Empty calibration fields clear that dimension to unknown.

## Tracking and lineage

The basic tracker links analyzed time points using bounded one-to-one centroid
matching. Choose a maximum displacement, voxel or physical units, and an allowed
missing-frame gap. Manual link/unlink operations correct correspondences. This
basic mode creates tracks without division inference. Mask or calibration
changes mark captured tracks stale until tracking is recomputed.

For drift-aware association and heuristic division inference, use
`temporal.track.preview` and `temporal.track.run`. The preview reports ambiguity
and exact source bindings; inferred divisions remain unconfirmed biological
hypotheses until reviewed. Drift offsets describe sample translation relative to
the first selected frame. No intermediate observations are invented inside gaps.
`temporal.catalogue` reports the available controls and limits.

`temporal.propagate.preview` shows translated exact-label corrections, clipping,
collisions and proposed replacements across selected frames.
`temporal.propagate.run` applies the reviewed group with retained before/after
evidence. Propagation does not segment images or infer missing identities across
divisions or merges. Undo requires all target outputs to still match the retained
group. Changed masks make the previous temporal graph historical until recomputed.

Initialize a lineage graph from current tracks to record cell divisions and
correct continuations. A division connects one parent to two daughters at a later
analyzed time point. Candidate suggestions rank geometry and combined volume;
they require a researcher's decision. Graph edits retain reasons and history,
support undo, and report per-track observations, movement and volume summaries.
`lineage.get`, `lineage.initialize`, `lineage.division.set`,
`lineage.division.remove`, `lineage.link`, `lineage.unlink`, `lineage.undo`,
`lineage.suggest` and `lineage.summary` expose the same operations to agents.
Changes to the underlying masks, calibration or base tracks mark the graph stale.

`lineage.export.catalogue` lists graph JSON, observation CSV, track-summary CSV
and link CSV formats. `lineage.export` saves the current graph through the same
GUI, CLI and MCP operation. Exports retain the exact graph revision and source
label hashes. Observation tables include calibrated centroids when spacing is
known; link tables distinguish continuations from recorded divisions and report
unobserved frames between endpoints. Track spans and path lengths describe
observations, without inferring birth, death or movement inside a gap. CSV times
are relative to acquisition frame zero. Unknown calibration remains empty.
Graph JSON retains full correction history. Existing destination files are never
overwritten, and exported files and provenance remain in analysis packages.

The workbench project is separate from the existing image library. Native desktop
builds require a local Python analysis environment installed through **Models**.
The browser preview does not run this filesystem-backed workbench.

## Multi-channel fluorescence display

`image.composite.preview` combines up to eight distinct channels into a color
display. Give each channel a color, visibility, contribution and gamma. Omit both
intensity limits to use the supported source plane's minimum and maximum, or
supply lower and upper limits in source-intensity units. Gamma above one
brightens midtones. A constant automatic range contributes black; explicit limits
can display its constant intensity.

For a plane, choose a max, mean or middle Z projection. For a volume, choose an
explicit time, XY/XZ/YZ plane and slice. The acquisition is decoded once and the
channels are mixed sequentially. The preview uses nearest source-center sampling
and is bounded to 2,048 pixels per side. Returned coordinates and dimensions
remain tied to the source grid. Unsupported fill pixels are transparent and do
not contribute to automatic windows; a slice without acquired support reports an
actionable error.

These controls change only the display. Analysis channel selection, labels,
calibration, source intensities and measurements remain unchanged. Additive color
mixtures are clipped to the display range. `image.composite.catalogue` describes
the controls and bounds for GUI, CLI and agent clients.

`image.composite.export` saves the same rendering as a new PNG with embedded
source, effective-window and display-setting provenance. The retained file and
provenance are included in project packages. This bounded display export is
separate from native-resolution source and label exports.

`image.composite.volume` applies the same channel controls to a true 3D display
at an explicit time point. Its RGBA voxel grid is bounded to 128 samples per
dimension, with a source-center coordinate transform and transparent unsupported
voxels. Automatic windows use the entire supported volume; a slice preview's
automatic window may therefore differ. Colors and gamma affect viewing only.

An optional `labelChannel` adds the current saved 3D labels for that time and
channel on the identical sampled grid. The response distinguishes an absent
analysis from labels that were not requested; stale labels require recomputation.
Full-resolution labels and measurements remain authoritative. Nearest sampling
can omit thin structures from the display. CLI and MCP clients receive the same
RGBA and label buffers with effective windows, source identity and calibration.

Display presets retain named versions of channel colors, visibility, gamma,
contribution, intensity windows and both display bounds. `display.preset.save`
creates a new preset, or appends a version when given `presetId`. Earlier versions
remain available through `display.preset.get`. `display.preset.list` returns the
latest versions; `display.preset.archive` hides or restores an identity without
deleting its history. Projects retain up to 100 preset identities and 1,000 total
versions, including archived presets.

Use `display.preset.resolve` to apply a saved version to another image. Channel
mapping uses explicit zero-based indices and must include every saved channel
exactly once; omission means the same indices. No fluorophore equivalence is
inferred. Fixed limits cannot cross between raw and processed intensity units.
Automatic-only presets can cross those units with an explicit compatibility
notice, and their windows are recalculated for the selected plane or volume.

Resolving settings changes no image, analysis selection or display. The returned
`presetRef` can accompany a composite preview, 3D display or PNG export while the
channel settings and relevant render bound exactly match that version. Edited
settings require removing the reference or saving another version. The runtime
checks the retained version hash and channel mapping before recording preset
provenance. Archived versions remain available for explicit reuse. Full preset
history is included in analysis packages.

## Standalone runtime

Use Python 3.11 and a dedicated environment. From the repository root:

```sh
python3.11 -m venv .venv-workbench
.venv-workbench/bin/python -m pip install -r shared/python/requirements-analysis.txt
.venv-workbench/bin/python shared/python/workbench.py capabilities
```

On Windows, create the environment with `py -3.11 -m venv .venv-workbench` and use
`.venv-workbench\Scripts\python.exe` in place of `.venv-workbench/bin/python`.
MCP is optional:

```sh
.venv-workbench/bin/python -m pip install -r shared/python/requirements-mcp.txt
```

`capabilities` reports the installed dependencies, operation schemas, formats and
limits. Help and ordinary CLI commands do not require the MCP SDK.

## CLI example

The following commands use example absolute paths; replace them with your own.
The new project directory must not already exist. Each successful mutation
returns the current `revision`; use that value for the next mutation.

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call project.create --args '{"name":"Experiment"}' --request-id create-1
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call image.import --args '{"paths":["/data/cells.tif"],"pxPerUm":2}' --expected-revision 0 --request-id import-1
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call project.inspect
```

Copy an image ID from `importedImageIds` or the inspection response:

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call analysis.preview --args '{"imageId":"IMAGE_ID","parameters":{"method":"otsu"}}'
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call analysis.run --args '{"imageId":"IMAGE_ID","parameters":{"method":"otsu"}}' --expected-revision 1 --request-id analyze-1
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call measurements.get --args '{"imageId":"IMAGE_ID"}'
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call project.export --args '{"destination":"/data/analysis.zip"}' --expected-revision 2 --request-id export-1
```

For scripts and graphical clients, `request --stdin`, `request --file request.json`
or `request --json '…'` accepts the complete envelope:

```json
{
  "schemaVersion": 1,
  "operation": "mask.edit",
  "requestId": "delete-one-1",
  "projectPath": "/data/Experiment.ccproject",
  "expectedRevision": 2,
  "actor": {"kind": "cli", "name": "My analysis script"},
  "arguments": {"imageId": "IMAGE_ID", "action": "delete", "labelIds": [1]}
}
```

Each CLI invocation emits one JSON envelope to stdout and diagnostics to stderr.
Exit status is 0 for success and 1 for an operation error. The response contains
`ok`, `operation`, `requestId`, and either `result` or `error`; project responses
also include `revision`. Reuse a request ID only for an exact retry, including its
original revision, actor and arguments. A changed payload with the same ID fails.

### Multi-channel display from the CLI

For an image with at least two channels, this request displays channel 0 in
magenta and channel 1 in green. Channel indices are zero-based. Automatic windows
use the valid acquired samples in the selected projection; source pixels and
measurements are unchanged.

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call image.composite.preview --args '{"imageId":"IMAGE_ID","target":"plane","sourceParameters":{"zProjection":"max"},"channels":[{"channel":0,"color":"#ff00ff"},{"channel":1,"color":"#00ff00"}],"maxSize":1024}'
```

The JSON result contains a PNG `dataUrl` and the effective intensity windows.
To export the same display, use the same settings and the revision returned by
the preview. The example below assumes that revision is 3. Choose a new
destination filename; an existing file will not be overwritten.

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call image.composite.export --args '{"imageId":"IMAGE_ID","target":"plane","sourceParameters":{"zProjection":"max"},"channels":[{"channel":0,"color":"#ff00ff"},{"channel":1,"color":"#00ff00"}],"maxSize":1024,"format":"composite-png","destination":"/data/channels.png"}' --expected-revision 3 --request-id composite-export-1
```

For a volume or time series, set `target` to `volume`, omit `sourceParameters`,
and supply `timeIndex`, `plane` and `index` explicitly. For example,
`"timeIndex":0,"plane":"xy","index":0` selects the first XY slice at the first time
point. `xz` and `yz` are also supported. Display exports embed the selected slice
or projection, effective channel settings, source identity and calibration. The
same operation names and arguments are available through MCP.

For the 3D renderer, request a bounded RGBA volume instead of a single slice:

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call image.composite.volume --args '{"imageId":"IMAGE_ID","timeIndex":0,"channels":[{"channel":0,"color":"#ff00ff"},{"channel":1,"color":"#00ff00"}],"maxDimension":128,"labelChannel":0}'
```

This read-only operation returns base64 RGBA voxels and their mapping to the
original source grid. Automatic contrast spans the supported volume at the
selected time, so its range may differ from an individual slice preview. The
optional `labelChannel` adds current saved labels for that analysis channel;
it does not change which channels contribute color. The response reports when
labels are absent and rejects stale labels. Desktop **Render 3D composite** uses
this same operation. PNG export continues to export the selected slice or
projection; it does not capture the rotated 3D camera view.

### Reusing display settings from the CLI

Save channel settings as a named preset. This example assumes the current project
revision is 4; substitute the revision returned by your latest operation.

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call display.preset.save --args '{"name":"Two-channel fluorescence","intensityUnits":"raw-source","channels":[{"channel":0,"color":"#ff00ff"},{"channel":1,"color":"#00ff00"}],"maxSize":1024,"maxDimension":128}' --expected-revision 4 --request-id preset-save-1
```

Use the returned preset ID to resolve settings against a target image:

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call display.preset.resolve --args '{"presetId":"PRESET_ID","version":1,"imageId":"IMAGE_ID"}'
```

Resolution checks channel indices and intensity units without rendering or
changing the image. Pass `settings.channels`, the applicable display bound
(`settings.maxSize` for a slice or `settings.maxDimension` for a volume), and the
returned `presetRef` with your composite request to retain its exact preset
version in display provenance. When
channel indices differ, supply a complete explicit `channelMapping`, such as
`[{"source":0,"target":1},{"source":1,"target":0}]`; channel names or fluorophores
are not inferred. Automatic windows are recomputed for the selected target.

For transfer to another project, export a specific version. This example assumes
the preceding save returned revision 5:

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call display.preset.export --args '{"presetId":"PRESET_ID","version":1,"format":"preset-json","destination":"/data/channels-preset.json"}' --expected-revision 5 --request-id preset-export-1
```

In the destination project, call `display.preset.import.preview` with the file's
absolute `path`, then pass that path and the returned `previewFingerprint` to
`display.preset.import.run` with the current expected revision. Import creates a
new local identity and retains the original file; applying the settings remains
an explicit action.

## MCP connection

Configure an MCP client to launch the dedicated Python executable over stdio:

```json
{
  "mcpServers": {
    "cellcounter": {
      "command": "/absolute/repository/.venv-workbench/bin/python",
      "args": [
        "/absolute/repository/shared/python/workbench.py",
        "mcp",
        "--project", "/data/Experiment.ccproject"
      ]
    }
  }
}
```

The default connection exposes read-only tools. To permit analysis, corrections,
imports, calibration changes and exports, add `--allow-write` to `args`. Import
and export paths must remain inside the configured project unless a file or
directory is explicitly granted with `--allow-path /data/chosen-directory`.
Repeat that flag for additional locations. The client cannot change the project
path through a tool call.

Trusted local plugins and registered model environments require the additional
`--allow-plugins` grant, which also requires `--allow-write`. This includes
plugin installation/enabling, inference, training, reader/exporter execution and
executable steps in saved jobs. Grant the plugin directory, checkpoint,
interpreter and external input/output locations explicitly with `--allow-path`.
Plugins execute Python with the user's permissions; the execution timeout and
output limits are not an operating-system sandbox.

MCP tool names replace operation dots with underscores, for example
`project_inspect`, `analysis_run` and `mask_edit`. Their inputs contain an
`arguments` object matching the CLI operation schema. Mutating calls require a
stable `requestId` and `expectedRevision`, except that project creation and package restoration do not
require an existing revision. `job.worker.stop` records a worker-control request
without changing the scientific project revision, so it also omits
`expectedRevision`. Tools return the shared response as structured
content. Preview and source-slice tools additionally return native MCP image
content. Encoded image and volume buffers remain in structured content and are
omitted from the duplicate text response.

Volume operations take explicit `imageId`, zero-based `timeIndex` and `channel`.
Use `volume.inspect`, `volume.display`, `volume.slice`,
`volume.analysis.preview`, `volume.analysis.run`, `volume.measurements.get`,
`volume.mask.edit` and `volume.mask.undo`. `volume.calibration.set` updates or
clears individual axes and the time interval. `tracks.run`, `tracks.get`,
`tracks.link` and `tracks.unlink` use an image ID and channel. The capability
catalog defines all required arguments and limits.

Volume arrays use ZYX order with X contiguous. Coordinates in measurements and
edits use voxel edges, so the first voxel center is `(0.5, 0.5, 0.5)`.
Slice indices and renderer crosshairs use zero-based voxel indices. Display
descriptors include the scale and offset mapping sampled indices to source
indices; their label texture uses nearest-neighbor sampling.

## Saved workflows and resumable jobs

Save a workflow with `workflow.save`. Its supported steps include, in order,
an optional `preprocessing` recipe,
`analysis`, `volume-analysis`, `plugin-segmentation` or `model-segmentation`,
optional `plugin-measurement` and `assay` steps, `measurements`, `summary`, and
optionally `export`. The analysis step
captures segmentation parameters. Saving an existing `workflowId` creates a new
immutable version; existing jobs retain the version they captured.
For volumes, the first step contains `parameters` and a separate `channel`.
`job.create` accepts optional `timeIndices`; omitting it processes all time
points in each selected image. An explicit time selection must be valid for
every selected image. Each volume frame is a separate checkpoint.

An initial preprocessing step creates a retained derived acquisition for each
selected input plane or time/channel frame. Subsequent steps use that derived
image; the original remains available. The job records both the original
selection and its working image and resumes after completed recipe checkpoints.
Processed outputs use channel zero and, for volumes, time zero internally.
Assay settings therefore refer to the processed channel. Cross-channel assays
and fixed nuclear-reference bindings require compatible source data and are
rejected in these single-channel preprocessing workflows.
Recipes and the original and derived source dependencies participate in job
currentness checks. Biological assignments and reference approvals are not copied
to derived images automatically.

For example, pass this object as the operation's `arguments`:

```json
{
  "name": "Count and export",
  "steps": [
    {"type": "analysis", "parameters": {"method": "otsu", "minAreaPx": 20}},
    {"type": "measurements"},
    {"type": "summary"},
    {"type": "export"}
  ]
}
```

Create a job using the returned workflow ID and chosen image IDs:

```json
{
  "workflowId": "WORKFLOW_ID",
  "imageIds": ["IMAGE_ID"],
  "exportDestination": "/data/workflow-output.zip"
}
```

`job.create` returns `result.job`. Call `job.advance` with
`{"jobId":"JOB_ID"}` to execute the next saved unit, then summary or export steps. Plugin steps
checkpoint individually for each image or volume frame. Each
advance requires the current project revision and a fresh request ID. Inspect
`result.job.status`, `progress` and `nextUnit` after every call: a committed failure
can return `ok: true` with job status `failed` or `blocked`.

Completed image checkpoints survive application and MCP server restarts.
`job.pause` pauses before the next unit, `job.resume` resumes a paused job,
`job.retry` retries a failed unit, and `job.cancel` cancels remaining units while
preserving completed results. These actions do not interrupt an image computation
already running. `job.list` and `job.get` expose the saved state.

`job.worker.start` runs an existing job in a local background process, advancing
the same durable checkpoints used by `job.advance`. `sweep.worker.start` accepts
`{"sweepId":"SWEEP_ID"}` and uses that worker infrastructure to continue an entire
parameter sweep through `sweep.advance`. `job.worker.list` and
`job.worker.status` report progress and heartbeat state. One worker can own a
project at a time; manual advancement is unavailable while that worker owns the
project. `job.worker.stop` requests a stop after the current checkpoint, preserving
completed work and the requesting actor. It does not kill an arbitrary process.
A revision conflict stops the worker for attention instead of automatically
repeating a scientific operation. Worker records identify `targetKind` (`job`,
`sweep` or `refresh`) and `targetId`; sweep workers report aggregate checkpoint progress.
Resume the paused job or sweep and explicitly start a new worker when ready.
Restoring a package never restarts its workers.

Changing an input, calibration or completed mask invalidates the job's captured
inputs. A blocked job requires a new job using the intended current inputs rather
than silently replacing a correction. Its summary covers the selected images;
an optional ZIP export contains the **complete project**. Repeated exports need
new destinations because existing files are never overwritten.

MCP checks export destinations both when definitions are submitted and before
executing a job saved by any client. Grant the destination with `--allow-path`
if it is outside the configured project. A workflow template may omit its export
destination and supply it when creating the job.

## Branching workflows

Use `workflow.graph.catalogue` to discover supported node schemas and input kinds.
`workflow.graph.preview` validates a graph and returns its normalized node order;
with `imageIds` and optional volume `timeIndices`, it also budgets the job's new
images and checkpoints. This structural preview does not run image analysis.
`workflow.graph.save` saves a named immutable version. Existing linear workflows
and their jobs remain supported.

A graph has one implicit `$source` acquisition input. Preprocessing nodes may
chain and fan out; segmentation nodes consume source or processed pixels and
always create independent image variants. Measurement, assay and measurement
plugin nodes consume a retained analyzed image. All nodes inherit the exact
source selection from their input; a processed input uses channel zero and local
volume time zero. Changing a graph's source selection therefore applies
consistently to each raw branch. Model and plugin nodes freeze the same versions,
parameters and interpreter bindings as ordinary workflows.

For example, save this as `workflow.graph.save` arguments to compare two minimum
areas after one shared smoothing step:

```json
{
  "name": "Two size thresholds",
  "graph": {
    "schemaVersion": 1,
    "target": "plane",
    "sourceParameters": {"channel": 0, "zProjection": "max"},
    "nodes": [
      {"id": "smooth", "type": "preprocessing", "input": "$source",
       "recipe": [{"method": "gaussian", "sigma": 1}]},
      {"id": "small", "type": "analysis", "input": "smooth",
       "parameters": {"method": "otsu", "minAreaPx": 20}},
      {"id": "large", "type": "analysis", "input": "smooth",
       "parameters": {"method": "otsu", "minAreaPx": 80}},
      {"id": "measure-small", "type": "measurements", "input": "small"},
      {"id": "measure-large", "type": "measurements", "input": "large"},
      {"id": "summary", "type": "summary", "inputs": ["measure-small", "measure-large"]},
      {"id": "export", "type": "export", "input": "summary"}
    ]
  }
}
```

For a volume graph use `target: "volume"`, a top-level `channel`, and
`volume-analysis` nodes; select time points when creating the job. Create and
advance graph jobs through the existing `job.create`, `job.advance` and
`job.worker.start` operations. `nextUnit` names the source image/time and node;
`nodeProgress` reports durable completion per node. Independent nodes execute in
deterministic order, one checkpoint at a time. They are not parallel workers.

After a node's input is available, `job.graph.node.preview` accepts `jobId`,
`checkpointIndex`, `nodeId` and optional `maxSize`. Built-in segmentation,
preprocessing and assays calculate a fresh unsaved preview; measurements read
the exact retained mask. The response labels these modes separately and includes
the input binding. Previewing a completed node never replaces its saved result.
Model and plugin nodes require explicit execution rather than a hidden executable
preview.

The summary collects multiple result references
and keeps each branch, original image and time separate. Branches are alternative
analyses of the same acquisition, not independent specimens; no specimen/well,
review or adaptation assignments are copied to their image variants. Optional
export writes the complete project, including branch definitions, exact source
and mask bindings, results and history. A fresh `exportDestination` at job creation
overrides the graph's saved destination.

Limits are 32 nodes, eight segmentation branches, 5,000 scientific node
checkpoints and up to 1,000 selected input image identities per job. Generated
branches also count against the selected project's storage-format capacity. Invalid edges, missing inputs,
cycles and unused branches are rejected before saving. Changes to an input or
completed branch stop further execution; completed branches survive. Explicit
retry of a failed or blocked graph checks frozen dependencies again and cannot
silently adopt corrected inputs. Use the explicit corrected-branch continuation
preview to create a new job while retaining the original checkpoints.

Graph parameter sweeps use `nodeId` and a discovered parameter `path` for each
axis; linear sweeps continue to use `stepIndex`. Each combination keeps isolated
source and branch images. Reports identify segmentation branches separately and
leave pooled graph object totals empty. Budgets include preprocessing outputs,
segmentation variants and every scientific node checkpoint before creating any
variants. Portable distribution sends the complete graph for each image/time
unit and runs it through ordinary graph jobs on the receiving machine.

Explicit union/intersection mask nodes create new connected objects. Paired
N:C and neurite/soma assay ports bind compatible analyzed branches from the same
acquisition. Conditional execution, mixed plane/volume graphs and arbitrary
image merges are unsupported. Summary fan-in does not merge scientific pixels. MCP checks
every frozen model/plugin node and export destination before starting either
foreground or background execution.

## Python SDK

The supported package is `cellcounter-workbench`; import from `workbench_sdk`.
From a checkout, install with `python -m pip install './shared/python[mcp,zarr]'`,
or install its built wheel. This provides the `cellcounter-workbench` executable
and works outside the repository directory. Python 3.11 or later is required.
The Python distribution contains the canonical runtime only; model checkpoints,
model environments and the separately bundled Node engine are not installed by
SDK operations.


Use `WorkbenchClient` from the installed `workbench_sdk` package. The SDK calls the same operation dispatcher
and returns the same structured envelopes as CLI and MCP; it does not implement
another analysis engine.

```python
from workbench_sdk import WorkbenchClient, WorkbenchOperationError

client = WorkbenchClient("/absolute/experiment.ccproject",
                         actor={"kind": "agent", "name": "Local analysis script"})
snapshot = client.inspect()  # Explicitly adopts the observed project revision.
operation = client.prepare("image.import", {"paths": ["/absolute/field.tif"]},
                           request_id="import-field-1")
try:
    response = operation.execute()
except WorkbenchOperationError as error:
    print(error.code, error.details)
    # Decide how to resolve the conflict; the client does not adopt a newer
    # revision or rerun the command automatically.
```

`operations()` returns shared argument schemas and capability metadata. A prepared
operation retains its exact actor, arguments, request ID and expected revision for
an explicit retry after a transport interruption. Successful mutations advance
the client's known revision; ordinary reads do not adopt another writer's newer
revision. `inspect()` deliberately refreshes it. Errors retain the complete failed
envelope. `send()` accepts an exact caller-built request without substituting IDs
or actors. An optional transport callback can carry that same envelope to another
configured host; the SDK itself opens no remote connection and installs no runtime.

## Import an existing CellCounter library

Legacy libraries can be captured without opening a graphical window.
`migration.library.capture` takes `platform` (`windows` or `macos`), an absolute
`sourceDirectory` and a new JSON `destination`. Windows captures a consistent
read-only SQLite snapshot. macOS uses the installed native application to decode
its own SwiftData schema; configure its executable with the CLI's global
`--native-helper` option. Native capture uses fixed arguments and never accepts an
executable path from an imported project. MCP requires write/source/destination
grants and the existing `--allow-plugins` execution grant for the native helper.

Call `migration.library.preview` with the archive `path` and optional `imageIds`.
It reports importable, archived-only and missing image sources, complete evidence
counts and a `previewFingerprint`. Then call `migration.library.run` with the same
path/selection, fingerprint and project name, targeting a **new** project directory.
This retains the exact archive and creates a pending migration. Use
`migration.library.advance` to copy one evidence file or create one image identity
per checkpoint. `pause`, `resume` and `cancel` operate between checkpoints; resume
after a failure requires the original frozen source bytes. Cancellation preserves
completed copies and images. Existing libraries are never modified.

`project.inspect.migration` and `migration.library.get` show progress and any
missing evidence. `completed` means all planned units were traversed; inspect
`evidenceComplete` and `scientificImportComplete` separately. A missing or
unsupported acquisition can remain archived without becoming a usable analysis
image. Original vendor bytes, analysis TIFFs and display projections retain their
separate roles. Display pixels never silently replace a missing analysis source.

Legacy cells and variants contain centres, diameters and optional contours, rather
than authoritative raster masks. `migration.geometry.get` reads those historical
records with `exactMask:false`. It does not turn them into approved references or
invent mask undo history. `migration.records.get` exposes paged original entity
records, including raw settings, ROIs, review history and queued operations;
`migration.evidence.list` pages retained/pending/missing files. No model is enabled
and no old queue is restarted during import. Packages retain this evidence and
restore unfinished migrations paused.

Current migration bounds are 1,000 selected image identities, 10,000 evidence
files, 100,000 records, a 64 MiB record archive, a 16 MiB frozen plan, 512 MiB per
file and 4 GiB total evidence. An explicit image subset still retains the complete
record archive and all available listed evidence. Exceeding a bound returns an
actionable error; it does not silently discard data. Legacy layered workspaces,
semantic paint journals and presentation/animation operations remain archived
records until their separate workspace adapter is available.

## Portable distributed tasks

Distribute a saved workflow by creating one isolated task per selected image or
volume time point. Each task retains the workflow version, source data,
calibration, valid support and required reference inputs. The remote machine runs
the same canonical workflow engine in its own project directory. Transfer ZIP
packages using your preferred file transfer method; these operations do not
configure a cluster scheduler or share a live SQLite project between machines.

In the desktop Workflows task, expand Distributed work to preview the partition,
create tasks and export their packages. Opening a restored task exposes its
preparation controls; after preparation, use the existing Jobs controls to run
or stop it. Returned packages are previewed before collection.

Use `distribution.preview` with `workflowId`, `imageIds` and optional
`workflowVersion`/`timeIndices` to inspect the partition before creating it.
`distribution.create` takes the same selection and an optional `name`, and
returns `result.distribution`. A group contains at most 128 tasks. Call
`distribution.get` with `distributionId` for task identities and collection
status; `distribution.list` returns compact group summaries.

Export an individual task with `distribution.bundle.export`, passing
`distributionId`, `taskId` and a new ZIP `destination`. Like other mutations,
creation and export require the current project revision. Changed coordinator
inputs must be resolved before exporting or collecting the affected task.

For a workflow using built-in methods, run the transferred package on the other
machine with the standalone runtime:

```sh
python shared/python/workbench.py --project /data/task.ccproject distributed-run \
  --package /data/task.zip \
  --result /data/task-result.zip
```

The project directory must be new and its parent must exist. A workflow containing
an export step also needs a separate new ZIP destination supplied with
`--workflow-export /data/workflow-output.zip`. The final `--result` package is
exported after the canonical job completes with current outputs; a failed or
blocked job does not produce a successful result package. Progress is written to
stderr and the final JSON envelope to stdout.

For plugin or learned-model workflows, first use `package.restore`, inspect the
task with `distribution.task.get`, and explicitly configure/enable the required
local executables. Restoration never enables plugins or models. Then run
`distributed-run` against that existing project, omitting `--package`.
Preparation rejects incompatible runtime differences by default. The
preparation-only `--allow-runtime-differences` flag explicitly accepts and records
supported runtime differences; it does not substitute a method, enable code or
skip workflow steps.

The runner prepares an unprepared task once through `distribution.task.prepare`,
then advances its ordinary job. GUI and MCP clients can use that operation
directly with optional `exportDestination` and `allowRuntimeDifferences`, followed
by the existing job or background-worker controls. A prepared task retains its
job ID and settings. Do not repeat preparation-only flags on subsequent runs.
Runtime bindings are immutable after preparation. To change a prepared task's
interpreter or runtime, restore a fresh original task bundle into another new
project, configure that environment and prepare it again. Moving an unfinished
prepared job to a different runtime does not silently rewrite its definition.
Completed packages can still be inspected and collected without executing code.

Ctrl+C requests a stop after the active checkpoint. Continue a paused job with:

```sh
python shared/python/workbench.py --project /data/task.ccproject distributed-run \
  --resume --result /data/task-result.zip
```

Use `--retry` only after resolving a failed job's reported error. After an abrupt
process exit, inspect the retained task before continuing; omit `--package`
because the project already exists. A pending/running job continues its saved
checkpoints, and a completed job can be exported without rerunning its science.
The runner never automatically retries a revision conflict. Every output path
must be new; an existing ZIP is never replaced.

Back in the coordinator, call `distribution.result.preview` with `distributionId`,
`taskId` and the returned package `path`. Review its job, summary and runtime
differences. Submit those arguments plus the returned `previewFingerprint` to
`distribution.result.collect` at the current revision. Collection checks package
integrity, task origin, frozen inputs and workflow, and complete current job
outputs. Changed inputs, foreign results and duplicate collections are rejected.

Collected results remain **isolated result projects** linked to their tasks.
Collection does not replace coordinator masks, copy biological assignments or
combine tasks into biological replicates. `distribution.result.export` publishes
a selected retained result to a new ZIP for restoration and inspection. MCP
uses the same operations, with explicit write, source/destination path and
executable-code permissions where applicable.

## Parameter sweeps

`sweep.parameters` discovers scalar controls from a saved workflow's actual
segmentation, model, plugin, assay and preprocessing schemas. Each candidate
identifies a zero-based `stepIndex` in the complete workflow and a `path`, such
as `parameters.minAreaPx` or `recipe.0.sigma`. Supply axes as
`{"stepIndex":0,"path":"parameters.minAreaPx","values":[9,25,49]}`.
Use `null` only when `canOmit` is true; omission reapplies ordinary defaults.

Call `sweep.preview` with `workflowId`, `imageIds` and `axes`, optionally selecting
`workflowVersion` and volume `timeIndices`. It validates every Cartesian
combination before creating anything and reports required variants, processed
images and checkpoints. Limits are six axes, 16 values per axis, 64 combinations
and 5,000 total image/frame checkpoints, subject to project image, job and
metadata limits. Equivalent combinations after parameter normalization are
rejected. `sweep.create` accepts the same arguments and an optional name.
An export workflow requires an existing `exportDirectory`; each combination
receives a distinct new ZIP destination.

Every combination owns independent image variants, an immutable concrete
workflow and a normal resumable job. Variants are repeated analyses of the same
acquisitions, **not additional biological replicates**. Specimen, well, review
and reference-mask assignments are not copied. Source selections, parameter
values and original-to-variant identities remain recorded in the sweep.

`sweep.get`, `sweep.list` and project inspection report group progress and
currentness. `sweep.advance` executes one canonical checkpoint across the group,
finishing analysis and summary units before complete-project exports.
`sweep.pause`, `resume`, `retry` and `cancel` preserve completed results.
Inspect the returned group and job status after each mutation; a committed
computation failure can return `ok:true` with a failed job. Use
`sweep.worker.start` to continue the whole sweep in the background, or
`job.worker.start` for one combination. The group must be pending or running
with current inputs; resume or retry eligible jobs explicitly before starting.
Use `job.worker.stop` with the returned worker ID to pause after the current
unit, preserving completed combinations. It uses a durable stop marker rather
than competing with the active computation for its project revision.
MCP checks the export directory and each remaining job's immutable workflow
before group advancement or worker launch, including the executable-code grant
for model and plugin nodes. The worker binds the frozen sweep and child workflow
definitions and rechecks them between units.

`sweep.results` compares saved scientific checkpoints, with one row per
combination and input image/frame. It reports object count, foreground samples,
mean object size, calibrated size when known and mean object intensity. These
describe the outputs; they are not accuracy scores. Mean intensity gives each
object equal weight, and different channels or preprocessing recipes may change
its interpretation. Object observations across time can count the same tracked
cell more than once.

The comparison retains pending, incomplete, changed and unavailable input rows
with explicit reasons and empty metrics. A combination total becomes available
only when all its input rows have current results; partial counts are labelled
as available observations. Scientific checkpoints can be complete while a job
still awaits its summary or export. The API returns every combination summary
and paginates input rows with `offset` and `limit` (up to 500). Reports are bounded
to two million object observations.

Use `sweep.export.catalogue` and `sweep.export` to save complete JSON comparisons
or input-level CSV tables, independently of the page displayed in the GUI.
Exports retain the frozen sweep definition hash, result snapshot, source/label
references and provenance. They include missing and changed input rows, with
empty CSV values instead of fabricated zeros. Export files are bounded to
16 MiB and never overwrite an existing destination.

## Experiments and biological replicates

Create specimens with an experiment, condition and control/treatment role. Assign
each image to its specimen, optionally adding a plate, well row/column and field
identifier. Different acquisition files remain separate images even when their
pixels are identical. The project shares their stored source bytes.

`specimen.set`, `plate.set`, `image.assign` and `image.unassign` expose the same
organization controls to CLI and MCP clients. `experiment.get` reads the design.
`experiment.summary` reports per-specimen observations and gives each complete
biological specimen equal weight within its experiment and condition.

Incomplete specimens are listed and excluded from condition aggregates. Physical
area summaries require every assigned image of a specimen to be analyzed and
calibrated. Images and objects are never counted as biological replicates. Counts
per image are descriptive; they do not correct for differences in field area or
sampling design.

`assay.metrics` lists numeric image-level metrics in a saved assay.
`experiment.assay.summary` uses a current reference run and a metric path to
collect compatible current results across specimens. Compatibility includes the
assay settings, source processing, units, projection and selected volume frame.
The summary shows image contributions and exclusions, averages images within
each complete specimen, then gives specimens equal weight within a condition.
Restricting the image selection does not turn a partial specimen into a complete
one. Time points remain separate and are not treated as biological replicates.

## Saved data and export

A project folder contains `workbench.sqlite` and content-addressed files in
`artifacts/`. Keep both together. Imported source bytes are preserved, and
measurements use source intensities rather than the displayed preview.
Processed images explicitly identify their transformed intensity units and retain
their preprocessing recipes.
Object measurements come from the saved label pixels, not their display contours.

`project.export` writes a scientific snapshot with source data, exact label
arrays, correction history, measurements, tracks, workflows and provenance.
New indexed projects use the [streamed Package2 format](#large-libraries-and-streamed-packages);
older projects retain their compatible analysis ZIP format. Package structure and
limits depend on that format, rather than the visible library page.

The package's `sourceRevision` identifies the exported snapshot; recording the
export advances the live project's revision once. Existing ZIPs are never
overwritten. `package.inspect` verifies package metadata and reports dependencies;
Package2 artifact bytes are verified during restore. `package.restore` reopens it
into a new project directory, retaining source data, masks, workflows and history.
The restored project gets a new ID.
It never overwrites an existing project, installs dependencies or starts code.
Restored executable plugins and model bindings require explicit enabling.
Unfinished training and analysis workers are marked interrupted; their processes
are never restarted by restoration. Training optimizer state is not resumed.
Retain the original project folder as well as any exported package.

`image.export.catalogue` lists built-in single-image exports. `image.export`
writes full-resolution instance labels, selected source pixels or the valid
support mask as calibrated OME-TIFF, current scalar object measurements as CSV,
or a bounded PNG display overlay. Source exports preserve native pixel dtype;
a mean Z projection uses floating-point values to retain fractional intensities.
Label TIFFs retain their exact uint32 identifiers, with zero as background.
An overlay is a display image, not an instance-label file.

Choose a saved plane analysis or an explicit volume time/channel selection.
Labels, measurements and overlays use the saved analysis's source selection.
Source/support exports can select a channel and projection independently.
Exports retain their file bytes, source provenance and SHA-256 hash in the
project. Every destination must be a new file; an existing file is never replaced.

## Plugins and local learned models

Install a local manifest with `plugin.install`, inspect its retained version with
`plugin.inspect`, and explicitly enable it with `plugin.setEnabled`. Each version
keeps the exact manifest and Python source. Manifest parameter schemas generate
the desktop controls and validate CLI/MCP arguments. Supported kinds are
segmentation, measurement, reader and exporter.

`plugin.run` applies a segmenter or measurement method to the selected plane or
volume. Segmentation must return exact integer labels matching the source shape.
Measurement outputs retain their source and mask dependencies; `plugin.results`
reports whether later changes made a result stale. `plugin.read` preserves the
original input and imports a reader's validated pixel output as a canonical TIFF.
`plugin.export` retains the exported file and writes to a new destination without
overwriting existing files.

Each plugin invocation records the Python/package metadata observed inside its
actual isolated subprocess. A launcher preserves the plugin's existing two-file
argument protocol; plugins do not need to add inventory fields to their
scientific response. The project retains an immutable inventory reference with
segmentation, measurement, reader and exporter provenance, including paired
plugin evaluations. The parent application's inventory is recorded separately
where relevant and is not assumed to match the isolated child.

`model.catalog` describes the `cellpose3` and `cellpose4` backends, their inference
parameter schemas and training availability. `model.register` requires an explicit
backend, local checkpoint path and local Python executable. It retains the exact
checkpoint bytes and hashes the interpreter; `model.configure` changes the binding
or enabled state. `model.probe` checks the installed Cellpose major version and
required inference API without loading the checkpoint. The shared runtime does
not install dependencies or download substitute weights.

`model.environment.capture` records the registered interpreter's observed Python
version, platform and installed distribution names/versions. It is an explicit
project mutation with `modelId`, the current revision and executable-code
permission. It invokes the trusted interpreter without loading the model or
importing its scientific packages. The immutable inventory is saved with its hash
and interpreter binding. `model.environment.get` reads the active record and
history; pass an optional `environmentId` to inspect an older inventory.

The model controls distinguish a compatibility probe from **Capture environment**.
Capture saves a requirement for subsequent execution. When an environment is
bound, inference and training compare the observed inventory before running;
package or Python changes require an explicit new capture. Rebinding a model's
Python path clears the active environment binding while retaining its history.
Previously saved workflow jobs keep their frozen environment requirement. Create
a new workflow version/job when a changed environment is intended.

Models without a captured binding remain explicitly unrecorded until capture.
Their runs retain the observed inventory, but do not enforce a previously saved
one. Inventories include at most 4,096 distribution records and do not contain
environment variables, package download URLs or installation paths. They are
metadata records, not installable lockfiles: identical inventories do not prove
identical editable source, installed binaries, system libraries, GPU drivers or
numerical results. No dependency installation is performed.

`model.run` analyzes one selected 2D channel and Z projection and saves exact
source-resolution labels. Cellpose 3 uses `diameterPx`, defaulting to 30 pixels.
Cellpose 4 / Cellpose-SAM uses optional `rescaleDiameterPx`: omit it for native
scale, or supply it as a resize hint. It is not an estimated cell diameter.
Parameters are validated against the selected backend's `inferenceSchema`;
Cellpose 4 rejects the Cellpose 3 `diameterPx` control. Both expose flow and cell
probability thresholds, minimum object area and device selection. Saved workflows
freeze these controls with the checkpoint, interpreter and backend identifiers.

Cellpose 3 checkpoints are limited to 512 MiB; Cellpose 4 checkpoints may be up to
2 GiB and are copied and hashed as streams. Legacy analysis ZIP restoration permits
this larger member only when the project explicitly identifies it as a retained
Cellpose 4 checkpoint, or the exact retained micro-SAM primary checkpoint described
below. Legacy packages remain limited to 2 GiB compressed and 4 GiB expanded.
Current indexed projects use [Package2's streamed limits](#large-libraries-and-streamed-packages).

Approve reviewed masks using `adaptation.reference.set` and assign their images
to biological specimens. `adaptation.suggest` proposes a mixture of diverse and
heuristically difficult images. `adaptation.dataset.create` freezes source
planes and labels with separate train, validation and held-out test specimens.
Previously held-out specimens and source contents cannot be moved into a later
training/validation split through this interface.

`adaptation.evaluate` compares two enabled segmentation plugins on the same
frozen test inputs. The local workflow cannot establish how externally supplied
plugins were trained. `adaptation.train.start` starts Cellpose 3 adaptation in a
local worker; Cellpose 4 currently supports inference only and is rejected for
shared training. List/status/cancel/collect operations expose progress, request
cancellation and retain the completed checkpoint/report. Validation selects the
checkpoint; held-out predictions are retained separately. Reviewing test results
repeatedly can influence later model choices, so the evaluation history is kept.

## Preprocessing, independent masks and assays

`preprocessing.catalogue` describes filter controls and dimensional support.
Build an ordered recipe, preview it, then call `preprocessing.run` to create a
new image. Available filters include Gaussian smoothing, median filtering,
rolling-ball background subtraction, CLAHE, percentile normalization and
edge-preserving diffusion. Constant subtraction, white top-hat correction,
unsharp masking and Richardson–Lucy deconvolution support planes and volumes.
Deconvolution uses an explicitly synthetic Gaussian point-spread function
specified in pixel/voxel units; it does not infer measured optics. Its input must
be nonnegative, and computation is bounded by sample, iteration and kernel
budgets. Unsharp masking can retain negative overshoot. Filter descriptions
record these intensity transformations and boundary policies.
Supported dimensions and allocation limits are explicit.
`preprocessing.inspect` shows retained lineage and parameters.

`image.duplicate` creates an independent mask layer sharing the same immutable
source pixels. Set `copyAnalysis:true` to start from current masks; future edits
remain independent. Reference approvals, tracks and review decisions are not
copied. This also supports separate nuclear and whole-cell masks on one source.

Use **Import object labels** to preview an external integer TIFF or NPY mask,
then apply it to the selected plane or volume. `mask.import.preview` and
`mask.import.run` expose the same flow to CLI and MCP clients. The preview returns
a fingerprint; pass it when applying to detect changes to the file, source,
calibration or existing mask since preview. Dimensions and source selection must
match exactly. Label identifiers are preserved, zero denotes background, and
unsupported-fill labels are rejected. Empty masks are valid and remove current
objects from that selection. Applying retains the original input, updates
measurements and supports the ordinary mask undo operation.

`mask.compare` compares two current saved layers on the same acquisition,
coordinate grid and valid support. Plane comparisons also require the same
saved Z projection. It reports foreground Dice/Jaccard agreement and object
matches at IoU ≥ 0.5, with unmatched labels and a disagreement overlay. Neither
layer is assumed to be ground truth. Volume scores cover the entire selected
time/channel volume; the overlay shows one chosen orthogonal slice. Response
lists are bounded to 1,000 matches or unmatched IDs each, while totals cover
every object.

`assay.catalog` lists morphology, 3D surface/shape, fluorescence, spatial
neighbourhoods, marker positivity, reporter-positive cells, colocalization,
live/dead classification, DNA-content estimates, nuclear:cytoplasmic intensity
and puncta measurements. Each assay declares its dimensions and controls.
`assay.preview` calculates without saving; `assay.run` retains output and exact
input dependencies. `assay.results` marks outdated results and
`assay.recompute` creates a new result using current inputs, preserving the old
one. Nuclear:cytoplasmic analysis requires independent masks with the same source
bytes and Z projection.

3D surface area uses a closed marching-cubes mesh with independent axis spacing.
Objects touching acquisition boundaries are flagged. Surface extraction has a
bounded per-object and total voxel budget; it does not silently downsample
scientific masks. Biological interpretations of assay thresholds remain the
researcher's responsibility.

## Refreshing results after corrections

Mask edits and calibration changes recalculate the canonical measurements of the
saved labels. Saved downstream assays and measurement-plugin results retain their
original inputs, so later changes can make them stale. Use **Saved result
freshness** under Measurements to inspect the current image or the project,
review the reasons and prepare a refresh plan.

`refresh.inspect` accepts optional `imageIds` and `includeHistory`. By default it
shows the latest logical analyses, with current, stale or blocked status. A
changed paired reference, such as a nuclear mask used by a nuclear:cytoplasmic
assay, is a dependency change even when the measured image's own mask is unchanged.
The default transitive plan includes supported processing, tracking, lineage,
assay/plugin-measurement and statistical dependencies in order. It reapplies stored
registration transforms rather than estimating new alignment and does not rerun
segmentation. See [refreshing a dependency chain](#refreshing-a-dependency-chain)
for mask-transfer rules and blockers.

For a narrower measurement-only plan, the shared GUI/CLI/MCP sequence is:

1. Call `refresh.preview` with `dependencyMode: "measurements"` and optional
   `imageIds`. It selects the latest logical stale assays and measurement-plugin
   outputs. To choose particular saved runs,
   provide `runRefs` entries with `kind` (`assay` or `plugin-measurement`) and
   `runId`. `includeCurrent:true` explicitly allows recalculating current results.
2. Review the selected work, blocked items and the returned `previewFingerprint`.
   Submit the same selection and dependency mode to `refresh.create` with that
   fingerprint, the current revision and an optional `name`. Blockers prevent creation unless
   `skipBlocked:true` is explicitly supplied; skipped items remain in the plan.
3. Use the returned refresh ID with `refresh.advance` to complete one checkpoint,
   or `refresh.worker.start` to run remaining checkpoints in a local background
   worker. `refresh.get` and `refresh.list` expose saved progress.

Each plan freezes the current source, labels, calibration, support and reference
inputs, together with its method and runtime bindings. The original assay or
measurement-plugin engine calculates each replacement. Original results remain
available, and replacement links record what was refreshed. This flow does not
run segmentation or overwrite existing exported files. Executable measurement
plugins still require explicit trust and the corresponding MCP permission.

`refresh.pause`, `refresh.resume`, `refresh.retry` and `refresh.cancel` preserve
completed checkpoints. For an active background worker, use the existing
`job.worker.stop` action to request a checkpoint stop. Resume requires the frozen
inputs and runtime to remain current; changed inputs need a new preview and plan.
Retry applies to a failed checkpoint after resolving its error, and never
repeats completed checkpoints. A project supports at most 100 refresh jobs with
256 selected units per job.

`refresh.results` reads a full report without recalculating science.
`refresh.export.catalogue` and `refresh.export` publish the report as JSON or CSV
to a new file. Reports retain previous/replacement result identities, exact
dependencies, method/runtime bindings, currentness and skipped blockers. CSV
contains one row per checkpoint or skipped blocker, with JSON columns preserving
the complete records. A finished selected plan has `executionComplete:true`;
`coverageComplete` additionally requires current outputs and no skipped blockers.
An old exported report remains a historical snapshot and must be exported again
to a new destination when an updated report is needed.

## Annotations and intensity profiles

Save points, lines, polylines and simple polygons independently of cell masks.
Annotations can use a 2D channel/projection or an explicit orthogonal slice in
a volume. Vertices use source pixel-edge coordinates. The desktop editor
supports drawing, numeric vertex edits, names and notes.

`annotation.save`, `annotation.list`, `annotation.get`, `annotation.delete`
and `annotation.undo` retain editable geometry and reversible history.
`annotation.measure` reads a saved annotation or accepts draft geometry.
Measurements use the current independent axis calibration; missing spacing
leaves physical distances and areas unknown. A measurement-channel override
samples the same geometry without changing its saved display selection.

Polygon geometry reports continuous area and perimeter, while intensity
statistics use acquired pixel centres inside the polygon. Line profiles use
bounded bilinear interpolation along pixel-space arc length. Samples requiring
unsupported pixels or extrapolation remain missing. The profile display keeps
these gaps and exposes individual sample coordinates and values. Processed
intensities retain their processed-source units.

Polygons must have a simple boundary without crossings, repeated consecutive
vertices or overlapping edges. The runtime bounds annotation counts, vertices,
polygon work and profile samples; its operation responses report those limits.
Saved annotation revisions and source/support references are retained in analysis
packages.

`annotation.export.catalogue` describes three formats available through desktop,
CLI and MCP. `annotation.export` publishes one saved annotation as geometry JSON,
measurement CSV or line-profile CSV. Save edited geometry before exporting.
Geometry JSON retains exact local pixel-edge coordinates, source selection,
revision history and calibration. It uses the CellCounter annotation format.
Measurement CSV recomputes geometry and intensity statistics with current
calibration and the chosen measurement channel. Profile CSV includes each
zero-based sample index, source coordinates, pixel and calibrated arc distances,
intensity and a `valid` column. Missing intensities remain empty with `valid=0`;
measured zero intensity has `valid=1`.

Exports retain the exact geometry revision, file and provenance hashes in the
project and analysis packages. Existing destination files are never overwritten.
MCP export destinations must fall within the project's path grants. CSV string
values that could be interpreted as spreadsheet formulas receive a leading
apostrophe.

To transfer saved geometry, choose a CellCounter annotation JSON file and inspect
its compatibility summary. `annotation.import.preview` checks the source hash,
dimensions, acquired support, selection, geometry and provenance. Import requires
the exact source pixels and grid. It accepts calibration differences explicitly;
the target image's calibration remains authoritative and coordinates are
unchanged. `annotation.import.run` requires the returned `previewFingerprint`,
so changing the file, source, support or calibration requires a new preview.

Imports create a new annotation ID and a local import event. The original file,
its hash and its external history are retained as evidence in the project and
analysis packages. External history is not replayed as local user activity.
Import files are bounded to 2 MiB and must be regular UTF-8 JSON files. MCP
imports use the same source-path grants as other file imports.

## Review and quality control

`review.flag` records satisfactory analyses or those needing review.
`review.session.create` freezes a deterministic random sample of images/frames
or detected cells, optionally restricted to apparently satisfactory analyses.
It retains exact source and label inputs. Cell-only sampling cannot reveal
objects missed by every detector.

The review desk uses anonymous sample codes. A declared reviewer records
accept/reject/uncertain decisions and an error category. Earlier decisions remain
in history. Required independent reviewers can disagree; `review.adjudicate`
records a resolved judgment and reason. These are declared local identities,
not authenticated accounts.

Blinded sessions withhold other decisions before a reviewer's own submission.
Aggregate outcome summaries stay hidden until `review.reveal` explicitly records
the end of blinding. Project owners and exported packages still retain source
identities; blinding applies to the review presentation.

`review.summary` reports workload, disagreement, rejected sampled units and
changed inputs. After reveal it includes descriptive rejection intervals and
agreement fractions. These are not segmentation-accuracy benchmarks or
biological-replicate statistics. Corrections mark affected samples stale; their
retained views remain available, and a new sample can capture the revised inputs.

## Large TIFF sources and regions

Large TIFFs can be retained separately with `source.import` without decoding an
entire image plane into memory. `source.list` and `source.inspect` report access
capabilities. `source.overview` returns a bounded display and an explicit mapping
to original pixel coordinates. The desktop overview supports rectangle selection;
numeric coordinates specify exact regions.

`source.extract` copies an original-resolution XY region from an explicit stored
page and channel into an ordinary analysis image. The result retains its source
ID/hash, pixel rectangle, physical origin where known, original dtype and raw
intensity values. Regions are limited to 16 million pixels.

This reader currently uses the first TIFF series and explicit stored pages;
page numbers are not interpreted as biological Z or time coordinates. It uses
read-only memory mapping or selective tile/strip decoding. Each decoded segment
must fit within 32 MiB; a large compressed single strip may require conversion
to a tiled or uncompressed TIFF. Retained source files remain limited to 512 MiB.
Extracting regions does not perform whole-slide segmentation or reconcile
objects across adjacent region boundaries.

## Translation registration

`registration.estimate` estimates a 2D translation between explicit channel,
time and Z-projection selections. Equal input grids are required for estimation;
a known translation can also be entered directly. `registration.preview` shows
the reference, translated moving image and overlay. `registration.apply` saves
a derived image in the reference grid with its transform, interpolation,
calibration and exact valid-support mask.

Segmentation and measurements exclude unsupported fill. Smoothing propagates
the support mask and conservatively excludes neighborhoods affected by fill.
Algorithms requiring complete neighborhoods operate on an entirely supported
rectangular crop; irregular support may require a different processing choice.
Support is retained in processing provenance, model adaptation inputs and
analysis packages.

Positive X moves pixels right; positive Y moves them down. Nearest or linear
interpolation is supported. Source images are retained and existing object masks
are not transferred. `registration.inspect` reports the saved derivation.
Estimation is bounded to four million pixels; application permits sixteen
million output pixels and twenty-four million combined input pixels.

## Acquisition library metadata and repair

`image.metadata.get` and `image.metadata.set` manage names, notes, tags and one
explicit name per indexed source channel. Channel names are descriptive labels;
they never remap source indices or infer fluorophore equivalence. `library.search`
provides paged text/tag/collection search with `active`, `archived` or `all`
visibility. `collection.save` maintains named memberships without implying
experimental replicates. `image.archive` and `collection.archive` are reversible
through `archived:false`; they preserve acquisitions, assignments, measurements
and provenance. Scientific summaries continue to include explicitly assigned
images irrespective of their library visibility.

`library.duplicates` groups exact retained file hashes. Different acquisitions,
blank controls and analysis variants remain separate identities; nothing is
merged automatically. This is byte identity, not a claim about similar decoded
pixels or biological equivalence.

For a missing or corrupt retained source, call `image.relink.preview` with an
original file, then `image.relink.run` with its preview fingerprint and current
project revision. The candidate must match the original source SHA-256 exactly.
Different pixels require a new acquisition. Repair preserves masks, calibration
and assignments, retains displaced corrupt bytes as evidence and records the
source location. Publication and metadata recovery use the same durable project
transaction boundary as exports. Relinking to an intact source only records its
location. Format1 projects retain their 1,000-acquisition bound; indexed format2
supports up to 100,000 acquisitions with paged readers. This is a supported limit,
not a measured performance claim.

## Shared project sessions and agent navigation

### Task navigation in current source builds

The unified task navigation described here is available in current source builds.
The published macOS 1.1.0 / Windows 1.3.0 downloads and Python 0.1.0 wheel predate
this addition. Check `capabilities` or `operations.discover` for
`navigation.catalog` before using it with an installed runtime.

`navigation.catalog` is a read-only operation that does not require a project.
It returns the same six task IDs used by the desktop hosts, with canonical
operation references and their revision, execution and network requirements.

| Task ID | Navigation label | Main tools |
| --- | --- | --- |
| `preparation` | Images | Import, catalogue, calibration, preprocessing, registration and layer workspaces |
| `segmentation` | Segmentation | Models, model adaptation, plane/volume segmentation and exact-label corrections |
| `measurements` | Measurements | Assays, annotations, tracking, lineage and statistics |
| `review` | Review | Quality control, comparisons and review decisions |
| `workflows` | Workflows | Experiments, plates, graphs, sweeps, jobs, distribution and result refresh |
| `export` | Results & export | Summaries, exports, portable packages and project storage |

From the repository root:

```sh
python3 shared/python/workbench.py call navigation.catalog
```

Task assignments appear as `navigationTask` in operation discovery. An operation
without an explicit task remains discoverable and has no inferred destination.
Use `operations.discover` for exact argument schemas and capability-specific
inspect/probe operations for readiness. MCP adds the connection's current access
requirements to the catalogue; task discovery never grants write, network or
executable permissions.

Graphical sessions can publish an optional `selection.task` using one of these
IDs. A task-only update or navigation request preserves the selected image,
channel, time point, orthogonal slice and layer workspace. An applied
acknowledgement validates the complete resulting selection; unavailable spatial
context must be resolved rather than silently marked current. Requests from
older clients that omit `task` retain their spatial replacement behavior and
preserve any task already recorded by a newer client.

After reading `session.list` and `session.get`, an agent can request a task using
the host's current session revision and the current project revision:

```sh
python3 shared/python/workbench.py --project /absolute/experiment.ccproject \
  call session.navigate --request-id show-review-1 \
  --args '{"sessionId":"graphical-session-id","expectedSessionRevision":3,"observedProjectRevision":8,"selection":{"task":"review"}}'
```

The request changes no scientific result. The host reports whether navigation
was applied, deferred or refused. Pending task-only requests keep the requested
`{"task":"review"}` selection, so a host can distinguish task navigation from
a request to replace spatial context and preserve in-progress drafts.

### Project changes and session revisions

`project.changes` reads committed project effects after `afterRevision`. Its
`nextRevision` is the next cursor; consume further pages while `hasMore` is true.
When `resetRequired` is true, read `project.snapshot` and restart at that snapshot's
revision. An unchanged request reads only the indexed project revision. Events
record the actor and operation, with separate source, label, calibration and
metadata effects per affected image. Display settings and client drafts are not
scientific changes. Desktop clients use this cursor in their existing refresh
lifecycle, preserving drafts and reporting genuine revision conflicts.

`session.open` registers a local client; `session.update` publishes its selected
image, channel/time/slice or layer workspace. Session writes use
`expectedSessionRevision`, independently of scientific revisions. Selection
writes also require `observedProjectRevision` so stale coordinates cannot be
silently adopted. `session.list` and `session.get` let agents discover these
selections without screenshots. A stale record reports `selectionCurrent:false`
and unknown `selectionAvailable` until its owner publishes a current selection.
Sessions and navigation records are host-local coordination data and are not
included in analysis packages. Actors and client kinds are self-declared; these
fields are not authentication or proof that a client is still running.

An agent can explicitly call `session.navigate` for a concrete graphical session.
The host acknowledges through `session.navigation.ack`, with `applied`,
`deferred` or `refused` and an optional reason. Applying changes the visible
selection only after current identity and revision checks; draft conflicts can
be deferred or refused. Ordinary scientific operations never request navigation.
Close finished clients through `session.close`. Session operations advertise
`affectsProjectRevision:false`, and the Python SDK does not adopt their response
revision as permission to overwrite scientific changes made by another client.

`resource.report` gives observed Python/package versions, CPU counts, available
host capacity fields and configured microscopy runtime identity. Unknown fields
remain unknown. CUDA and MPS are explicitly unprobed; the report loads no model
or GPU framework and does not claim acceleration from installed package names.

## Layer workspaces and semantic journals

`workspace.catalogue` describes the installed shared microscopy runtime. Layer
workspaces live in the same project and package as scientific acquisitions.
`workspace.create`, `workspace.import.preview` and `workspace.import.run` create
versioned documents. Imports retain the original portable or native JSON;
unresolved raster layers require an explicit `workspace.source.bind` to a saved
image and channel, projection or exact time/Z slice. A filename in an old layer
is never interpreted as an authoritative source path.

`workspace.layer.add` and `workspace.layer.update` manage explicit image or
instance-label layers, visibility, blending, display windows and presentation
transforms. These controls leave scientific source pixels and saved instance
masks unchanged. `workspace.layer.preview` returns an untransformed source-grid preview for direct
journal editing, with full source dimensions and separate display dimensions.
`workspace.preview` uses the existing shared microscopy
composition engine. `workspace.replay` runs its saved closed layer operations,
including registration and stitching, and retains generated planes with valid
support and source bindings. Generated workspace planes remain explicit workspace
artifacts; they are not silently substituted for a scientific acquisition.
`workspace.undo` preserves the previous document as a new version.

`semantic.render` retains uint16 **class** labels and a TIFF from a paint journal;
class values are not cell-instance IDs. Native journals retain their original
bytes, but their old interpolated-disk brush and the shared capsule brush can
produce different boundary pixels. Source-grid mismatches are rejected instead
of rescaling strokes. `pointlineage.build` associates saved point observations;
it is separate from segmentation-object volume tracks. `animation.render`
retains a presentation GIF from a saved plan. Fixed plane bindings cannot supply
other time, Z or channel positions implicitly. Raw-volume bindings can explicitly
follow workspace time, Z and channel axes. Keyframe positions select actual
source indices; animation playback seconds do not invent acquisition timing.

`workspace.zarr.add` and `workspace.zarr.bind` bind a registered local NGFF source,
chosen multiscale array and exact level-pixel ROI. Both supported NGFF generations
use the maintained Python reader. Source-position browsing reads bounded planes
without creating a new acquisition for every view. Source calibration remains
unknown when it is not recorded. Previously retained read ranges are hash checked;
metadata-only listings report external freshness as unverified until those ranges
are used. An overview level remains explicitly identified by its array and ROI.

`workspace.materialize.preview` and `workspace.materialize.run` turn an eligible
retained generated intensity plane into an independent scientific image. A
successful preview binds the exact workspace version, coordinate identity,
calibration, acquired support and every source parent. Display transforms are not
silently resampled. Original images, masks and specimen assignments remain
independent; class labels are never promoted into cell instances. Recomputing a
generated image uses the frozen shared layer operation and its retained parents.

`workspace.get` exposes the complete document for structured editing;
`workspace.document.set` validates a replacement JSON document and retains source
bindings only for unchanged layer identities. `workspace.document.update` provides
a bounded inline draft alternative with an explicit workspace version;
`workspace.layer.samples` supplies exact bounded source-grid values to the shared
semantic/vector editor. `workspace.output.list` reports
retained render artifacts and currentness. `workspace.export` writes a portable
workspace, and `workspace.output.export` publishes an exact retained artifact to
a new destination. Analysis packages preserve original documents, immutable
versions, source bindings, semantic outputs and generated support masks.

Installed applications use their bundled Node 24.22.0 microscopy runtime.
Standalone commands explicitly supply `--microscopy-node /absolute/node` and
`--microscopy-runtime /absolute/runtime` before the command. The runtime manifest
pins the worker and all engine files; no project can nominate executable code,
and no operation installs a runtime. Metadata reads and retained-output export
do not require Node. Layers requiring unsupported native frame-visibility rules
must remain in the original workspace until an explicit compatible conversion
is available. The adapter rejects raw values or instance IDs that cannot be
represented exactly by the existing float32 layer engine.

## Paged project libraries and storage

`project.snapshot` returns compact project catalogues and only the requested image
IDs. `image.list`, `image.get`, `project.history` and `measurements.page` provide
bounded library, selection, history and object reads. Page cursors bind the saved
project revision and filters. After a revision change, start a new page sequence;
never rebase an unsaved edit using a stale cursor.

The desktop image browser retains explicitly selected IDs across search pages.
Batch, sweep, distributed and review scopes use those IDs rather than treating a
visible page as the entire library. Saved mask overlays remain independent of
measurement pages. `mask.pick` reads the exact source-grid label, and
`measurements.lookup` retrieves selected object records without scanning every
page. Masks are corrected by authoritative label IDs even when their table rows
are on another page.

New indexed projects use storage format 2. The project storage controls can
preview an existing format-1 upgrade and apply that exact preview. A host-local
original-store recovery copy and its hash are retained. Scientific sources and
masks are not recalculated by this migration.

Indexed packages retain a snapshot plus bounded artifact shards. Inspection
verifies the snapshot metadata; restoration verifies each shard and artifact.
`package.restore.start`, `.get`, `.advance`, `.cancel` and `.resume` expose durable
restore checkpoints in a new destination. Partial destinations are not open
scientific projects. The desktop can restore one checkpoint or continue while
open, stop after a checkpoint, reopen a retained destination and explicitly open
the completed project. Retained model/plugin code stays disabled on restoration.

Desktop layer editing now uses the canonical project Workbench and the same
shared editor. Original library workspace documents remain available through the
read-only archive reader and previewed import-copy flow. The standalone browser
editor retains its existing local-preview capabilities and is not an installed
scientific runtime.

## Current scope and troubleshooting

This shared runtime supports CPU-based classical 2D thresholding and watershed,
and true 3D Otsu/manual thresholding and watershed,
including channel selection and max, mean or middle-plane Z projections. It
supports TIFF, PNG, JPEG and BMP, up to 32 channels, 16 million pixels per analysis
plane, 20,000 objects, 512 MiB source files and 256 MiB decoded data. TIFF support
requires one series with a supported axis layout. Time series use explicit
time selection in the volume operations; 2D projection operations reject them.
Each selected scientific volume is limited to 8 million voxels. Automatic
tracking is limited to 2,000 objects per frame.

Supported OME metadata supplies independent spatial calibration and time interval
when available. Anisotropic XY spacing supports area measurements; the legacy
pixels-per-micrometre value is populated only for isotropic XY. Unknown Z
spacing is never inferred from XY. Volume summaries report object observations
per time/channel frame separately from 2D objects. Biological-replicate count
summaries cover 2D analyses; assay summaries also support compatible results from
one explicitly selected volume frame.

General conditional workflow execution and cluster scheduling remain outside
the shared workflow's current scope. Supported graph mask merges use explicit
compatible-source union/intersection semantics; temporal division suggestions
remain inferred until reviewed. Declared biological-replicate inference is
available through the statistical design and result operations below.
Training and analysis batches have local background workers. Portable distributed
tasks use explicit package transfer and retain isolated result projects; they do
not provide a remote queue or merge results into coordinator masks. These limits
describe the shared workbench, not every feature of the other application workspaces.

- **`revision-conflict`:** inspect or refresh the project, review the current
  result, then submit the intended change with its current revision and a new ID.
- **`request-conflict`:** use the original unchanged request for a retry, or a new
  ID for a different operation.
- **`runtime_unavailable` or missing scientific dependencies:** install
  `requirements-analysis.txt` into the Python environment launching the command.
  A missing MCP SDK requires the separate optional requirements file.
- **`permission_denied` over MCP:** inspect the server's configured project,
  `--allow-write` setting and allowed paths.
- **Unsupported image or size:** export a supported series, channel or timepoint
  from the acquisition software. The capabilities response lists current limits.
- **Artifact integrity error:** restore an intact project backup. Do not replace
  files inside `artifacts/` or edit the SQLite state manually.

### Experimental designs and statistical reports

`statistics.catalogue` describes supported outcomes, typed design fields and
inference settings. Define categorical factors with declared levels and reference
levels, or numeric factors with explicit units. Each design row names one saved
biological specimen. `subjectId` links distinct specimens from the same subject;
`blockId` identifies a declared experimental block. These identities are never
inferred from image names. Exclusions require reasons and remain in the input
report.

Use `statistics.design.preview` before `statistics.design.save`. The preview
resolves current saved object measurements or a compatible scalar from
`assay.metrics`, averages image values equally within each specimen, and freezes
sources, labels, calibration, assignments and assay references. Every assigned
image of an included specimen must be measured. Missing calibration, stale
results, incompatible selections, or multiple variants/ROIs of the same
acquisition block inference rather than silently increasing sample size.
Archive visibility does not change experimental membership.

`statistics.preview` calculates a declared analysis on a current frozen input
table; `statistics.run` retains the exact preview using its fingerprint. Supported
methods are independent Welch contrasts, complete paired-subject t contrasts,
and a typed linear model with categorical/numeric main effects and selected
two-factor interactions. Pairing requires exactly one sample at each contrasted
level for each subject. Linear models reject rank-deficient, saturated or severely
ill-conditioned matrices. Optional subject/block fixed effects are ordinary
linear-model terms, **not a general mixed-effects or repeated-measures model**.
Classical or HC3 covariance is explicit. Residual independence and the sampling
assumptions remain the researcher's responsibility.

Categorical coefficients use the declared reference level. Linear-model
contrasts compare two levels while holding other categories at their reference
and numeric factors at observed specimen means; with interactions this is a
conditional effect, not a universal main effect. Results preserve coefficients,
effect sizes, residual degrees of freedom, model status, fitted/residual tables,
pointwise confidence intervals and a declared Holm, Benjamini–Hochberg or
unadjusted result family. Multiplicity adjustment applies to p-values; intervals
remain pointwise. Zero observed variance produces an explicit unavailable test
rather than a claim of certainty. Nonparametric, permutation and mixed/random
effects methods are outside these operations.

`statistics.get` exposes the retained result and input table. Later corrections
or assignment changes mark affected results stale. `statistics.recompute.preview`
and `.run` resolve the same design against current measurements and retain a
replacement linked to the predecessor; they never alter saved masks. Each run
also records its re-execution descriptor for downstream refresh.

`statistics.export` publishes complete JSON reports, specimen CSV tables, effect
CSV tables or vector SVG effect plots to a new destination. SVG rendering uses
the optional pinned `requirements-reporting.txt` dependency (`pip install
'cellcounter-workbench[reporting]'` for an installed SDK package). Tables and
figures come from retained inputs/results, include currentness and never silently
update an earlier exported file. Inspect `statistics.export.catalogue` for exact
format names.

### Refreshing a dependency chain

New `refresh.inspect`, `.preview` and `.create` requests use
`dependencyMode: "transitive"`. The preview lists ordered processing, tracking,
lineage, assay/plugin-measurement and statistical checkpoints, their predecessor
bindings, blockers, and proposed specimen-assignment transfers. Save the reviewed
plan using its fingerprint, then use the existing `refresh.advance` or
`refresh.worker.start` lifecycle. Pause, cancellation and conflict handling share
the ordinary durable worker. Older saved measurement-only refresh jobs remain
readable and executable; `dependencyMode: "measurements"` also requests that
narrower behavior explicitly.

A derived-image checkpoint reruns the saved preprocessing recipe or **reapplies
the stored registration transform**. It does not re-estimate alignment. The
result receives a new acquisition identity. Existing exact masks transfer only
when recursive source-grid ancestry matches and every foreground voxel remains
inside acquired support. They are remeasured against the new pixels/calibration;
segmentation is not rerun. A changed grid or unsupported corrected voxel blocks
the checkpoint. The previous acquisition, measurements and correction history
remain retained.

Replacement maps feed later checkpoints, including paired nuclear/cell
references and statistical assay exemplars. A specimen assignment moves from an
old derived representation to its replacement in the same commit, with its
original assignment retained in the refresh history. This changes the active
representation of an observation; it does not create a new biological replicate.

Track matching and temporal inference rerun their saved gates/settings. Manual
links, unlink decisions and lineage edits transfer only when the affected
objects' exact old and current voxel geometry and acquisition-grid identity can
be established. Changed geometry, a conflicting new division or unavailable
historical edit evidence requires explicit review. Historical trackers created
before exact edit evidence was retained need an explicit new baseline before
automatic correction-preserving refresh. Temporal mask propagation itself stays
an explicit preview-bound correction, never an automatically repeated side
effect.

Each bounded checkpoint commits its output identities and the next expected
scientific state. A later external correction or assignment change stops resume
rather than silently rebasing the remaining work. Statistics regenerate retained
input, fitted and effect tables after their upstream replacements. Refresh
reports retain old/new image and run identities and skipped blockers. Previously
exported files remain historical snapshots; export a new report or figure to a
new destination.

### Read-only OMERO import

Configure an explicit host-local OMERO profile registry with `--omero-profiles`.
`omero.runtime.inspect` and `.candidate` inspect configuration/interpreter
identity without connecting; `.configure` binds a separately installed isolated
interpreter by exact hash, and `.probe` checks the fixed worker explicitly.
`omero.profile.save` stores connection settings and credential references using
configuration-hash CAS. Credentials, executable bindings and profile registries
are not portable project data. The optional isolated runtime requirements are in
`requirements-omero.txt`; ordinary workbench commands do not install or discover
an OMERO environment implicitly.

Named-profile operations page through groups and project/dataset or
screen/plate/well hierarchies, inspect image axes/calibration, and preview/import
one explicit T/C/Z XY region. Imports use raw server pixels with exact selected
region identity, not rendered JPEGs. The preview fingerprint is checked against a
fresh read before importing. Unknown calibration remains unknown. Network access
is read-only, TLS certificate/host verification is required, and imported pixels
remain usable without credentials. See `omero.catalogue` for current bounds and
capabilities.

MCP requires `--allow-omero-profile PROFILE_ID` for each allowed network profile.
Host-local setup additionally requires `--allow-omero-configuration`, write
permission and explicit registry/interpreter/credential-reference path grants.
The fixed local runtime probe uses the existing executable-operation opt-in.
These grants do not authorize arbitrary remote writes or shell commands.


### Review gates and corrected branches

Branching workflows can include a **Review** node after segmentation. Reaching
that node stops the existing background worker and records the exact source,
selection and mask awaiting review. Recommendations are retained separately from
decisions. Human-required gates accept a self-declared human decision, not an
agent-labelled approval; these roles are recorded provenance, not authentication.
An unrelated project edit does not invalidate the reviewed mask, but a changed
source or mask does. `job.graph.review.get`, `.recommend` and `.decide` expose the
same gate through the CLI and MCP.

Use `job.graph.continue.preview` and `.run` to continue a corrected branch. They
create a new job for the selected source/time checkpoint, copy the chosen exact
masks into independent images, reuse only unchanged compatible ancestors and
reset dependent assays and review gates. The original job and decisions remain
historical. A workflow with export requires a fresh destination.

An N:C assay node can connect its cell branch with `input` and its nuclear branch
with `nuclearInput`. Segmentation nodes may select a `sourceChannel` while keeping
the graph's projection/time. Both masks must belong to the same acquisition,
grid, calibration and valid support. Union/intersection mask nodes take two
`inputs` and generate **new connected components**, with face or full connectivity.
Touching union regions can become one object; original label IDs, review decisions
and tracks are not carried into those new objects. Arbitrary merge semantics are
not implied.


### Operation discovery and compact MCP

Agent clients can discover only the operations they need with
`operations.discover`: filter by `prefix`, text `query` or `mutating`, request
`includeSchemas: true` for exact arguments, and follow `nextCursor`. Pages default
to 25 entries and allow at most 100. Cursors are bound to the filters and catalogue;
restart discovery if either changes.

For a small MCP tool surface, add `--tool-mode compact` to the existing `mcp`
command. It exposes `workbench_discover`, `workbench_read`, and, when write access
is granted, `workbench_mutate`. Read/mutate calls take `operation`, `arguments`,
and the same request ID/revision fields required by the selected operation.
All path, executable, profile and saved-workflow checks still apply. Discovery
reports permission restrictions; it does not claim that optional runtimes or
network services are ready. Existing `--tool-mode operations` connections retain
direct operation names and receive bounded `tools/list` pages.

### Runtime configuration and plugin environments

The Python SDK uses the same validated host runtime setup as CLI startup:

```python
from workbench_sdk import WorkbenchClient, configure_runtime

binding = configure_runtime(
    microscopy_node="/absolute/bundled/node",
    microscopy_runtime="/absolute/bundled/microscopy-runtime",
    omero_profiles="/absolute/local/omero-profiles.json",
    runtime_registry="/absolute/local/plugin-runtimes.json",
)
client = WorkbenchClient("/absolute/experiment.ccproject")
page = client.discover(prefix="workspace.", include_schemas=True)
```

Only configure the optional runtimes you intend to use; `native_helper` accepts
the explicit installed macOS executable for legacy archive capture. Configuration
is process-wide, serialized with dispatch, and excluded from project packages.
Replacing an existing binding requires `expected_configuration_hash` from
`runtime_configuration()`. Existing local clients reject a changed binding;
create a client for the intended new configuration explicitly. Custom transports
own their remote runtime configuration and do not inherit the caller's local
runtime hash. Configuration never installs dependencies, enables a model/plugin
or opens a network connection by itself.

Plugin runtime bindings use a host-local registry, configured by the CLI's
`--runtime-registry` flag or the SDK's `runtime_registry` argument. Use
`runtime.interpreter.candidate`, `.register` and `.probe`, then
`plugin.runtime.bind` to select an interpreter for an exact installed plugin
package. Binding applies to that package hash across local projects and does not
enable disabled code. Registry writes require the observed `configurationHash`;
MCP additionally requires `--allow-runtime-configuration`, write permission and
explicit file grants. Dependency declarations are checked against the observed
interpreter inventory; nothing is installed automatically. New jobs freeze their
relevant binding, while older jobs retain the original default-interpreter
semantics. Registry paths and execution authority do not travel in packages.

The release supports segmentation, measurement, reader and exporter plugins.
Processor, tracker and assay plugin roles remain unsupported. These roles are
not implied by the built-in processing, tracking and assay operations.

`model.card.save/get/list` retains versioned intended use, limitations and exact
training/evaluation references. Authored text is not a model validation result.
`model.activation.set/get` records a future default, including an explicit empty
default, without enabling code or changing saved jobs. Package restoration keeps
model and plugin execution disabled until explicitly authorized locally.


### Reusable experimental layouts and exclusions

Reusable experimental layouts use the same typed categorical/numeric factors as statistical designs. Save slots with `experiment.layout.save`, inspect `experiment.layout.apply.preview`, and apply its fingerprint with `experiment.layout.apply.run`. Each slot creates one new biological specimen across all of its fields. Every application creates fresh specimen/plate identities; repeated subjects and blocks are linked only through explicit mappings. Layouts and preview-bound statistical design drafts can be saved before images or sufficient replicates exist. Draft inference reports its blockers and cannot be saved as a valid result.

`experiment.layout.application.statistics` produces a normal statistical definition draft from the retained factor rows. `acquisition.session.save` separately records instruments, operators, optional timezone-qualified acquisition timestamps and exact source membership. It does not change assignments or biological n; an absent acquisition time remains unknown. Sessions and layouts retain immutable versions.

In the desktop Workflows task, open **Experiments, specimens and plates** for layout versions, image bindings, acquisition sessions and exclusions. Layout application previews show new specimens and both new and replaced assignments. Blank subject/block mappings create new identities; exact existing IDs must be supplied to reuse them. Image choices remain explicit across paged library searches. The Statistics design editor can load a retained application using its selected outcome, and uses the same factor controls as the layout editor. A design with missing inputs can be retained as a draft; inference requires a ready saved version.

Use `experiment.exclusion.set` to record or clear a specimen or field exclusion with a reason. Summary/statistical inputs retain the effective decisions and their fingerprints, while old reports remain historical. Excluded fields do not make the remaining fields additional replicates. Archive visibility is independent of exclusion. A dependency refresh that replaces an acquisition representation carries its active field exclusion forward with an explicit predecessor link.

### Registered segmentation models

The registered model catalogue also supports exact local StarDist 2D, Omnipose and micro-SAM inference. `model.catalog` describes each backend's registration files and controls; `model.register` retains the selected checkpoint and, for StarDist, its configuration and optional thresholds. Omnipose architecture and micro-SAM architecture/AMG/AIS/APG mode are explicit. Model-specific inference schemas preserve extra acquired input channels where required; measured fluorescence remains on the declared anchor channel. These adapters do not install packages, download weights, substitute model aliases or advertise fine-tuning support. Saved workflows, sweeps and portable task definitions bind the complete weight/configuration identity. Micro-SAM primary checkpoints, like Cellpose 4 checkpoints, may be up to 2 GiB; ordinary model weights remain limited to 512 MiB and separate model JSON to 1 MiB.

The desktop **Registered models** form shows the selected backend's required files and architecture settings. Switching backend retains those drafts separately; registered inference controls come from the exact retained model definition. Compatibility probes and environment capture remain separate explicit actions. Reference-review suggestions use a selected scope of at most 200 candidate acquisitions; those candidates are not biological replicate assignments.

### Large libraries and streamed packages

New projects use indexed storage. Image records, scientific history and object measurement tables are retained separately, while edits still use one project revision and exact request replay. Existing format1 projects remain readable. `project.storage.upgrade.preview` and `project.storage.upgrade.run` migrate a previewed revision without recalculating science; the original database is preserved in a local recovery directory. This local recovery copy is excluded from portable packages because it may contain client-session and request metadata.

Use `project.snapshot` with explicit `selectedImageIds` for the active selection, `image.list` for the library, `project.history` for history, and `measurements.page` for object tables. The library page reports its total independently of loaded rows. Page cursors belong to one revision and filter set; a `snapshot-changed` response requires a new page sequence. It does not authorize rebasing an unsaved edit. `image.get` reads an off-page selection. `measurements.lookup` retrieves exact label identities, `mask.pick` reads the authoritative label at source coordinates, and `mask.overlay` displays the complete saved raster independently of table pagination. Orthogonal `volume.slice` calls can omit contours or request only selected label IDs.

Format2 project exports use Package2: a scientific-only indexed snapshot and streamed, hash-verified artifact shards inside a ZIP64 file. It retains source data, exact labels, measurement tables and provenance, including the shared engine code signature and observed environment metadata. It omits request receipts, client sessions and local runtime configuration. Supported bounds are 100,000 acquisitions per indexed project, 500,000 retained artifacts and 32 GiB per streamed package; these are limits, not performance claims. Ordinary selected-plane and volume computation limits still apply.

`package.inspect` verifies the Package2 manifest and scientific snapshot and reports that artifact bytes are verified during restore. `package.restore.start`, `.get`, `.advance`, `.cancel` and `.resume` provide durable restoration one shard at a time. These operations use `expectedRestoreRevision` for their own checkpoint state. Cancellation preserves verified partial bytes; a partial destination does not become a project until metadata finalization completes. Retained executable plugins/models stay disabled and background processes do not restart. `package.restore` remains a single-command convenience with the same retained checkpoints. Earlier analysis ZIPs remain supported.

Measurement-bearing analysis, correction, calibration, model, plugin and external-label operations accept `cellLimit` (1–1,000). This limits returned rows only. `cellCount` remains the complete count, while `returnedCellCount` and `cellsTruncated` identify the returned subset. Saved labels and measurements remain complete. Display the complete raster using `mask.overlay`, select exact objects through `mask.pick`/`measurements.lookup`, and read their table through `measurements.page`. Analysis previews retain their complete bounded overlay or volume display even when preview rows are limited.

### Additional segmentation and assay workflows

Classical plane segmentation supports Otsu, manual, triangle, Li, Yen, mean and adaptive thresholds, explicit bright/dark polarity or a recorded automatic background heuristic, and optional hole filling. Adaptive controls require an odd source-pixel neighbourhood and an explicit automatic or manual offset policy. Adaptive estimation requires rectangular acquired support; unsupported fill never contributes to its neighbourhood. These options use the same threshold kernel as the compatible legacy detector routes. Existing Otsu/manual settings keep their previous normalized defaults.

A graph's raw-intensity assays can consume source or preprocessed pixels without creating masks. These branches retain assay results and report no object count. N:C and neurite assays bind explicit nuclear and soma branches, respectively; paired mask sources must satisfy the canonical exact-grid requirements. Raw branches, segmentation alternatives and their sweep results remain distinct technical analyses.

Scratch-wound series participate in dependency-ordered refresh. Their replacement runs preserve ordered observations, explicit timestamps, common acquired support and predecessor links. Replicate statistics can use a declared series slope in pixel area per second, calibrated area per second, or normalized closure per second. The supported inference input is one current compatible series per biological specimen; multiple independent technical series require an explicit future aggregation policy and currently block the design. Frames never become biological replicates. Comparable declared time windows, processing, measured extents, calibration and coverage are required; different absolute ROI origins do not by themselves make specimens incompatible. Exact source positions remain retained provenance.

### Retained catalogue navigation

Large projects use `project.snapshot` for selected images and recent catalogue descriptors. `cataloguePages` reports total, returned count, partial state and the next revision-bound cursor for every catalogue. Use `project.catalogue` to page, `project.catalogue.get` for an exact retained identity/version, or `project.catalogue.getMany` for up to 200 explicit current identities. Assignments use image IDs; exclusion identities are `image:<id>` or `specimen:<id>`. A recent page is never a complete experiment or selection.

A snapshot can pin up to 64 open catalogue entries with `selectedCatalogueEntries`; missing entries are explicit. Active background/training jobs are reported separately from paged history, and `project.activity` reads that activity without replacing scientific drafts. Cursors reject changed revisions rather than silently mixing snapshots. Descriptor byte budgets can return fewer entries than requested; exact detail reads remain available.

The Windows task sections provide a shared retained-record browser. “Use in
controls” makes an older record available in the existing selector without
replacing its editor draft. Selected records stay available across project
refreshes; browser pins can be released without deleting data. Biological
reference cohorts resolve their exact image assignments and specimen identities,
and exclusion controls read the chosen target's current decision. The statistics
action that replaces a draft with all specimens explicitly reads the complete
bounded scope; it does not use the recent-record page as the experiment.
