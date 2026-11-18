# CellCounter v1.1.1 for Windows

This patch fixes imported images appearing in the library with correct dimensions but broken thumbnails and full-image previews.

Requires **Windows 10 or 11 x64**. The NSIS `.exe` and WiX `.msi` contain the same application. Installers are unsigned; compare the downloaded installer with `SHA256SUMS.txt` before installation.

## Changes

- Grant local image access to the actual library image and thumbnail folders, including paths with characters that filesystem patterns treat specially.
- Recover failed previews using browser-readable copies of the imported image. Missing thumbnails can be recreated without reimporting the library.
- Apply recovery to library images, full previews, review images and canvas-based displays. Ignore stale recovery results when the displayed image changes.
- Serialize recovery decoding and enforce image-size limits to bound memory use. Validate recovery requests against library records.
- Keep original analysis images and saved measurements unchanged; generated previews are display-only copies.

## Update

Quit CellCounter, install the new `.exe` or `.msi` using the same installer format as before, and reopen the app. Keep existing application data. A library reset, model reinstall or image reimport is not required.

See the [Windows installation guide](https://github.com/Alperen-Gur/Cellographer/blob/windows-v1.1.1/docs/WINDOWS.md).
