# CellCounter architecture

CellCounter has a native macOS application, a Windows desktop application and a
browser preview. The desktop Workbench shares a scientific operation runtime
across its graphical interface, command-line interface, Python SDK and Model
Context Protocol (MCP) server. The browser shares portable image and workspace
components but does not run the filesystem-backed Python Workbench.

This document describes the public source structure. For supported features and
limits, use the [feature matrix](FEATURES.md), [platform comparison](PLATFORM-PARITY.md)
and [Workbench guide](WORKBENCH.md).

## Applications and shared components

| Component | Location | Responsibility |
| --- | --- | --- |
| Native macOS application | [`CellCounting/`](../CellCounting/) | SwiftUI interface, SwiftData image library, native services and Workbench client |
| Windows application | [`desktop/`](../desktop/) | React/TypeScript interface, Tauri/Rust host, SQLite image library and Workbench client |
| Browser preview | [`web/`](../web/) | Static React PWA, browser storage and local worker-based processing |
| Scientific runtime and SDK | [`shared/python/`](../shared/python/) | Operation schemas, project persistence, scientific analysis, CLI, SDK and MCP |
| Typed operation contracts | [`shared/workbench/`](../shared/workbench/) | TypeScript request/response and domain contracts used by desktop clients |
| Portable microscopy engine | [`shared/microscopy/`](../shared/microscopy/) | Source coordinates, layers, annotations, painting, registration, lineage and animation |
| Microscopy worker | [`shared/microscopy-worker/`](../shared/microscopy-worker/) | Validated Node worker protocol and runtime packaging |
| Volume viewer | [`shared/viewer/`](../shared/viewer/) | Shared sampled-volume display and host communication |

## Shared Workbench operations

The macOS client sends operation requests through
[`WorkbenchService.swift`](../CellCounting/Services/WorkbenchService.swift).
The Windows client uses
[`client.ts`](../desktop/src/kernel/workbench/client.ts) and the
[Rust Workbench bridge](../desktop/src-tauri/src/workbench.rs).
The installed applications also route `--workbench` commands to their configured
scientific runtime.

The common dispatcher is [`workbench.py`](../shared/python/workbench.py).
[`workbench_sdk.py`](../shared/python/workbench_sdk.py) provides the Python client,
and [`_workbench_mcp.py`](../shared/python/_workbench_mcp.py) provides the MCP
adapter. Scientific behavior belongs to the shared runtime rather than a separate
implementation in each client.

A request carries a schema version, operation, arguments, request ID, actor and,
for scientific mutations, an expected project revision. The runtime validates the
operation schema and rejects stale changes. An exact retry uses the original
request identity and envelope. Client-session navigation has its own revision
and does not advance the scientific project revision.

Clients discover available operations and their argument schemas at runtime.
Optional dependencies, executable bindings and source limits affect readiness;
a visible operation or model entry alone does not establish that it can run.
The [Workbench guide](WORKBENCH.md) documents request envelopes, compact MCP
discovery, errors and configuration examples.

## Projects and application libraries

Workbench projects are user-selected directories containing `workbench.sqlite`
and content-addressed files in `artifacts/`. Source bytes, exact labels,
measurements, workflows and scientific history remain linked by retained
identities and hashes. Measurements use source pixels or explicitly recorded
processed intensities; display sampling and channel colors do not change them.

New projects use indexed storage with paged library, history and measurement
reads. Page cursors belong to a specific revision and filter set. Displaying a
page does not make it the complete experiment, and selecting an off-page object
does not require treating a sampled table as authoritative geometry.

The existing macOS and Windows image libraries have separate persistence
implementations. The Windows library uses the schema in
[`desktop/src-tauri/src/db/`](../desktop/src-tauri/src/db/) and application-data
paths in [`paths.rs`](../desktop/src-tauri/src/paths.rs); it does not attach to the
macOS SwiftData database. Previewed migration copies supported library evidence
into a Workbench project while retaining the original library.

Portable project packages retain scientific snapshots and hash-verified
artifacts. Host-local runtime configuration and client-session metadata do not
travel with the current indexed package format. Restoration uses a new
destination, verifies retained content and leaves model/plugin execution
disabled. See [storage and packages](WORKBENCH.md#large-libraries-and-streamed-packages).

## Scientific runtimes and workers

Desktop library detection and the Workbench use separately managed analysis
environments. Learned methods require their compatible packages and exact model
checkpoints; the Workbench does not install them implicitly during an operation.
Optional reporting, OME-Zarr and OMERO dependencies have explicit setup paths.

Analysis and adaptation can run through local background workers. Saved jobs
retain checkpoints, settings and source bindings. Interruption does not authorize
silently restarting a process or rebasing a saved job after scientific inputs
change. Workflow review gates and dependency refresh use the same retained
operation state.

The shared layer engine is compiled from TypeScript and runs in a pinned Node
runtime for desktop integrations. Its manifests bind the packaged code and
runtime files. Browser integrations use the compatible browser components
without launching Node or Python.

The Windows library's frontend separates inference and persistence through
[`InferenceTransport`](../desktop/src/kernel/transport/InferenceTransport.ts)
and [`PersistencePort`](../desktop/src/kernel/persistence/PersistencePort.ts).
Rust owns filesystem access, library persistence, environment setup and process
lifecycle. Python workers return structured scientific results and progress.
These library interfaces coexist with the project Workbench dispatcher.

## Browser execution

The browser preview has its own local application state and storage. TIFF
decoding, segmentation, assays and full-resolution exports run in dedicated
Web Workers. IndexedDB stores metadata; supported browsers use OPFS for source
blobs. Startup can restore metadata and thumbnails before decoding an active
source.

The static build supplies classical segmentation. Learned-model browser entries
require qualified artifacts and remain unavailable in the published preview.
There is no desktop companion, filesystem-backed Workbench, installed-app CLI or
MCP server. Browser workspace planes, imports and exports have independent memory
and format limits; see the [browser guide](WEB.md) and
[portable workspace guide](PORTABLE-WORKSPACE.md).

## Permissions and external services

Ordinary image analysis is local. Runtime and model installation can download
upstream packages and weights. Optional OMERO imports read from explicitly
configured servers; they do not upload image results.

MCP connections start read-only and restrict project/path access. Writes,
executable operations, runtime configuration and network profiles require their
applicable grants. Actor labels are retained provenance, not authenticated
reviewer identities. Executable plugins run in configured local environments;
the plugin mechanism is not a security sandbox.

Credentials, local interpreter bindings and execution grants stay outside
portable scientific packages. No ordinary operation silently installs software
or enables restored executable content.

## Development references

- [macOS installation](INSTALL.md)
- [Windows development and packaging](../desktop/README.md#development)
- [Browser development](../web/README.md#run-locally)
- [Python SDK installation and usage](../shared/python/README.md)
- [Contribution guidelines](../CONTRIBUTING.md)

Current dependency requirements and build commands are maintained in the
application manifests and [CI workflows](../.github/workflows/). Changes to
operation contracts should preserve explicit revision, provenance and permission
semantics across the clients that expose them.
