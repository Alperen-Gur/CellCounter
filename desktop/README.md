<div align="center">

# CellCounter for Windows

Local microscopy analysis, reproducible workflows and AI-agent access.

[![Windows release](https://img.shields.io/badge/Windows-v1.3.0-0078D4?logo=windows11&logoColor=white)](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0)
[![CI](https://img.shields.io/github/actions/workflow/status/Alperen-Gur/CellCounter/windows.yml?branch=main&label=Windows%20build)](https://github.com/Alperen-Gur/CellCounter/actions/workflows/windows.yml)
[![License](https://img.shields.io/badge/license-MIT-blue)](../LICENSE)

[Download](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0) · [Windows guide](../docs/WINDOWS.md) · [Workbench guide](../docs/WORKBENCH.md) · [Main project](../README.md)

</div>

CellCounter 1.3.0 combines an image library and batch-analysis interface with a
project-based microscopy workbench. Import images, segment and correct objects,
measure signals, review results and export images, tables or portable analysis
packages. The Windows application uses React and a native Tauri shell.

## Features

- **Image analysis:** local classical and learned segmentation, calibrated
  morphology, fluorescence measurements and microscopy assays.
- **Interactive review:** linked images and measurements, exact mask corrections,
  saved alternatives, review queues and retained decisions.
- **Project workflows:** branching analysis graphs, parameter sweeps, resumable
  jobs and correction-aware result refresh.
- **Multidimensional data:** channel displays, linked slice and volume views,
  temporal analysis and bounded TIFF/NGFF region processing.
- **Experiments and reporting:** specimens, plates, conditions, declared
  statistical designs and versioned scientific exports.
- **Automation:** the same Workbench operations through the GUI, installed-app
  CLI, Python SDK and scoped Model Context Protocol (MCP) server.

Some functions require separately installed local runtimes or model checkpoints.
Format, memory and algorithm limits are documented in the
[Workbench guide](../docs/WORKBENCH.md#current-scope-and-troubleshooting).
See the [feature matrix](../docs/FEATURES.md),
[platform comparison](../docs/PLATFORM-PARITY.md) and
[1.3.0 release notes](../docs/releases/windows-v1.3.0.md) for the current scope.

## Install and get started

1. Download the `.exe` or `.msi` and `SHA256SUMS.txt` from the
   [Windows release](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0).
2. Verify the download hash and install. Choose the `.exe` for a standard
   workstation installation or the `.msi` for managed deployment. The current
   installers are unsigned.
3. Open **CellCounter** and install the required analysis runtime or model from
   **Models**.
4. Open **Workbench**, create a project, import images and preview an analysis
   before saving results.

Windows 10 or 11 on x64 is required. End users do not need to install Node.js,
Rust or Python manually. Internet access is needed to provision optional analysis
environments and download model weights. See the [Windows guide](../docs/WINDOWS.md)
for requirements, upgrades, backup and troubleshooting.

## Automation and AI agents

The installed executable exposes `--workbench` for command-line operations and
MCP connections. Use the **AI agent access** panel to prepare a connection with
explicit project and path permissions. MCP connections are read-only by default;
writes and executable operations require separate grants.

For setup and examples, see [CLI usage](../docs/WORKBENCH.md#cli-example),
[MCP connections](../docs/WORKBENCH.md#mcp-connection) and the
[Python SDK](../shared/python/README.md).

## Data and privacy

Imported images, inference, measurements and corrections are processed locally.
CellCounter does not automatically upload images or diagnostic reports. Model
installation downloads packages and weights; optional OMERO operations connect
only to explicitly configured servers for read-only imports. Executable plugins
run locally with the authority of their configured environment and should be
enabled only when trusted.

Workbench projects are separate from the existing image library. Use the
previewed migration tools to copy supported library evidence into a project.
Back up project folders and application data before upgrades.

## Development

Build requirements are Node.js 22.18.x, Rust 1.88 or newer, and the
[Tauri 2 Windows prerequisites](https://v2.tauri.app/start/prerequisites/), including
Microsoft C++ Build Tools and WebView2. Run these commands from `desktop/`:

```powershell
npm ci
npm run verify:windows
npm run tauri -- dev
```

Build native installers on 64-bit Windows:

```powershell
npm ci
npm run build
cargo test --manifest-path src-tauri/Cargo.toml --locked
npm run build:windows
node scripts/verify-windows-artifacts.mjs --write-checksums
```

Bundles are written below `src-tauri/target/release/bundle/`. The
[Windows workflow](../.github/workflows/windows.yml) contains the complete pinned
packaging procedure. See [architecture](../docs/ARCHITECTURE.md) and
[contributing](../CONTRIBUTING.md) for the repository structure and development
guidance.

## License

CellCounter is MIT licensed. Model weights and optional dependencies have their
own terms; see [LICENSE](../LICENSE) and
[third-party notices](../THIRD_PARTY_LICENSES.md).
