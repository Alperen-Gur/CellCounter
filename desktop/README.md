<div align="center">

# CellCounter for Windows

Local microscopy analysis, repeatable workflows and AI-agent access.

[![Windows release](https://img.shields.io/badge/Windows-v1.3.0-0078D4?logo=windows11&logoColor=white)](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0)
[![CI](https://img.shields.io/github/actions/workflow/status/Alperen-Gur/CellCounter/windows.yml?branch=main&label=Windows%20build)](https://github.com/Alperen-Gur/CellCounter/actions/workflows/windows.yml)
[![License](https://img.shields.io/badge/license-MIT-blue)](../LICENSE)

[Download](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0) · [Windows guide](../docs/WINDOWS.md) · [Workbench guide](../docs/WORKBENCH.md) · [Main project](../README.md)

</div>

Import images, segment and correct cells, measure signals and export results.
CellCounter combines a batch image library with a project workbench, built with
React and Tauri.

## Features

- Classical and learned segmentation, calibrated measurements and microscopy assays
- Linked images and tables, mask corrections, review queues and saved alternatives
- Branching workflows, parameter sweeps, resumable jobs and result refresh
- Channel, slice and volume views, tracking and TIFF/NGFF region processing
- Specimens, plates, conditions, statistics and scientific reports
- Shared GUI, CLI, Python SDK and Model Context Protocol (MCP) operations

See [features](../docs/FEATURES.md), the
[platform comparison](../docs/PLATFORM-PARITY.md) and
[release notes](../docs/releases/windows-v1.3.0.md).

## Install and get started

1. Download the `.exe` or `.msi` and `SHA256SUMS.txt` from the
   [Windows release](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0).
2. Check the hash and install. Use `.exe` for a standard workstation or `.msi`
   for managed deployment. The installers are unsigned.
3. Open **Workbench → AI agent access → Install or repair runtime**.
4. Create a project, import images and preview segmentation.

Requires Windows 10/11 x64. The app sets up its Python environments and downloads
model weights when needed. See the [Windows guide](../docs/WINDOWS.md) for
installation, upgrades, backup and troubleshooting.

## Automation and AI agents

Use `--workbench` for CLI operations and MCP connections. In **AI agent access**,
select a project and generate a connection configuration. Connections start
read-only; add write access, folders and trusted executable methods as needed.

See [CLI usage](../docs/WORKBENCH.md#cli-example),
[MCP setup](../docs/WORKBENCH.md#mcp-connection) and the
[Python SDK](../shared/python/README.md).

## Data and privacy

Image analysis runs locally. Model setup downloads packages and weights, and
OMERO connects to your chosen server. Enable plugins only if you trust their
source. Images and diagnostic reports are never uploaded automatically.

Back up project folders and application data. To move library results into a
project, use the migration preview; it keeps the original library.

## Development

Requires Node.js 22.18.x, Rust 1.88+ and the
[Tauri 2 Windows prerequisites](https://v2.tauri.app/start/prerequisites/), including
Microsoft C++ Build Tools and WebView2. From `desktop/`:

```powershell
npm ci
npm run verify:windows
npm run tauri -- dev
```

Build installers on 64-bit Windows:

```powershell
npm ci
npm run build
cargo test --manifest-path src-tauri/Cargo.toml --locked
npm run build:windows
node scripts/verify-windows-artifacts.mjs --write-checksums
```

Installers are written to `src-tauri/target/release/bundle/`. See the
[Windows workflow](../.github/workflows/windows.yml) for packaging,
[architecture](../docs/ARCHITECTURE.md) for the codebase and
[contributing](../CONTRIBUTING.md) to get involved.

## License

CellCounter is MIT licensed. Model weights and optional dependencies have their
own terms. See [LICENSE](../LICENSE) and
[third-party notices](../THIRD_PARTY_LICENSES.md).
