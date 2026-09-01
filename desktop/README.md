<div align="center">

# CellCounter for Windows

Native, private microscopy analysis for Windows 10 and 11.

[![Windows release](https://img.shields.io/badge/Windows-v1.0.8-0078D4?logo=windows11&logoColor=white)](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.0.8)
[![CI](https://img.shields.io/github/actions/workflow/status/Alperen-Gur/CellCounter/windows.yml?branch=main&label=Windows%20build)](https://github.com/Alperen-Gur/CellCounter/actions/workflows/windows.yml)
[![License](https://img.shields.io/badge/license-MIT-blue)](../LICENSE)

[Download](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.0.8) · [Installation guide](../docs/WINDOWS.md) · [Main project](../README.md)

</div>

---

CellCounter for Windows preserves the React interface in a native Tauri application. Imported microscopy
images, model inference, measurements, corrections, and exports remain on the PC; there is no image-upload or
remote-inference path.

## Highlights

- Native x64 `.exe` and `.msi` installers for Windows 10 and Windows 11
- Cellpose-SAM v2, Cellpose `cyto3`, and StarDist fluorescence model families
- Microscopy import, Z-stack and channel handling, manual correction, advanced assays, comparison, and export
- Local projects, source images, model environments, measurements, and provenance
- Responsive React interface with Windows-native file handling and packaging

## Install

[![Download](https://img.shields.io/badge/Download-Windows%20v1.0.8-0078D4?style=for-the-badge&logo=windows11&logoColor=white)](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.0.8)

Choose the NSIS `.exe` for a standard workstation installation or the WiX `.msi` for managed deployment. Both
packages contain the same application. The installers are currently unsigned, so verify the download against
the included `SHA256SUMS.txt` before responding to any SmartScreen warning.

On first launch, open **Models** and install one of the three available model families. Internet access is needed
for the initial model setup; subsequent image analysis is local. End users do not need to install Node.js, Rust,
or Python.

For system requirements, hash verification, upgrades, backup, and troubleshooting, see the
[Windows guide](../docs/WINDOWS.md).

## Development

Requirements:

- Node.js 22.18.x with npm
- Rust 1.88 or newer
- Current Tauri 2 prerequisites for Windows, including Microsoft C++ Build Tools and WebView2

Install dependencies, verify the project, and start the development application:

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

Release bundles are written below `src-tauri/target/release/bundle/`. The Windows workflow performs the same
validation for repository changes and publishes downloadable workflow artifacts for successful builds.

## License

MIT — see the repository-level [LICENSE](../LICENSE).
