<div align="center">

<img src="docs/branding/CellCounter-icon.png" alt="CellCounter app icon" width="112" height="112">

# CellCounter

**A local microscopy workbench for segmentation, measurement and reproducible analysis.**

Import images, review and correct cell masks, quantify experiments, and export results with their analysis history.

[![macOS](https://img.shields.io/badge/macOS-1.1.0-0a7ea4?logo=apple&logoColor=white)](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.1.0)
[![Windows](https://img.shields.io/badge/Windows-1.3.0-0078D4?logo=windows11&logoColor=white)](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0)
[![Web](https://img.shields.io/badge/Web-0.3.2%20preview-5b5bd6?logo=pwa&logoColor=white)](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.3.2)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[Download](#download) · [Features](#features) · [Comparison](#feature-comparison) · [Quick start](#quick-start) · [AI-agent access](#automation-and-ai-agents) · [Documentation](#documentation)

</div>

---

CellCounter brings image analysis, manual correction and experimental results into one project. The desktop
Workbench shares its operations across the graphical interface, command line, Python SDK and Model Context
Protocol (MCP), so researchers and AI agents can work with the same saved masks, measurements and history.

No account is required. Image analysis runs locally, with optional model installation and explicitly configured
connections to your own image server.

## Download

| Edition | Requirements | Download |
| --- | --- | --- |
| **macOS 1.1.0** | macOS 15 or later; Apple silicon or Intel | [Universal application](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.1.0) |
| **Windows 1.3.0** | Windows 10 or 11, 64-bit | [EXE and MSI installers](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0) |
| **Web 0.3.2 preview** | A supported modern browser; served over HTTPS or localhost | [Static PWA package](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.3.2) |
| **Python SDK 0.1.0** | Python 3.11 or later and the required analysis dependencies | [Wheel and source package](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.1.0) |

The desktop apps install their dedicated Workbench runtime when you choose **Install or repair**. Learned
models require separately configured compatible environments and checkpoints.

**Installation:** follow the [macOS guide](docs/INSTALL.md) or [Windows guide](docs/WINDOWS.md).
The macOS app is ad-hoc signed and not notarized; Windows installers are unsigned. The guides explain the
first-launch security prompts and download checksums.

The **web preview** provides browser-local classical segmentation, measurements, assays and portable workspaces.
It has a smaller feature set: learned inference, model training and the desktop CLI/MCP runtime are unavailable.
See the [web guide](docs/WEB.md) and [platform comparison](docs/PLATFORM-PARITY.md).

## Features

| Capability | What you can do |
| --- | --- |
| **Segmentation and correction** | Preview classical threshold/watershed segmentation or use registered local models. Edit exact instance masks with polygon and brush tools, merge or split objects, compare mask variants, and retain correction history. |
| **Measurements and assays** | Quantify counts, morphology, calibrated size, fluorescence, marker positivity, colocalization, confluence, wound closure and other supported assays. Inspect measurements alongside their source images. |
| **Multidimensional imaging** | Select channels, Z planes and time points; inspect linked orthogonal and volume views; analyze supported 3D volumes and curate tracking and lineage results. |
| **Repeatable workflows** | Save linear or branching analysis workflows, run parameter sweeps, review intermediate results and resume interrupted jobs from saved checkpoints. |
| **Experiments and review** | Organize conditions, plates and biological specimens. Review detector disagreement and quality indicators, retain decisions, and run supported specimen-level statistical designs. |
| **Traceable results** | Recompute mask measurements after corrections, identify stale dependent results, and use explicit refresh plans. Export scientific files, reports and portable project packages with parameters and provenance. |

Registered desktop model adapters include **Cellpose 3**, **Cellpose 4 / Cellpose-SAM**, **StarDist 2D**,
**Omnipose** and **micro-SAM**. Availability depends on the selected interpreter, checkpoint and configuration.
Classical segmentation works without learned model weights.

The Workbench reads supported raster images and TIFF/OME-TIFF acquisitions, with bounded TIFF and OME-NGFF
region access and read-only region import from configured OMERO servers. Optional microscope readers in the
existing image-library workflow have separate requirements and capabilities.

See the [feature guide](docs/FEATURES.md) for the current inventory and the [Workbench guide](docs/WORKBENCH.md)
for operation-specific formats, parameters and limits.

## Feature comparison

Selected open-source microscopy tools, based on documentation reviewed on **23 October 2026**.
CellCounter entries describe the released desktop Workbench; the web preview has a smaller feature set.

**✓** documented support · **Plugin** supplied through an extension, which may be bundled ·
**Limited** a narrower implementation · **?** not established by the cited documentation.
Text in a cell identifies the supported route or scope. Support does not imply equivalent methods or performance.

| Feature | **CellCounter** | [Cell-ACDC](https://cell-acdc.readthedocs.io/en/stable/) | [Fiji / ImageJ](https://imagej.net/learn/) | [napari](https://napari.org/stable/) | [CellProfiler](https://cellprofiler.org/) | [QuPath](https://qupath.readthedocs.io/en/stable/) |
| --- | :---: | :---: | :---: | :---: | :---: | :---: |
| Classical segmentation | ✓ | ✓ | ✓ | Plugin | ✓ | ✓ |
| Learned segmentation | 2D | ✓ | Plugin | Plugin | Plugin | Plugin |
| Manual mask / object correction | ✓ | ✓ | ✓ | ✓ | 2D | ROIs / objects |
| Morphology and fluorescence measurements | ✓ | ✓ | ✓ | Plugin | ✓ | ✓ |
| 3D segmentation | Limited | ✓ | Plugin | Plugin | Selected modules | ? |
| Object tracking | Limited | ✓ | TrackMate | Plugin | 2D | ? |
| Lineage / division annotation | Reviewed proposals | ✓ | TrackMate | Plugin | 2D | ? |
| Large, multiscale image viewing | Selected regions | ? | BigDataViewer | ✓ | ? | ✓ |
| Reusable analysis | Workflows | Saved recipes | Macros / scripts | Plugins / scripts | Pipelines | Scripts |
| Batch analysis | ✓ | ✓ | ✓ | Scripts / plugins | ✓ | ✓ |
| Script / API access | CLI / Python SDK | CLI / Python interfaces | Macros / APIs | Python API | CLI / Python modules | Groovy / CLI |
| MCP tools for AI agents | ✓ | ? | Plugin | Plugin | ? | ? |

CellCounter's 3D analysis is bounded to **8 million voxels per selected volume**; learned adapters currently
run in 2D. Large-source viewing does not imply tiled support for every analysis. Tracking includes reviewed
division proposals. CellProfiler's manual editing and tracking modules are 2D; other modules support 3D.
Fiji and napari MCP access requires optional extensions.

See the [detailed comparison](docs/COMPARISON.md) for **commercial software**, sources, plugin requirements
and the distinctions behind these entries. This is a capability guide, not an accuracy, speed or usability ranking.

## Quick start

1. **Set up.** Install the desktop app, open **Workbench**, and install or repair its dedicated runtime.
2. **Import.** Create a local project, add images, and confirm the source channel, projection and spatial calibration.
3. **Analyze.** Preview segmentation on a representative image, adjust settings, then save the masks and measurements.
4. **Review.** Correct masks, inspect quality indicators and run the relevant assays. Assign biological specimens before condition-level statistical analysis, and resolve stale results after changes.
5. **Export.** Save a reusable workflow, export labels and measurement tables, or create a portable analysis package with source data, settings and history.

Existing image libraries remain available. The migration tools preview a copy into a new Workbench project
while preserving the original library. Start with the [desktop walkthrough](docs/WORKBENCH.md#desktop-workflow).

## Automation and AI agents

Use the interface that fits your work without maintaining separate analysis implementations.

| Interface | Use |
| --- | --- |
| **Desktop GUI** | Set up analyses, inspect images, correct masks and review results interactively. |
| **Command line** | Run documented operations from scripts and receive structured JSON responses. |
| **Python SDK** | Work with projects through `WorkbenchClient` and the shared operation dispatcher. |
| **MCP server** | Give a compatible AI client scoped access to project inspection, analysis, correction and export. |

The desktop **AI agent and command-line access** panel prepares connection settings for the installed app.
Project revisions prevent stale clients from silently overwriting later changes; request identifiers support
exact retries. Read, write, external-path and executable-code permissions are explicit.

Follow the [CLI examples](docs/WORKBENCH.md#cli-example), [Python SDK guide](docs/WORKBENCH.md#python-sdk)
or [MCP connection guide](docs/WORKBENCH.md#mcp-connection). The browser preview does not host this runtime.

## Local data and reproducibility

Desktop analysis runs on your computer; the web preview processes imported images inside the browser.
CellCounter has no automatic image-upload or remote-inference service. Runtime and model installation may
download software or weights. The optional OMERO adapter reads selected data from a server you configure,
and executable plugins run code you explicitly enable.

Keep a project's folder intact, and retain exported analysis packages alongside the scientific results.
Packages preserve source data, masks, workflow definitions, parameters and history; reopening a package does
not automatically install dependencies or execute plugins. Model versions, runtime dependencies and computing
devices can affect segmentation results.

## Current scope

- **3D analysis is bounded.** Each selected scientific volume is limited to 8 million voxels. Volume rendering
  samples at most 128 points per axis; saved scientific measurements use the original voxels.
- **Large-source support is operation-specific.** Region access and tiled threshold/connected-components
  analysis are available; general tiled learned-model inference is not included.
- **Learned adapters are currently 2D.** Model availability does not imply support for every acquisition,
  device or 3D workflow. Division suggestions and propagated corrections require review.
- **Statistical inference requires a declared experimental design.** Use biological-specimen assignments in
  the Workbench. The existing library's pooled-cell comparison is descriptive and does not establish
  independent biological replication.

Consult [current scope and troubleshooting](docs/WORKBENCH.md#current-scope-and-troubleshooting) and
[platform differences](docs/PLATFORM-PARITY.md) before planning a workflow.

## Documentation

| Guide | Contents |
| --- | --- |
| [Installation](docs/INSTALL.md) | macOS setup, runtime installation and first-launch help |
| [Windows](docs/WINDOWS.md) · [Web preview](docs/WEB.md) | Platform-specific installation, workflows and troubleshooting |
| [Features](docs/FEATURES.md) · [Platform comparison](docs/PLATFORM-PARITY.md) | Supported capabilities and edition differences |
| [Software comparison](docs/COMPARISON.md) | Open-source and commercial alternatives, feature qualifications and primary sources |
| [Workbench](docs/WORKBENCH.md) | Analysis, correction, workflows, experiments, export, CLI, SDK and MCP |
| [Portable workspace](docs/PORTABLE-WORKSPACE.md) | Browser workspace formats, coordinates, layers and limits |
| [Releases](https://github.com/Alperen-Gur/CellCounter/releases) | Downloads, checksums and version history |
| [Contributing](CONTRIBUTING.md) | Building from source, reporting bugs and contributing changes |

## Support and citation

Report problems or request features in [GitHub Issues](https://github.com/Alperen-Gur/CellCounter/issues).
Include your application version, operating system, relevant settings and steps to reproduce the problem.
Share only image data or logs you are permitted to disclose.

If you use CellCounter in research, cite the software using [CITATION.cff](CITATION.cff) and cite the segmentation
models and methods used in your analysis. Record the application and model versions in your methods.

CellCounter builds on open-source scientific software, including [Cellpose](https://github.com/MouseLand/cellpose),
[StarDist](https://github.com/stardist/stardist) and [Omnipose](https://github.com/kevinjohncutler/omnipose).
See [third-party acknowledgments and licenses](THIRD_PARTY_LICENSES.md).

## License

CellCounter source code is available under the [MIT License](LICENSE). Optional dependencies and model weights
retain their respective licenses.
