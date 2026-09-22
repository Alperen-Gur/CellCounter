# CellCounter v1.1.1 for Windows

This patch addresses imported images appearing in the library with correct dimensions but broken thumbnails and full-image previews.

Requires **Windows 10 or 11 x64**. Both the NSIS `.exe` and WiX `.msi` contain the same application. Installers are **unsigned**; compare the downloaded installer with `SHA256SUMS.txt` before installation.

## Image display fixes

- Grant local image access to the actual library image and thumbnail folders, including paths containing characters treated specially by filesystem patterns.
- Recover failed previews using browser-readable derivatives of the imported image. Missing thumbnails can be recreated without reimporting the library.
- Apply recovery to library images, full previews, review images and canvas-based displays. Ignore stale recovery results when the displayed image changes.
- Serialize recovery decoding and enforce image-size limits to bound concurrent memory use. Validate recovery requests against library records.
- Preserve original analysis images and saved measurements; generated previews are display-only derivatives.

## Updating

Quit CellCounter, install the new `.exe` or `.msi` using the same installer format as before, and reopen the app. Keep existing application data. A library reset, model reinstall or image reimport is not required.

See the [Windows installation guide](https://github.com/Alperen-Gur/CellCounter/blob/windows-v1.1.1/docs/WINDOWS.md). The three supported model families, CPU-only inference and remaining platform differences are unchanged.

## Validation boundary

This release uses a native Windows x64 packaging build for the frontend, Rust backend, MSI and NSIS installers. Installer files and SHA-256 checksums are checked before publication.

**Automated tests and interactive app validation were not run for this patch.** Regression cases are included in source, but the reporter's exact failure has not been confirmed resolved on their PC. Installer UI, upgrades and model inference were not exercised for this release.

The macOS release remains v1.0.14 and is distributed separately.
