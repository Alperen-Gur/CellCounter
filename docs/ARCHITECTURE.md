# CellCounter architecture

CellCounter has a native macOS app, a Windows desktop app and a browser preview.
The desktop Workbench shares its analysis runtime with the CLI, Python SDK and
MCP server. The browser uses shared image and workspace components with its own
local processing and storage.

For usage, see [features](FEATURES.md), [platforms](PLATFORM-PARITY.md) and the
[Workbench guide](WORKBENCH.md).

## Applications and shared components

| Component | Location | Responsibility |
| --- | --- | --- |
| Native macOS app | [`CellCounting/`](../CellCounting/) | SwiftUI interface, SwiftData library, native services and Workbench client |
| Windows app | [`desktop/`](../desktop/) | React/TypeScript interface, Tauri/Rust host, SQLite library and Workbench client |
| Browser preview | [`web/`](../web/) | React PWA, browser storage and worker-based processing |
| Analysis runtime and SDK | [`shared/python/`](../shared/python/) | Operations, projects, analysis, CLI, SDK and MCP |
| Operation contracts | [`shared/workbench/`](../shared/workbench/) | TypeScript requests, responses and domain types |
| Microscopy engine | [`shared/microscopy/`](../shared/microscopy/) | Coordinates, layers, annotations, painting, registration, lineage and animation |
| Microscopy worker | [`shared/microscopy-worker/`](../shared/microscopy-worker/) | Node worker protocol and runtime packaging |
| Volume viewer | [`shared/viewer/`](../shared/viewer/) | Volume display and host communication |

## Shared Workbench operations

macOS sends requests through
[`WorkbenchService.swift`](../CellCounting/Services/WorkbenchService.swift).
Windows uses [`client.ts`](../desktop/src/kernel/workbench/client.ts) and the
[Rust bridge](../desktop/src-tauri/src/workbench.rs). Installed apps also forward
`--workbench` commands to their configured runtime.

[`workbench.py`](../shared/python/workbench.py) dispatches operations.
[`workbench_sdk.py`](../shared/python/workbench_sdk.py) provides the Python client;
[`_workbench_mcp.py`](../shared/python/_workbench_mcp.py) provides MCP access.
Analysis lives in this runtime, so clients use the same implementation.

Requests contain a schema version, operation, arguments, request ID and actor.
Writes include the expected project revision. Stale writes return a conflict;
retrying the same request uses its original envelope. Session navigation has a
separate revision. Clients discover operations and argument schemas at runtime.
See the [Workbench guide](WORKBENCH.md) for requests, errors and setup examples.

## Projects and application libraries

Projects contain `workbench.sqlite` and an `artifacts/` folder. Sources, masks,
measurements, workflows and edit history are linked by IDs and hashes.
Measurements use source pixels or saved processed intensities. Display colors
and rendering settings affect the view.

Indexed storage provides paged image, history and measurement reads. Cursors
refer to a project revision and filter set. Selection and mask picking work
independently of the currently loaded table page.

The original application libraries use platform-specific storage. Windows uses
[`desktop/src-tauri/src/db/`](../desktop/src-tauri/src/db/) and the locations in
[`paths.rs`](../desktop/src-tauri/src/paths.rs); macOS uses SwiftData. Library
migration previews and copies data into a project, preserving the original.

Portable packages contain a project snapshot and hash-verified artifacts.
Restoration writes a new destination and verifies the contents. Configure and
enable restored models or plugins locally before running them. See
[storage and packages](WORKBENCH.md#large-libraries-and-streamed-packages).

## Scientific runtimes and workers

Desktop library detection and the Workbench have separately managed analysis
environments. Set up model packages and checkpoints in a compatible environment.
Reporting, OME-Zarr and OMERO dependencies have their own setup instructions.

Local workers run analysis and adaptation in the background. Jobs save settings,
source references and checkpoints, so work can continue after an interruption.
Review gates and dependency refresh use the same job state.

The TypeScript layer engine runs in a packaged Node runtime on desktop. Its
manifest identifies the worker and engine files. Browser builds run the browser
components directly.

The Windows library separates inference and persistence with
[`InferenceTransport`](../desktop/src/kernel/transport/InferenceTransport.ts) and
[`PersistencePort`](../desktop/src/kernel/persistence/PersistencePort.ts). Rust
handles files, storage, environments and processes. Python workers return
analysis results and progress.

## Browser execution

TIFF decoding, segmentation, assays and exports run in Web Workers. IndexedDB
stores metadata, and browsers with OPFS support keep source files there. Startup
loads metadata and thumbnails before decoding an active image.

The static build provides classical segmentation and a browser workspace editor.
See the [browser guide](WEB.md) and [portable workspace guide](PORTABLE-WORKSPACE.md)
for usage and development.

## Permissions and external services

Image analysis runs locally. Model and runtime setup can download upstream
packages and weights. OMERO imports read from configured servers.

MCP starts read-only. Grant write access, external paths, executable operations
and network profiles as needed. Plugins run in configured local Python
environments with the user's permissions. Credentials, interpreter bindings and
access grants stay local to the host.

## Development references

- [macOS installation](INSTALL.md)
- [Windows development and packaging](../desktop/README.md#development)
- [Browser development](../web/README.md#run-locally)
- [Python SDK installation and usage](../shared/python/README.md)
- [Contribution guidelines](../CONTRIBUTING.md)

Application manifests and [CI workflows](../.github/workflows/) contain build
commands and dependency versions. Keep operation behavior consistent across
clients when changing shared contracts.
