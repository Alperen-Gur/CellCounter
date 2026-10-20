# CellCounter for Windows 1.3.0

This release adds a project workbench with shared GUI, CLI, Python SDK and MCP operations. The installed executable provides the `--workbench` entry point; the AI agent access panel prepares scoped connection settings after the dedicated runtime is installed.

- Import acquisitions, segment and correct exact masks, measure objects and assays, and export scientific images, tables and reproducible analysis packages.
- Save linear or branching workflows, run resumable jobs, compare parameter sweeps, and prepare or collect isolated distributed work packets. Review gates and corrections retain their history.
- Use linked volume and slice displays, channel display presets, annotations, temporal analysis, explicit experimental designs and result freshness plans.
- Open bounded TIFF/NGFF regions, run the supported tiled threshold workflow, and import raw regions from explicitly configured OMERO profiles.
- Browse indexed image and result catalogues without treating the visible page as the complete experiment. Existing stores can be upgraded explicitly, and package restoration can resume at retained checkpoints.
- Use the shared layer workspace with preserved source bindings, semantic paint journals, replay and generated-image provenance. Historical documents retain a compatibility route.

The MSI and NSIS installers include a pinned Node runtime for the shared workspace engine. The separate Workbench Python runtime is installed or repaired explicitly; model and optional OMERO environments remain separate. Existing library data is preserved and legacy migration is previewed before copying retained evidence.

This is a software feature release, not evidence of superiority over other microscopy software. The browser preview has a smaller capability set. Local nonvisual build and automated checks were performed; native Windows packaging is validated by CI. Interactive application verification and biological accuracy benchmarking were not performed. Follow the [Windows guide](https://github.com/Alperen-Gur/CellCounter/blob/windows-v1.3.0/docs/WINDOWS.md) and [Workbench guide](https://github.com/Alperen-Gur/CellCounter/blob/windows-v1.3.0/docs/WORKBENCH.md) for supported operations and limits.
