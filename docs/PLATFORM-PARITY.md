# Release status and feature parity

Current release series: **macOS 1.1.0**, **Windows 1.3.0** and **Web 0.3.2 preview**.

The native applications share the project Workbench engine and its GUI, CLI,
Python SDK and MCP operations. The browser remains a separate local PWA with a
smaller feature set. Historical library workflows and platform-specific model
installation tools remain available where they have distinct capabilities.

| Capability | macOS 1.1.0 | Windows 1.3.0 | Web 0.3.2 preview |
| --- | --- | --- | --- |
| Shared project GUI, installed CLI and MCP entry point | Included; dedicated runtime installed explicitly | Included; dedicated runtime installed explicitly | No native companion, CLI or MCP server |
| Exact masks, correction history and measurements | Plane and volume operations | Plane and volume operations | Browser classical analysis and bounded 2D correction |
| Registered learned models | Local checkpoint and explicit compatible interpreter | Local checkpoint and explicit compatible interpreter | Qualified learned artifacts are not bundled |
| Saved workflows and background execution | Linear and branching jobs, review gates, sweeps and isolated distributed packets | Same shared operations | Portable browser workflows and local jobs within browser limits |
| Project and catalogue storage | Indexed catalogues, explicit legacy migration and resumable package restore | Same shared operations | Browser-managed storage and bounded portable exports |
| Large and remote sources | Bounded TIFF/NGFF regions, supported tiled threshold analysis and configured OMERO raw-region import | Same shared operations | Portable local Zarr v2 workspace; no OMERO adapter |
| Layer workspace | Canonical bindings, semantic journals, replay and generated-image provenance | Same shared engine | Portable layers, painting, replay and GIF export within browser limits |
| Experimental results | Specimen assignments, typed statistical designs, temporal analyses and explicit result refresh plans | Same shared operations | Browser assays and descriptive workflows; no shared native statistics engine |
| Executable extensions | Explicit local installation/enabling and interpreter configuration | Same shared operations | No native executable plugins |

The native NGFF reader supports the documented 0.4/Zarr v2 and 0.5/Zarr v3
routes through pinned maintained libraries. This does not mean arbitrary codecs,
remote stores, unlimited data sizes or every analysis algorithm are supported.
The current tiled analysis path is a bounded plane threshold/connected-components
workflow; whole-series OMERO processing and general tiled learned-model inference
are not included. See the [Workbench guide](WORKBENCH.md) for operation limits.

Model availability depends on the selected interpreter, checkpoint and backend
configuration; a catalogue entry alone is not an installed or validated model.
The web app has no image-upload service. Its learned inference, proprietary
microscope readers and actual model training remain unavailable. Current native
Workbench import also does not claim proprietary VSI support. The browser's
[portable workspace guide](PORTABLE-WORKSPACE.md) lists its narrower format,
codec and coordinate behavior.

These are software capabilities, not evidence of complete commercial-tool parity,
biological accuracy or performance superiority. Local automated and nonvisual
build checks were performed for this release; interactive application and visual
verification were not performed. Windows installers are unsigned. macOS is
ad-hoc signed and not notarized. Publishing the static web ZIP does not create a
hosted service.

See the [Windows notes](releases/windows-v1.3.0.md),
[web notes](releases/web-v0.3.2.md), [installation guide](INSTALL.md), and
[Workbench guide](WORKBENCH.md). The detailed [feature tables](FEATURES.md)
retain a clearly labeled earlier release baseline; their counts are not current
completion percentages.

Opt-in local timing sessions and editable diagnostic exports remain available
across all three platforms. Recording starts only by user choice, and reports
have no automatic upload path.
