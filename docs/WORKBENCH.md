# CellCounter Workbench

The Workbench brings image analysis, correction, measurements and export into one
project. The desktop interface, CLI, Python SDK and MCP server use the same
operations, so changes made in one are available in the others.

Start with the [desktop workflow](#desktop-workflow), [CLI example](#cli-example),
[Python SDK](#python-sdk) or [MCP connection](#mcp-connection).

- **Analysis:** [channel displays](#multi-channel-fluorescence-display),
  [tracking](#tracking-and-lineage), [preprocessing and assays](#preprocessing-independent-masks-and-assays),
  [annotations](#annotations-and-intensity-profiles).
- **Workflows:** [saved jobs](#saved-workflows-and-resumable-jobs),
  [branches](#branching-workflows), [parameter sweeps](#parameter-sweeps),
  [review](#review-and-quality-control), [refreshing results](#refreshing-results-after-corrections).
- **Experiments:** [specimens and plates](#experiments-and-biological-replicates),
  [statistics](#experimental-designs-and-statistical-reports),
  [layouts](#reusable-experimental-layouts-and-exclusions), [export](#saved-data-and-export).
- **Data:** [library import](#import-an-existing-cellcounter-library),
  [TIFF regions](#large-tiff-sources-and-regions), [OMERO](#read-only-omero-import),
  [models and plugins](#plugins-and-local-learned-models),
  [layers](#layer-workspaces-and-semantic-journals),
  [packages](#large-libraries-and-streamed-packages),
  [distributed tasks](#portable-distributed-tasks).
- **Setup:** [Python runtime](#standalone-runtime),
  [runtime configuration](#runtime-configuration-and-plugin-environments),
  [agent discovery](#operation-discovery-and-compact-mcp),
  [troubleshooting](#troubleshooting).

## Desktop workflow

Open **Workbench**, create a project folder and import your images. Choose a
channel and Z projection, then use **Preview** to adjust segmentation. **Run
analysis** saves the mask and measurements.

Delete or merge selected objects, draw a polygon to add an object, or undo a
correction. Measurements update when the mask changes. Enter calibration in
**pixels per micrometre** for physical area and equivalent diameter.

Use **Summary** to inspect counts and per-image measurements. **Export** saves a
project ZIP. **Refresh** loads changes made from another client and clears an
unsaved segmentation preview. Desktop clients also refresh when they regain
focus, provided there are no active edits.

Choose **3D / time** to work with a volume. The linked XY, XZ and YZ views share a
crosshair; the volume view adds rotation, zoom, contrast and opacity controls.
Run 3D threshold/watershed segmentation, then correct labels with slice polygons
or a spherical brush. Delete and merge act on whole objects; replacing a polygon
changes the selected slice. Set X, Y and Z voxel sizes for physical volume
measurements. Clearing a calibration field removes that axis's spacing.

Use the Workbench access panel to install or repair its analysis runtime.

## Tracking and lineage

Track analyzed time points with centroid matching. Set maximum displacement,
choose voxel or physical units, and set the allowed missing-frame gap. Correct
correspondences with manual link and unlink actions.

For drift-aware tracking and division suggestions, use `temporal.track.preview`
and `temporal.track.run`. Review ambiguous matches and proposed divisions before
accepting them. Drift offsets describe translation relative to the first frame.
`temporal.catalogue` lists the controls.

Use `temporal.propagate.preview` to inspect how a mask correction would move
across selected frames, including collisions and clipping. Apply it with
`temporal.propagate.run`; undo restores the saved before/after group. Mask or
calibration changes mark affected tracks for recomputation.

Initialize a lineage graph from the tracks, then add divisions or correct
continuations. A division connects one parent to two daughters at a later time
point. Suggestions use geometry and combined volume; decisions, reasons and undo
history are saved with the graph.

Agents use `lineage.get`, `lineage.initialize`, `lineage.division.set`,
`lineage.division.remove`, `lineage.link`, `lineage.unlink`, `lineage.undo`,
`lineage.suggest` and `lineage.summary`.

`lineage.export.catalogue` lists graph JSON, observation CSV, track-summary CSV
and link CSV formats. Export with `lineage.export` to a new filename. Tables
include calibrated centroids, observed movement, recorded divisions and frame
gaps. CSV times are relative to acquisition frame zero; missing calibration
produces empty physical-value fields. Graph JSON includes correction history.

## Multi-channel fluorescence display

`image.composite.preview` combines channels into a color display. Set each
channel's color, visibility, contribution and gamma. Omit intensity windows for
automatic contrast, or provide lower and upper values in source-intensity units.
Gamma above one brightens midtones.

For a plane, choose a max, mean or middle Z projection. For a volume, choose the
time, XY/XZ/YZ plane and slice. `image.composite.catalogue` describes the controls.
These settings affect viewing; analysis uses the source pixels.

`image.composite.export` saves a PNG with channel settings, source selection and
calibration. `image.composite.volume` returns an RGBA volume for the 3D renderer.
Add `labelChannel` to show saved labels on the same grid. CLI and MCP clients
receive the same image buffers and source-coordinate mapping.

Save reusable settings with `display.preset.save`. Passing `presetId` creates a
new version. Browse them with `display.preset.list` and `display.preset.get`, or
hide and restore presets with `display.preset.archive`.

Apply a version to another image with `display.preset.resolve`. If channel order
has changed, supply a zero-based `channelMapping` covering each saved channel.
Fixed intensity windows require matching intensity units; automatic windows are
recalculated for the target. Pass the returned `presetRef` with a composite
request to record the preset version. Save a new version after editing settings.

## Standalone runtime

Use Python 3.11 in a dedicated environment. From the repository root:

```sh
python3.11 -m venv .venv-workbench
.venv-workbench/bin/python -m pip install -r shared/python/requirements-analysis.txt
.venv-workbench/bin/python shared/python/workbench.py capabilities
```

On Windows, create it with `py -3.11 -m venv .venv-workbench` and use
`.venv-workbench\Scripts\python.exe` in place of `.venv-workbench/bin/python`.
For MCP, also install:

```sh
.venv-workbench/bin/python -m pip install -r shared/python/requirements-mcp.txt
```

`capabilities` reports available operations, formats and installed dependencies.

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

This example displays channel 0 in magenta and channel 1 in green, with automatic
contrast. Channel indices are zero-based.

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call image.composite.preview --args '{"imageId":"IMAGE_ID","target":"plane","sourceParameters":{"zProjection":"max"},"channels":[{"channel":0,"color":"#ff00ff"},{"channel":1,"color":"#00ff00"}],"maxSize":1024}'
```

The result contains a PNG `dataUrl` and the effective intensity windows. Export
it with the same settings and the current project revision. This example uses
revision 3 and a new output filename:

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call image.composite.export --args '{"imageId":"IMAGE_ID","target":"plane","sourceParameters":{"zProjection":"max"},"channels":[{"channel":0,"color":"#ff00ff"},{"channel":1,"color":"#00ff00"}],"maxSize":1024,"format":"composite-png","destination":"/data/channels.png"}' --expected-revision 3 --request-id composite-export-1
```

For a volume or time series, use `target: "volume"` with `timeIndex`, `plane` and
`index` instead of `sourceParameters`. For example,
`"timeIndex":0,"plane":"xy","index":0` selects the first XY slice at the first
time point. The other planes are `xz` and `yz`.

For a 3D rendering buffer:

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call image.composite.volume --args '{"imageId":"IMAGE_ID","timeIndex":0,"channels":[{"channel":0,"color":"#ff00ff"},{"channel":1,"color":"#00ff00"}],"maxDimension":128,"labelChannel":0}'
```

This returns base64 RGBA voxels with their source-grid mapping. Automatic contrast
uses the selected volume. `labelChannel` adds saved labels; PNG export saves the
selected slice or projection.

### Reusing display settings from the CLI

Save a named preset using the current project revision:

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call display.preset.save --args '{"name":"Two-channel fluorescence","intensityUnits":"raw-source","channels":[{"channel":0,"color":"#ff00ff"},{"channel":1,"color":"#00ff00"}],"maxSize":1024,"maxDimension":128}' --expected-revision 4 --request-id preset-save-1
```

Resolve the returned preset ID against a target image:

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call display.preset.resolve --args '{"presetId":"PRESET_ID","version":1,"imageId":"IMAGE_ID"}'
```

Use `settings.channels`, `settings.maxSize` or `settings.maxDimension`, and
`presetRef` in the composite request. If channels have moved, include a mapping
such as `[{"source":0,"target":1},{"source":1,"target":0}]`.

To move a preset to another project, export a version:

```sh
.venv-workbench/bin/python shared/python/workbench.py --project /data/Experiment.ccproject call display.preset.export --args '{"presetId":"PRESET_ID","version":1,"format":"preset-json","destination":"/data/channels-preset.json"}' --expected-revision 5 --request-id preset-export-1
```

In the destination project, call `display.preset.import.preview` with the file's
absolute `path`, then send that path and its `previewFingerprint` to
`display.preset.import.run`. Apply the imported preset when ready.

## MCP connection

Configure your MCP client to launch Python over stdio:

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

Connections start read-only. Add `--allow-write` for analysis, corrections,
imports, calibration changes and exports. Use `--allow-path /data/chosen-directory`
for inputs or outputs outside the project; repeat it for additional locations.

For plugins and registered models, also add `--allow-plugins`. Grant access to
the plugin directory, checkpoints, interpreter and external input/output paths.
Plugins run as local Python processes with your user permissions.

MCP tool names replace dots with underscores: `project_inspect`, `analysis_run`
and `mask_edit`, for example. Pass an `arguments` object matching the operation's
schema. Writes also take `requestId` and `expectedRevision`; project creation
and package restoration start without an existing project revision.
`job.worker.stop` uses worker-control state instead of a scientific revision.

Tools return structured responses. Preview and source-slice tools also return
MCP image content; volume buffers are available in the structured result.

For volumes, use `volume.inspect`, `volume.display`, `volume.slice`,
`volume.analysis.preview`, `volume.analysis.run`, `volume.measurements.get`,
`volume.mask.edit` and `volume.mask.undo`. Select `imageId` and zero-based
`timeIndex` and `channel`. `volume.calibration.set` sets individual axes and time
spacing. Tracking uses `tracks.run`, `tracks.get`, `tracks.link` and
`tracks.unlink`.

Volume arrays use ZYX order with X contiguous. Measurement and edit coordinates
use voxel edges: the first voxel center is `(0.5, 0.5, 0.5)`. Slice indices and
renderer crosshairs are zero-based voxel indices. Display descriptors provide
the scale and offset back to the source grid.

## Saved workflows and resumable jobs

Save a recipe with `workflow.save`. Steps run in this order: optional
`preprocessing`; `analysis`, `volume-analysis`, `plugin-segmentation` or
`model-segmentation`; optional `plugin-measurement` and `assay`; `measurements`;
`summary`; and optional `export`. Saving with an existing `workflowId` creates
a new version. Jobs keep the version they started with.

A preprocessing step creates a derived image for each selected input. Later
steps use that image, whose working channel and volume time indices are zero.
Choose assay channels accordingly. The original images remain in the project.

For example, pass this as `workflow.save` arguments:

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

Create a job with the returned workflow ID:

```json
{
  "workflowId": "WORKFLOW_ID",
  "imageIds": ["IMAGE_ID"],
  "exportDestination": "/data/workflow-output.zip"
}
```

Volume workflows also accept `timeIndices`; omit them to process all time points.
Each selected time must exist in every input image.

`job.create` returns `result.job`. Call `job.advance` with `{"jobId":"JOB_ID"}`
to run the next checkpoint. Use the current revision and a new request ID for
each call. Read `status`, `progress` and `nextUnit` to follow the job: a saved
failure may return `ok:true` while its status is `failed` or `blocked`.

Jobs resume from saved checkpoints after a restart. `job.pause`, `job.resume`,
`job.retry` and `job.cancel` control remaining work; `job.list` and `job.get`
show progress. Pause and cancellation take effect after the active computation.

Use `job.worker.start` to run in the background. `sweep.worker.start` runs a whole
sweep. `job.worker.list` and `job.worker.status` show worker progress;
`job.worker.stop` stops after the current checkpoint. Resume a paused job or
sweep before starting its worker again. Worker records identify `targetKind`
(`job`, `sweep` or `refresh`) and `targetId`.

Changes to captured inputs can block a job. Create a new job with the intended
inputs after resolving them. For export steps, supply a new `exportDestination`
when creating the job. Exports contain the complete project. MCP connections
need an allowed path for that destination.

## Branching workflows

Use branching workflows to compare methods or connect processing, segmentation,
measurements and review. `workflow.graph.catalogue` lists node types and schemas.
`workflow.graph.preview` checks the graph and returns its execution order;
`workflow.graph.save` saves a version.

Graphs start at `$source`. Preprocessing nodes can chain or branch. Segmentation
nodes create independent image variants, and measurements and assays consume
those variants. Source selections follow the input of each node; processed
images use channel zero and local time zero. Model and plugin settings are saved
with the graph.

This graph compares two minimum-area settings:

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

For volumes, use `target: "volume"`, a top-level `channel` and `volume-analysis`
nodes. Choose time points when creating the job.

Run graphs with `job.create`, `job.advance` or `job.worker.start`. `nextUnit`
identifies the input and node; `nodeProgress` shows saved checkpoints.
`job.graph.node.preview` takes `jobId`, `checkpointIndex`, `nodeId` and optional
`maxSize` to inspect an available node input. Segmentation, preprocessing and
assays calculate previews; measurement previews read the saved mask.

Summary nodes collect results from several branches, keeping their image and
time identities. Set a fresh `exportDestination` on the job to export the
project. `sweep.parameters` discovers graph controls by `nodeId` and parameter
`path`; linear workflows use `stepIndex`.

Changed inputs stop further execution while preserving completed branches. Use
[corrected-branch continuation](#review-gates-and-corrected-branches) to start a
new job from reviewed masks. Union/intersection nodes create connected objects;
paired assays can connect nuclear or soma masks from a compatible branch.

## Python SDK

Install `cellcounter-workbench` from its wheel or, from a checkout, with
`python -m pip install './shared/python[mcp,zarr]'`. Python 3.11 or later is
required. The package provides `workbench_sdk` and the `cellcounter-workbench`
command.

```python
from workbench_sdk import WorkbenchClient, WorkbenchOperationError

client = WorkbenchClient("/absolute/experiment.ccproject",
                         actor={"kind": "agent", "name": "Local analysis script"})
snapshot = client.inspect()  # Read the current project revision.
operation = client.prepare("image.import", {"paths": ["/absolute/field.tif"]},
                           request_id="import-field-1")
try:
    response = operation.execute()
except WorkbenchOperationError as error:
    print(error.code, error.details)
    # Inspect the error before retrying.
```

`inspect()` refreshes the client's project revision. Successful writes advance
it. Prepared operations keep their arguments, actor, request ID and revision,
so you can retry the same request after a transport interruption.

`operations()` returns schemas and capability metadata. `send()` accepts a full
request envelope. Errors include the failed envelope. A custom transport callback
can send requests to another configured host.

## Import an existing CellCounter library

Capture an existing library with `migration.library.capture`. Supply `platform`
(`windows` or `macos`), an absolute `sourceDirectory` and a new JSON `destination`.
Windows captures a SQLite snapshot. macOS uses the installed app to read its
SwiftData library; set the executable with `--native-helper`.

Call `migration.library.preview` with the archive `path` and optional `imageIds`.
Review the import plan, then send the same selection, `previewFingerprint` and
project name to `migration.library.run`, targeting a new project directory.
`migration.library.advance` copies the next file or image record. Pause, resume
and cancel operate between checkpoints. The original library stays intact.

`project.inspect.migration` and `migration.library.get` show progress.
`evidenceComplete` and `scientificImportComplete` distinguish archived material
from usable analysis images. `migration.geometry.get` reads historical cell
centres, diameters and contours; these records have `exactMask:false`.
`migration.records.get` reads original settings, ROIs, review history and queued
operations. `migration.evidence.list` lists copied, pending or missing files.

MCP capture needs write access, source/destination path grants and
`--allow-plugins` for the native macOS helper.

## Portable distributed tasks

Split a saved workflow into tasks for another machine. Each task contains its
workflow version, source data, calibration and reference inputs. Transfer the ZIP
packages with your preferred file-sharing method.

In **Workflows → Distributed work**, preview the partition, create tasks and
export their packages. On the receiving machine, restore a task, prepare it and
run it with the normal job controls. Preview returned packages before collection.

`distribution.preview` takes `workflowId`, `imageIds` and optional
`workflowVersion` and `timeIndices`. `distribution.create` takes the same
selection and an optional `name`. Read tasks with `distribution.get` and
`distribution.list`. Export one with `distribution.bundle.export`, using
`distributionId`, `taskId` and a new ZIP `destination`.

For built-in methods, the standalone runner handles restoration and execution:

```sh
python shared/python/workbench.py --project /data/task.ccproject distributed-run \
  --package /data/task.zip \
  --result /data/task-result.zip
```

Use a new project directory with an existing parent. If the workflow has an
export step, add `--workflow-export /data/workflow-output.zip`. Progress goes to
stderr and the final JSON response to stdout.

For plugin or model workflows, restore the package first, inspect it with
`distribution.task.get`, configure the local runtimes and enable the required
code. Then run `distributed-run` without `--package`.

`distribution.task.prepare` creates the task's job. Use
`--allow-runtime-differences` during preparation to accept reported runtime
differences. Prepared tasks keep their runtime bindings; to choose another
runtime, restore the original bundle into a fresh project and prepare it there.

Ctrl+C stops after the active checkpoint. Resume with:

```sh
python shared/python/workbench.py --project /data/task.ccproject distributed-run \
  --resume --result /data/task-result.zip
```

Use `--retry` after fixing a failed job. Following an abrupt exit, inspect the
existing task before continuing and omit `--package`. Choose new filenames for
all exports.

Back at the coordinator, call `distribution.result.preview` with
`distributionId`, `taskId` and the returned package `path`. Review the job and
runtime details, then pass those arguments and `previewFingerprint` to
`distribution.result.collect`. Collected results are linked result projects.
`distribution.result.export` saves one as a new ZIP.

## Parameter sweeps

`sweep.parameters` lists the scalar controls in a saved workflow. Each entry has
a zero-based `stepIndex` and `path`, such as `parameters.minAreaPx` or
`recipe.0.sigma`. Define an axis like this:
`{"stepIndex":0,"path":"parameters.minAreaPx","values":[9,25,49]}`.
Use `null` to apply the default only when `canOmit` is true.

Call `sweep.preview` with `workflowId`, `imageIds` and `axes`; optionally choose
`workflowVersion` and volume `timeIndices`. `sweep.create` takes the same
arguments and an optional name. For export workflows, supply an existing
`exportDirectory`.

Each combination gets independent image variants, a workflow and a resumable job.
`sweep.get` and `sweep.list` show progress. `sweep.advance` runs the next
checkpoint; `sweep.pause`, `.resume`, `.retry` and `.cancel` control the group.
Use `sweep.worker.start` to run it in the background or `job.worker.start` for a
single combination. `job.worker.stop` stops after the active checkpoint.

`sweep.results` returns one row per combination and input image/frame, with
counts, foreground size, mean object size and intensity. Mean intensity weights
objects equally. Incomplete or changed inputs have a status and empty metrics.
Use `offset` and `limit` to page input rows.

Save the comparison as JSON or CSV with `sweep.export.catalogue` and
`sweep.export`. Exports include parameter settings, input references and all
result rows, including those awaiting analysis.

## Experiments and biological replicates

Create specimens with an experiment, condition and control/treatment role. Assign
images to each specimen, with optional plate, well and field details.

`specimen.set`, `plate.set`, `image.assign` and `image.unassign` provide the same
controls through CLI and MCP. `experiment.get` reads the design.
`experiment.summary` combines images within each specimen, then gives complete
specimens equal weight within each condition. It lists incomplete specimens
separately. Physical-area summaries require calibration for all assigned images.

`assay.metrics` lists numeric values from a saved assay.
`experiment.assay.summary` uses a reference run and metric path to collect
compatible results. It shows image contributions and exclusions, averages each
specimen's images and then summarizes conditions. Assign biological specimens
before calculating replicate statistics.

## Saved data and export

A project contains `workbench.sqlite` and an `artifacts/` folder. Keep them
together. Sources, masks, measurements and correction history are stored in the
project; processed images also record their recipes and intensity units.

`project.export` saves a snapshot with source data, labels, measurements, tracks,
workflows and history. New indexed projects use
[Package2](#large-libraries-and-streamed-packages); earlier projects use their
analysis ZIP format. `sourceRevision` identifies the exported snapshot.

Inspect a package with `package.inspect` and restore it with `package.restore`
into a new project directory. Configure and enable restored models or plugins
before using them. Keep the original project as well as your exported package.

`image.export.catalogue` lists single-image formats. `image.export` saves source
pixels, instance labels or acquired-support masks as calibrated OME-TIFF;
measurements as CSV; or a display overlay as PNG. Label TIFFs use uint32 IDs with
zero as background. Source exports keep native pixel types, while mean
projections use floating-point values.

Choose a saved plane analysis or volume time/channel selection and a new output
filename. Exported files and their source references are saved with the project.

## Plugins and local learned models

Install a local manifest with `plugin.install`, inspect it with `plugin.inspect`
and enable it with `plugin.setEnabled`. Plugins can provide segmentation,
measurements, readers or exporters. Their parameter schemas generate desktop
controls and define CLI/MCP arguments.

`plugin.run` applies segmentation or measurements to a plane or volume. A
segmentation plugin returns integer labels matching the source shape.
`plugin.results` reads saved outputs and their status. `plugin.read` imports
reader output as TIFF while preserving the original file. `plugin.export` saves
the output and writes it to a new destination.

`model.catalog` lists model backends, registration files and controls.
`model.register` takes a backend, local checkpoint and Python executable;
`model.configure` changes its binding or enabled state. `model.probe` checks
compatibility. Install the model's dependencies in that Python environment
before running it.

Use `model.environment.capture` to save the environment's Python and package
versions, and `model.environment.get` to read the record or its history. Runs
with a captured binding check it before execution. After updating packages,
capture the environment again and create a new workflow version or job.

`model.run` analyzes a selected 2D channel and Z projection. Cellpose 3 uses
`diameterPx` (default 30 pixels). Cellpose 4 / Cellpose-SAM uses optional
`rescaleDiameterPx`; omit it for native scale. Use the backend's `inferenceSchema`
for its controls, including flow, cell probability, minimum area and device.

For model adaptation, approve masks with `adaptation.reference.set` and assign
images to specimens. `adaptation.suggest` proposes images for annotation.
`adaptation.dataset.create` saves train, validation and held-out test specimens.
`adaptation.evaluate` compares two segmentation plugins on the test inputs.
`adaptation.train.start` starts Cellpose 3 training in a local worker. Training
list, status, cancel and collect operations track progress and save the completed
checkpoint and report.

## Preprocessing, independent masks and assays

Build a recipe from `preprocessing.catalogue`, preview it and call
`preprocessing.run` to create a processed image. Filters include Gaussian,
median, rolling-ball background subtraction, CLAHE, percentile normalization,
diffusion, constant subtraction, white top-hat, unsharp masking and
Richardson–Lucy deconvolution. Deconvolution uses a Gaussian point-spread
function specified in pixel or voxel units and requires nonnegative input.
`preprocessing.inspect` shows the recipe and source history.

`image.duplicate` creates an independent mask layer on the same source.
Set `copyAnalysis:true` to start with the current labels. This is useful for
separate nuclear and whole-cell masks.

Choose **Import object labels** to preview a TIFF or NPY label image, then apply
it. CLI and MCP use `mask.import.preview` and `mask.import.run`, passing the
returned `previewFingerprint`. Labels must match the selected source dimensions;
zero is background. Import preserves IDs, updates measurements and supports undo.

`mask.compare` compares saved layers on the same acquisition and grid. It reports
foreground Dice/Jaccard agreement, object matches at IoU ≥ 0.5, unmatched labels
and a disagreement overlay. Volume scores cover the selected volume; choose a
slice for the overlay.

`assay.catalog` lists morphology, 3D shape, fluorescence, spatial neighbourhoods,
marker positivity, reporter-positive cells, colocalization, live/dead,
DNA-content, nuclear:cytoplasmic intensity and puncta workflows.
`assay.preview` calculates a preview; `assay.run` saves it. Read outputs with
`assay.results` and update them with `assay.recompute`.

Nuclear:cytoplasmic analysis uses independent masks from the same source and Z
projection. 3D surface measurements use marching cubes with per-axis calibration
and flag objects touching acquisition boundaries.

## Refreshing results after corrections

Mask edits and calibration changes update object measurements. Saved assays,
plugin measurements and other dependent results are marked when their inputs
change. Open **Measurements → Saved result freshness** to inspect them and plan
a refresh.

`refresh.inspect` takes optional `imageIds` and `includeHistory`. The default
refresh follows processing, tracking, lineage, measurements and statistics in
dependency order. See [refreshing a dependency chain](#refreshing-a-dependency-chain)
for details.

For a measurement-only refresh:

1. Call `refresh.preview` with `dependencyMode: "measurements"` and optional
   `imageIds`. To select saved runs, provide `runRefs` with `kind` (`assay` or
   `plugin-measurement`) and `runId`. Set `includeCurrent:true` to include current
   results.
2. Review the plan and pass its `previewFingerprint`, selection, dependency mode
   and current revision to `refresh.create`. Use `skipBlocked:true` to proceed
   with the runnable items.
3. Run checkpoints with `refresh.advance` or start a worker with
   `refresh.worker.start`. `refresh.get` and `refresh.list` show progress.

`refresh.pause`, `.resume`, `.retry` and `.cancel` control saved plans.
`job.worker.stop` stops the background worker after its checkpoint. Changed
inputs need a new preview and plan.

`refresh.results` reads the report. `refresh.export.catalogue` and
`refresh.export` save JSON or CSV with previous and replacement results,
dependencies and skipped items. `executionComplete` reports finished work;
`coverageComplete` also requires current outputs and no skipped items. Export a
new file when you want an updated report.

## Annotations and intensity profiles

Draw points, lines, polylines and polygons independently of cell masks. Use a
2D channel/projection or a volume slice. Vertices use source pixel-edge
coordinates; the desktop editor also offers numeric editing, names and notes.

`annotation.save`, `.list`, `.get`, `.delete` and `.undo` manage annotations.
`annotation.measure` reads saved or draft geometry. It uses the current axis
calibration and can sample another channel with a measurement-channel override.

Polygon measurements include area, perimeter and pixel intensities. Line profiles
use bilinear interpolation along the line. Missing samples appear as gaps, with
their coordinates available in the profile table. Draw polygons with a simple,
non-crossing boundary.

`annotation.export.catalogue` lists geometry JSON, measurement CSV and profile
CSV. Save edited geometry, then call `annotation.export`. Geometry JSON includes
source selection and edit history. Profile CSV contains sample index,
coordinates, distance, intensity and `valid`; missing values use `valid=0`.

To transfer geometry, call `annotation.import.preview` with a CellCounter
annotation JSON file. The source pixels and grid must match the target. Apply
with `annotation.import.run` and the `previewFingerprint`. The imported annotation
gets a new local ID, keeps its original history, and uses the target calibration.
MCP imports and exports need the corresponding path grants.

## Review and quality control

`review.flag` marks analyses as satisfactory or needing review.
`review.session.create` selects a reproducible random sample of images, frames
or cells. You can include apparently satisfactory analyses in the sample.

The review desk uses anonymous codes. Reviewers record accept, reject or uncertain
decisions with an error category. `review.adjudicate` saves a resolution and
reason when reviewers disagree.

Blinded sessions hide other decisions until the reviewer submits their own.
`review.reveal` ends blinding and releases aggregate outcomes.
`review.summary` reports workload, disagreement, rejection intervals and changed
inputs. Corrections mark affected samples stale; create a new sample to review
the updated analysis.

## Large TIFF sources and regions

Register a large TIFF with `source.import`, then inspect it with `source.list`
and `source.inspect`. `source.overview` returns a display with a mapping to
original pixel coordinates. Draw a rectangle in the overview or enter its
coordinates.

`source.extract` copies the selected XY region, stored page and channel into an
analysis image. It preserves the original pixel type, intensities, source
reference and physical origin where available. The reader uses memory mapping
or selective tile/strip decoding. Stored page numbers identify TIFF pages;
choose biological time and Z selections in the analysis image.

## Translation registration

`registration.estimate` finds a 2D translation between channel, time and
Z-projection selections on equal grids. You can also enter a known translation.
Positive X moves right; positive Y moves down.

`registration.preview` shows the reference, moving image and overlay.
`registration.apply` creates an aligned image on the reference grid with nearest
or linear interpolation. It saves the transform, calibration and acquired-pixel
mask. Processing and measurements use that mask to exclude fill pixels.
`registration.inspect` reads the saved alignment and source history.

## Acquisition library metadata and repair

`image.metadata.get` and `image.metadata.set` manage names, notes, tags and
channel names. `library.search` searches text, tags and collections with `active`,
`archived` or `all` visibility. `collection.save` manages named groups.

Use `image.archive` and `collection.archive` to hide items, or set
`archived:false` to restore them. Archiving preserves measurements, assignments
and history; experimental membership is managed separately.

`library.duplicates` groups files with matching hashes. Each acquisition keeps its
own identity.

To repair a missing or corrupt source, call `image.relink.preview` with the
original file, then `image.relink.run` with its fingerprint and current project
revision. The file's SHA-256 must match the saved source. Relinking preserves
masks, calibration and assignments.

## Shared project sessions and agent navigation



### Task navigation in current source builds

Current source builds expose `navigation.catalog`. Check `capabilities` or
`operations.discover` when connecting to an installed runtime.

The catalogue lists the desktop tasks and their operations without opening a
project:

| Task ID | Navigation label | Main tools |
| --- | --- | --- |
| `preparation` | Images | Import, catalogue, calibration, preprocessing, registration and layers |
| `segmentation` | Segmentation | Models, adaptation, segmentation and mask editing |
| `measurements` | Measurements | Assays, annotations, tracking, lineage and statistics |
| `review` | Review | Quality control, comparisons and review decisions |
| `workflows` | Workflows | Experiments, plates, graphs, sweeps, jobs, distribution and refresh |
| `export` | Results & export | Summaries, exports, packages and storage |

```sh
python3 shared/python/workbench.py call navigation.catalog
```

Operation descriptors include `navigationTask`. Use `operations.discover` for
argument schemas and the connection's access requirements.

To navigate an open desktop session, read `session.list` and `session.get`, then
send a request using its current session and project revisions:

```sh
python3 shared/python/workbench.py --project /absolute/experiment.ccproject \
  call session.navigate --request-id show-review-1 \
  --args '{"sessionId":"graphical-session-id","expectedSessionRevision":3,"observedProjectRevision":8,"selection":{"task":"review"}}'
```

The host responds with `applied`, `deferred` or `refused`. A task-only request
keeps the image, spatial selection and editor drafts. Scientific results stay
unchanged.

### Project changes and session revisions

`project.changes` reads changes after `afterRevision`. Continue with `nextRevision`
while `hasMore` is true. If `resetRequired` is true, read `project.snapshot` and
restart from that revision. Events include the actor, operation and affected
sources, labels, calibration or metadata.

`session.open` registers a client. `session.update` publishes its image,
channel/time/slice, task or layer workspace. Use `expectedSessionRevision` for
session writes and `observedProjectRevision` for selections. Read them through
`session.list` and `session.get`; `selectionCurrent:false` indicates an outdated
selection.

`session.navigate` requests navigation. The host replies through
`session.navigation.ack`, applying it or providing a reason to defer or refuse.
Close finished clients with `session.close`. Session revisions are separate from
scientific project revisions, and sessions stay local to the host.

`resource.report` returns Python/package versions, CPU and host-capacity
information, and the configured microscopy runtime.

<a id="layer-workspaces-and-semantic-journals"></a>

## Layers and edit history

`workspace.catalogue` describes the microscopy runtime. Create or import a layer
document with `workspace.create`, `workspace.import.preview` and
`workspace.import.run`. Bind imported raster layers to a saved image and channel,
projection or time/Z slice with `workspace.source.bind`.

`workspace.layer.add` and `.update` manage image and label layers, visibility,
blending, contrast and presentation transforms. `workspace.layer.preview` reads
a source-grid preview; `workspace.preview` composes the layers.
`workspace.replay` runs saved operations, including registration and stitching.
`workspace.undo` restores the previous document as a new version.

`semantic.render` saves uint16 class labels and TIFF output from a paint journal.
`pointlineage.build` associates point observations. `animation.render` creates a
GIF from a saved plan. Use raw-volume bindings for workspace time, Z and channel
navigation; animation keyframes select source indices.

`workspace.zarr.add` and `.bind` connect a local NGFF source, multiscale array and
level-pixel ROI. Browsing reads source planes directly. The selected array and
ROI are saved with the workspace.

To analyze a generated intensity plane, use `workspace.materialize.preview` and
`.run`. The preview records its workspace version, coordinates, calibration and
source parents. The resulting image can be segmented and measured in the
Workbench.

`workspace.get` reads the document; `workspace.document.set` replaces it and
`workspace.document.update` applies an inline draft. `workspace.layer.samples`
provides source-grid values for painting and vector editing.
`workspace.output.list` reads generated outputs. `workspace.export` saves a
portable workspace; `workspace.output.export` saves a selected output. Project
packages include layer documents, versions, source bindings and generated files.

Desktop applications use the bundled Node microscopy runtime. For standalone
commands, set `--microscopy-node /absolute/node` and
`--microscopy-runtime /absolute/runtime` before the command.

## Paged project libraries and storage

`project.snapshot` returns project catalogues and requested image IDs. Use
`image.list`, `image.get`, `project.history` and `measurements.page` to browse
images, history and object tables. Cursors belong to a revision and filter set;
start a new page sequence after the revision changes.

Selections persist across search pages. `mask.pick` reads a label at source
coordinates, `measurements.lookup` retrieves selected objects, and `mask.overlay`
displays the saved raster.

New projects use indexed storage. Upgrade an older project through
`project.storage.upgrade.preview` and `.run`. The upgrade keeps a local recovery
copy of the original database and preserves scientific results.

Package restoration has saved checkpoints. Use `package.restore.start`, `.get`,
`.advance`, `.cancel` and `.resume` to restore a new destination incrementally.
Open it after restoration finishes. The desktop can continue restoration while
open or stop after a checkpoint.

Import original library workspaces through the archive reader's preview-and-copy
flow to edit them in the project Workbench.

## Troubleshooting

- **`revision-conflict`:** refresh the project, review the current result and
  submit your change with its current revision and a new request ID.
- **`request-conflict`:** retry the original request unchanged, or choose a new
  ID for a different operation.
- **`runtime_unavailable` or missing dependencies:** install
  `requirements-analysis.txt` in the Python environment running the command.
  For MCP, also install `requirements-mcp.txt`.
- **`permission_denied` over MCP:** check the configured project,
  `--allow-write` and allowed paths.
- **Image import error:** export the needed series, channel or time point from
  the acquisition software and import it again.
- **Artifact integrity error:** restore an intact project backup.

### Experimental designs and statistical reports

`statistics.catalogue` lists outcomes, design fields and analysis settings.
Define categorical factors with levels and a reference level, or numeric factors
with units. Each row identifies a biological specimen. Use `subjectId` for
specimens from the same subject and `blockId` for experimental blocks.

Preview with `statistics.design.preview`, then save with
`statistics.design.save`. The design uses current object measurements or a scalar
from `assay.metrics`, averaging image values within each specimen. The preview
shows missing inputs and exclusions to resolve before analysis.

`statistics.preview` calculates Welch contrasts, paired-subject t contrasts or
a linear model with categorical/numeric main effects and two-factor interactions.
Paired comparisons need one sample at each contrasted level per subject. Linear
models offer subject/block fixed effects and classical or HC3 covariance.
Save the preview with `statistics.run` and its fingerprint.

Results include coefficients, effect sizes, confidence intervals, fitted values,
residuals and degrees of freedom. Choose Holm, Benjamini–Hochberg or unadjusted
p-values. Categorical contrasts use the reference level; other categories stay at
their reference and numeric factors at their specimen means.

`statistics.get` reads a result and its input table. After corrections, use
`statistics.recompute.preview` and `.run` to create a linked replacement.
`statistics.export` saves JSON, specimen CSV, effect CSV or SVG effect plots.
Use `statistics.export.catalogue` for format names. SVG export requires
`requirements-reporting.txt`, or install `cellcounter-workbench[reporting]`.

### Refreshing a dependency chain

`dependencyMode: "transitive"` follows processing, tracking, lineage, assays,
plugin measurements and statistics. `refresh.preview` lists checkpoints in order,
including specimen-assignment transfers and items needing attention. Save the
plan with its fingerprint, then advance it or start a refresh worker.

Derived-image checkpoints rerun the preprocessing recipe or apply the saved
registration transform. The output gets a new image identity. Masks transfer
when source-grid ancestry and acquired pixels match, then measurements use the
new pixels and calibration. Previous images and edit history stay available.

Later checkpoints use the replacement images and paired references. Specimen
assignments move to the replacement representation with a history entry.
Tracking reruns its saved settings; manual links and lineage edits transfer when
the corresponding object geometry and grid match. Review any changes that cannot
be transferred.

Each checkpoint saves its outputs and the next expected state. If inputs change,
review them and create a new plan. Reports show previous and replacement IDs and
any skipped items. Export new tables or figures after the refresh.

### Read-only OMERO import

Set `--omero-profiles` to a local profile registry. Use
`omero.runtime.inspect` and `.candidate` to inspect setup, `.configure` to choose
an isolated Python interpreter, and `.probe` to check it. Install that environment
from `requirements-omero.txt`. `omero.profile.save` stores connection settings and
credential references.

Browse groups, projects/datasets or screens/plates/wells by named profile. Inspect
image axes and calibration, then preview and import a T/C/Z XY region.
Imports copy raw pixels and keep their selected region and source identity.
The preview fingerprint is checked again when importing. See `omero.catalogue`
for operation schemas.

For MCP, add `--allow-omero-profile PROFILE_ID` for each server profile. Setup
also uses `--allow-omero-configuration`, write access and path grants for the
registry, interpreter and credential references. Configure credentials locally;
imported pixels remain available when disconnected.

### Review gates and corrected branches

Add a **Review** node after segmentation to pause a workflow for a decision.
`job.graph.review.get`, `.recommend` and `.decide` expose the gate through CLI
and MCP. Gates save the source and mask being reviewed, recommendations,
decisions and reasons. A changed source or mask requires another review.

Use `job.graph.continue.preview` and `.run` after correcting a branch. They create
a new job from the selected checkpoint and masks, reuse compatible ancestors and
reset dependent assays and gates. The original job remains available. Supply a
new export destination when the workflow includes export.

An N:C node takes its cell branch as `input` and nuclear branch as `nuclearInput`.
Segmentation nodes can choose `sourceChannel` while keeping the graph's time and
projection. Paired masks need matching acquisition, grid, calibration and
acquired support. Union/intersection nodes take two `inputs` and create connected
components with face or full connectivity.

### Operation discovery and compact MCP

Find operations with `operations.discover`. Filter by `prefix`, text `query` or
`mutating`; set `includeSchemas:true` for arguments and follow `nextCursor` for
more results.

Add `--tool-mode compact` to the MCP command for three tools:
`workbench_discover`, `workbench_read` and, with write access,
`workbench_mutate`. Read and mutate calls take `operation`, `arguments` and the
selected operation's request ID/revision fields. Use `--tool-mode operations`
for individual tools such as `analysis_run`.

### Runtime configuration and plugin environments

The SDK and CLI share runtime configuration:

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

Configure the runtimes you need. `native_helper` selects the installed macOS
executable for library capture. Configuration is process-wide. To replace it,
pass `expected_configuration_hash` from `runtime_configuration()`, then create
a client for the new binding. Custom transports configure their remote host.

Set the plugin interpreter registry with CLI `--runtime-registry` or SDK
`runtime_registry`. Use `runtime.interpreter.candidate`, `.register` and `.probe`,
then `plugin.runtime.bind` to choose an interpreter for an installed plugin.
Registry writes use the observed `configurationHash`. MCP setup also needs
`--allow-runtime-configuration`, write access and file grants.

Jobs save their runtime binding. Install plugin dependencies in the selected
environment before execution. Configuration, credentials and path grants stay
local to the host.

`model.card.save/get/list` stores model notes and training/evaluation references.
`model.activation.set/get` chooses a default model for future work. Enable
restored models and plugins locally before execution.

### Reusable experimental layouts and exclusions

Save reusable specimen, plate and factor layouts with `experiment.layout.save`.
Preview them with `experiment.layout.apply.preview`, then apply the returned
fingerprint with `experiment.layout.apply.run`. Each slot creates a specimen and
its fields. Supply existing subject/block IDs to link repeated observations.

In **Workflows → Experiments, specimens and plates**, manage layout versions,
image bindings, acquisition sessions and exclusions. Preview new specimens and
replaced assignments before applying. Save incomplete designs as drafts and
finish their inputs before analysis.

`experiment.layout.application.statistics` creates a statistics draft from a
layout application. `acquisition.session.save` records instruments, operators,
acquisition timestamps and source membership.

Use `experiment.exclusion.set` to exclude a specimen or field, record a reason,
or clear an exclusion. Summaries and statistical inputs record the decisions in
use when calculated. Archiving and experimental exclusions are separate controls.

### Registered segmentation models

Register local Cellpose 3, Cellpose 4 / Cellpose-SAM, StarDist 2D, Omnipose and
micro-SAM models. `model.catalog` lists the files and controls for each backend.
`model.register` saves checkpoints and configuration; StarDist can also use a
thresholds file. Choose the Omnipose architecture or micro-SAM architecture and
AMG/AIS/APG mode during setup.

The desktop **Registered models** form shows the files and settings for the
chosen backend and keeps drafts when switching models. Probe compatibility and
capture the environment before running. Workflows, sweeps and distributed tasks
save the model and configuration used for their analysis.

### Large libraries and streamed packages

Indexed projects store image records, history and object tables separately.
Use `project.snapshot` with `selectedImageIds`, `image.list`, `project.history`
and `measurements.page` to read them. After `snapshot-changed`, start a new page
sequence. `image.get`, `measurements.lookup`, `mask.pick` and `mask.overlay` read
selected images, objects or labels directly.

Package2 exports combine a scientific snapshot and hash-verified artifact shards
in ZIP64. They include sources, labels, measurements and history. Sessions,
request receipts and local runtime configuration stay on the host.

`package.inspect` reads the manifest and snapshot; restoration verifies each
artifact. `package.restore.start`, `.get`, `.advance`, `.cancel` and `.resume`
use `expectedRestoreRevision` for restoration progress. Cancellation keeps
completed bytes so the restore can continue later. `package.restore` performs
the same work in one command.

Use `cellLimit` to choose how many object rows an analysis response returns.
`cellCount` is the complete count; `returnedCellCount` and `cellsTruncated`
describe the response. Read the full table through `measurements.page` and show
the saved labels with `mask.overlay`.

### Additional segmentation and assay workflows

Classical segmentation offers Otsu, manual, triangle, Li, Yen, mean and adaptive
thresholds, bright/dark polarity, automatic background selection and hole filling.
Adaptive thresholding uses an odd-sized pixel neighbourhood and an automatic or
manual offset.

Raw-intensity assay nodes can read source or processed pixels directly. N:C and
neurite assays connect nuclear and soma masks from matching image grids.

Scratch-wound series save observation order, timestamps and measured support.
They participate in dependency refresh. Replicate statistics can use one series
per specimen, with slope in pixel area, calibrated area or normalized closure per
second. Choose comparable time windows, processing and measured extents across
specimens.

<a id="retained-catalogue-navigation"></a>

### Browsing saved records

`project.snapshot` returns selected images and recent catalogue entries.
`cataloguePages` supplies totals and next-page cursors. Browse with
`project.catalogue`, read a version with `project.catalogue.get`, or request
several identities with `project.catalogue.getMany`.

Pin open entries with `selectedCatalogueEntries`. `project.activity` reads active
background and training jobs separately from history. Assignment targets use
image IDs; exclusion targets use `image:<id>` or `specimen:<id>`.

In Windows task sections, **Use in controls** makes an older record available in
a selector while keeping the current editor draft. Selections survive refreshes;
release a browser pin when finished with it. Exclusion controls show the selected
target's current decision, and statistical designs load their specimen assignments
from the experiment.
