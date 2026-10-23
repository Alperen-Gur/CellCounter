# Platform comparison

Current releases: **macOS 1.1.0**, **Windows 1.3.0** and **Web 0.3.2 preview**.

macOS and Windows share the project Workbench, CLI, Python SDK and MCP server.
CellCounter Web runs in your browser.

| Feature | macOS | Windows | Web preview |
| --- | --- | --- | --- |
| Local image analysis | ✓ | ✓ | ✓ |
| Project Workbench | ✓ | ✓ | Browser workspace |
| CLI, Python SDK and MCP | ✓ | ✓ | — |
| Classical segmentation | 2D and 3D | 2D and 3D | 2D |
| Learned segmentation | Cellpose, StarDist, Omnipose, micro-SAM | Cellpose, StarDist, Omnipose, micro-SAM | — |
| Mask correction and history | ✓ | ✓ | ✓ |
| Volume analysis | ✓ | ✓ | — |
| Tracking and lineage | ✓ | ✓ | Sequence tracking and layer links |
| Reusable analysis | Branching workflows, sweeps and review gates | Branching workflows, sweeps and review gates | Saved settings, jobs and workspace replay |
| Background processing | Local workers and portable work packets | Local workers and portable work packets | Browser workers |
| Large-image tools | TIFF/NGFF regions and tiled threshold analysis | TIFF/NGFF regions and tiled threshold analysis | Local Zarr v2 sources |
| OMERO import | ✓ | ✓ | — |
| Experiments and statistics | Specimens, plates, conditions and statistical designs | Specimens, plates, conditions and statistical designs | Assays and condition summaries |
| Result refresh after edits | ✓ | ✓ | — |
| Executable plugins | Readers, segmentation, measurements and exporters | Readers, segmentation, measurements and exporters | — |
| Project storage | Project folders and image library | Project folders and image library | Browser storage |
| Export | Scientific files and analysis packages | Scientific files and analysis packages | Images, tables, reports, datasets and workspace files |

## Installation and privacy

macOS requires version 15 or later and supports Intel and Apple Silicon. Windows
requires Windows 10/11 x64 and WebView2. For the browser edition, serve the release
files over HTTPS or localhost.

Images are processed locally. Runtime and model setup downloads the required
packages and weights. OMERO connects to the server you configure. Diagnostic
reports are saved locally when you choose to export them.

Keep original images and back up your projects. In the browser, export important
results before clearing site data or changing browser profiles.

See [macOS installation](INSTALL.md), [Windows installation](WINDOWS.md),
the [browser guide](WEB.md), [features](FEATURES.md) and the
[Workbench guide](WORKBENCH.md).
