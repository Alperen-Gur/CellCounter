# CellCounter for Windows 1.3.0

This release adds a project workbench whose GUI, CLI, Python SDK and MCP server share the same operations. The installed executable provides the `--workbench` entry point, and the AI agent access panel prepares scoped connection settings once the Workbench runtime is installed.

## Changes

- Import acquisitions, segment and correct exact masks, measure objects and assays, and export scientific images, tables and reproducible analysis packages.
- Save linear or branching workflows, run resumable jobs, compare parameter sweeps, and prepare or collect distributed work packets. Review gates and corrections keep their history.
- Use linked volume and slice displays, channel display presets, annotations, temporal analysis, experimental designs and result freshness plans.
- Open TIFF/NGFF regions, run tiled threshold analysis, and import raw regions from configured OMERO profiles.
- Browse indexed image and result catalogues page by page. Upgrade existing project stores, and resume package restoration from saved checkpoints.
- Use the shared layer workspace with source bindings, semantic paint journals, replay and generated-image provenance. Older workspace documents still open.

## Install

The MSI and NSIS installers include a Node runtime for the shared workspace engine. Install the Workbench Python runtime from **Workbench → AI agent access → Install or repair runtime**; model and OMERO environments are set up separately. Existing library data is preserved, and copying a library into a project starts with a preview.

Follow the [Windows guide](https://github.com/Alperen-Gur/Cellographer/blob/windows-v1.3.0/docs/WINDOWS.md) and [Workbench guide](https://github.com/Alperen-Gur/Cellographer/blob/windows-v1.3.0/docs/WORKBENCH.md).
