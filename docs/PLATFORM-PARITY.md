# Platform comparison

Current releases: **macOS 1.1.0**, **Windows 1.3.0** and **Web 0.3.2 preview**.

The desktop applications share the project Workbench, including its GUI, installed
CLI, Python SDK and MCP operations. The browser is a separate local PWA with a
smaller feature set. Existing image-library and portable workspace tools have
their own platform-specific behavior.

| Capability | macOS 1.1.0 | Windows 1.3.0 | Web 0.3.2 preview |
| --- | --- | --- | --- |
| Local analysis | Yes | Yes | Yes, within browser limits |
| Shared project Workbench | Yes; explicitly installed Python runtime | Yes; explicitly installed Python runtime | Not included |
| Installed CLI and MCP server | Yes; scoped project and executable-code permissions | Yes; same shared operations | Not included |
| Python SDK | Standalone package using the shared dispatcher | Same package and operations | Not used by the browser |
| Classical segmentation | Planes and selected volumes | Same shared operations | Bounded planes |
| Registered learned models | Explicit compatible local interpreter and checkpoint | Same shared adapters; backend compatibility depends on local environment | Qualified production artifacts are not bundled |
| Exact masks and correction history | Plane and volume operations | Same shared operations | Bounded 2D correction and saved alternatives |
| Volume analysis and display | Original-voxel analysis with linked slices and sampled rendering | Same shared operations | Plane-based workspace; no shared scientific volume engine |
| Tracking and lineage | Shared tracking, temporal inference and reviewed lineage operations | Same shared operations | Bounded sequence tracking and portable layer relationships |
| Saved workflows | Linear/branching graphs, sweeps and review gates | Same shared operations | Portable recorded workspace operations and local processing jobs |
| Background and portable tasks | Local workers and explicit distributed work packets | Same shared operations | Browser workers; no native task worker |
| Large and remote sources | Bounded TIFF/NGFF regions, tiled threshold analysis and configured OMERO raw-region import | Same shared operations | Local Zarr v2 workspace within its format/codec limits; no OMERO adapter |
| Experiments and statistics | Biological specimens, typed statistical designs and retained reports | Same shared operations | Browser assays and descriptive comparisons; not the shared specimen-statistics engine |
| Dependent-result refresh | Stale-result reporting and explicit refresh plans | Same shared operations | Browser result/protocol behavior; not the shared refresh engine |
| Executable plugins | Local reader, segmentation, measurement and exporter roles | Same shared operations | Native executable plugins not included |
| Project storage | Filesystem projects and indexed catalogues | Same shared format | Browser-managed metadata and source storage |
| Portable exports | Scientific files and resumable analysis packages | Same shared operations | File downloads, sample/dataset exports and portable workspace documents within browser bounds |

## Shared desktop limits

- Standard imported sources are bounded to 512 MiB and 256 MiB decoded data;
  selected planes to 16 million pixels and selected scientific volumes to
  8 million voxels. Some operations have narrower limits.
- Volume rendering samples at most 128 values per axis. Original voxels remain
  authoritative for supported scientific measurements and edits.
- Registered learned-model adapters perform 2D inference. General tiled
  learned-model inference and whole-series OMERO processing are not included.
- NGFF supports the documented 0.4/Zarr v2 and 0.5/Zarr v3 routes. This does not
  imply arbitrary codec, remote-store or unlimited-size support.
- General conditional workflow execution and automated cluster scheduling are
  not included. Portable work packets use explicit transfer and collection.
- Model availability requires the correct installed packages, checkpoint and
  interpreter. A catalogue entry alone does not establish readiness or hardware
  acceleration. The bundled Windows model-installation paths use CPU inference.

The shared Workbench does not provide a built-in VSI reader. Existing library
importers and model installers are separate routes; their format or checkpoint
coverage must not be inferred from this table.

## Browser limits

The browser has no native companion, filesystem-backed Python Workbench or
installed MCP server. It does not include proprietary microscope readers,
validated learned-model weights or live model training. Its local Zarr reader
supports a narrower set of formats and codecs than the desktop NGFF reader.
Browser quotas and site-data deletion can remove local work; export important
results and retain the original images.

See the [browser guide](WEB.md) and [portable workspace guide](PORTABLE-WORKSPACE.md)
for the browser's coordinate, source and export behavior.

## Installation and privacy

macOS requires version 15 or later and supports Intel and Apple Silicon. Its
download is ad-hoc signed and not notarized. Windows provides unsigned x64 MSI
and NSIS installers for Windows 10/11 and requires WebView2. The browser archive
contains static files to serve over HTTPS or localhost; downloading it does not
create a hosted service.

Analysis is local by default. Initial runtime/model downloads, explicitly
configured OMERO access and trusted executable extensions have their own network
requirements. Optional timing reports and diagnostics are previewed and exported
locally; the application does not upload them automatically.

See [macOS installation](INSTALL.md), [Windows installation](WINDOWS.md),
[current features](FEATURES.md) and the [Workbench guide](WORKBENCH.md).
