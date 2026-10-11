# CellCounter v1.1.2 for Windows

This maintenance release keeps measurements consistent with the current batch calibration and removes unused code. It includes the image-preview recovery fixes from v1.1.1.

Requires **Windows 10 or 11 x64**. The NSIS `.exe` and WiX `.msi` contain the same application. Installers are **unsigned**; compare their SHA-256 hashes with `SHA256SUMS.txt`.

## Changes

- Use the selected batch's calibration in the results editor and analysis sidebar.
- Convert new analysis measurements to the batch's current scale before saving, retaining the original run parameters.
- Restore saved masks at the current review calibration, including physical measurements and existing size classifications, while preserving original run provenance.
- Remove unused processing, editing and onboarding modules, obsolete helpers, and duplicate initialization.

## Updating and validation

Quit CellCounter and install the new `.exe` or `.msi`, using the same installer format as before. Keep existing application data. A library reset or model reinstall is not required. See the [Windows guide](https://github.com/Alperen-Gur/CellCounter/blob/windows-v1.1.2/docs/WINDOWS.md).

The release uses the packaging-only Windows x64 workflow: frontend compilation and type-checking, Rust production compilation, MSI/NSIS generation, artifact checks and SHA-256 generation. **Automated tests, interactive application validation, installer UI checks and model inference were not run.**

The three supported model families and CPU-only inference remain unchanged. macOS is released separately as v1.0.16; the web preview remains v0.2.1.
