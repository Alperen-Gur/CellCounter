<div align="center">

# CellCounter Web

Microscopy analysis in your browser.

[![Web preview](https://img.shields.io/badge/Web-v0.3.2%20preview-5b5bd6?logo=pwa&logoColor=white)](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.3.2)
[![CI](https://img.shields.io/github/actions/workflow/status/Alperen-Gur/CellCounter/web.yml?branch=main&label=Web%20build)](https://github.com/Alperen-Gur/CellCounter/actions/workflows/web.yml)
[![License](https://img.shields.io/badge/license-MIT-blue)](../LICENSE)

[Download preview](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.3.2) · [Browser guide](../docs/WEB.md) · [Main project](../README.md)

</div>

Import images, run classical segmentation, correct masks and export measurements
on your device. CellCounter Web is an installable progressive web app (PWA) that
needs no account. Serve the release files over HTTPS or localhost.

## Features

- PNG, JPEG, WebP, BMP, TIFF and OME-TIFF import, folders and calibration metadata
- Otsu, triangle, adaptive and manual thresholds, channel selection, Z projections
  and watershed
- Object editing, linked measurements, undo/redo and saved mask alternatives
- Morphology, fluorescence, microscopy assays and condition summaries
- OME-Zarr v2 sources, layers, annotations, painting, registration, stitching and
  lineage editing
- CSV, JSON, ImageJ ROI, GeoJSON, image, label-mask, NumPy and PDF exports
- Saved browser projects, offline use, and light and dark interfaces

See the [browser guide](../docs/WEB.md),
[portable workspace guide](../docs/PORTABLE-WORKSPACE.md) and
[release notes](../docs/releases/web-v0.3.2.md).
For desktop editions, see the [platform comparison](../docs/PLATFORM-PARITY.md).

## Data and privacy

Images are processed in your browser. CellCounter Web has no account or telemetry
and does not upload images. Keep original source files and export important
results before clearing browser data. Diagnostic reports are reviewed and saved
locally.

## Run locally

Requirements:

- Node.js `^20.19.0` or `>=22.12.0` with npm
- A current browser with Web Workers, IndexedDB and `createImageBitmap`
- HTTPS for deployment, or localhost for development

From `web/`:

```sh
npm ci
npm run dev
```

Create a production build:

```sh
npm run build
```

Serve the contents of `dist/` from the web root. See the
[browser guide](../docs/WEB.md) for deployment steps.

## Development checks

```sh
npm test -- --run
npm run verify:privacy
npm run verify:workflow
npm run verify:models
npm run verify:core
npm run verify:parity
npm run verify:parity-analysis
```

See [architecture](../docs/ARCHITECTURE.md) and
[contributing](../CONTRIBUTING.md).

## License

CellCounter is MIT licensed. See [LICENSE](../LICENSE) and
[third-party notices](../THIRD_PARTY_LICENSES.md).
