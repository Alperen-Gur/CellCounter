<div align="center">

# CellCounter Web

Microscopy analysis in a local, installable browser application.

[![Web preview](https://img.shields.io/badge/Web-v0.3.2%20preview-5b5bd6?logo=pwa&logoColor=white)](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.3.2)
[![CI](https://img.shields.io/github/actions/workflow/status/Alperen-Gur/CellCounter/web.yml?branch=main&label=Web%20build)](https://github.com/Alperen-Gur/CellCounter/actions/workflows/web.yml)
[![License](https://img.shields.io/badge/license-MIT-blue)](../LICENSE)

[Download preview](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.3.2) · [Browser guide](../docs/WEB.md) · [Main project](../README.md)

</div>

CellCounter Web 0.3.2 is a static progressive web application (PWA). Import images,
run classical segmentation, correct objects and export measurements on your
device. It requires no account or image-upload service. The release archive can
be served over HTTPS or localhost; it does not provide a hosted deployment.

## Features

- **Import:** PNG, JPEG, WebP, BMP, TIFF and supported OME-TIFF images, including
  folders and available calibration metadata.
- **Segmentation:** local Otsu, triangle, adaptive and manual thresholding, with
  selected channels, Z projections and optional watershed.
- **Review:** image navigation, contour editing, add/remove/resize/merge/split
  corrections, linked measurement selection and reversible mask alternatives.
- **Measurements:** calibrated morphology, fluorescence and supported assays,
  with condition summaries and provenance.
- **Microscopy workspace:** bounded OME-Zarr v2 planes, layers, annotations,
  semantic painting, translation registration, grid stitching and lineage edits.
- **Export:** CSV, JSON, ImageJ ROI, GeoJSON, annotated images, label masks,
  NumPy label maps and PDF reports.
- **Local projects:** browser-managed storage, lazy image restoration, offline
  support after installation, and light and dark interfaces.

See the [browser guide](../docs/WEB.md) for format and storage limits, the
[portable workspace guide](../docs/PORTABLE-WORKSPACE.md) for layer operations,
and the [release notes](../docs/releases/web-v0.3.2.md) for this version.

## Preview limitations

Learned-model weights are not supplied as qualified browser artifacts. Model
entries report unavailable inference explicitly. Classical segmentation does not
substitute for Cellpose or StarDist.

The browser does not include the desktop Python Workbench, installed-app CLI or
MCP server, model training, or proprietary ND2, CZI, LIF, OIR and VSI readers.
Convert unsupported acquisitions locally to a supported OME-TIFF first. Browser
workspaces process bounded source planes; their projected surface display is
separate from the desktop Workbench's scientific volume analysis.

Use the [desktop releases](../README.md#download) when these capabilities are
required. The [platform comparison](../docs/PLATFORM-PARITY.md) and
[feature matrix](../docs/FEATURES.md) describe the differences.

## Data and privacy

Image processing runs in the browser. CellCounter Web includes no telemetry,
image-upload route or remote-inference service. Projects are held in
browser-managed storage; clearing site data can remove them. Export important
results and retain original source files. Optional diagnostics are reviewed and
exported by the user, with no automatic submission.

## Run locally

Requirements:

- Node.js `^20.19.0` or `>=22.12.0` with npm.
- A current browser with Web Workers, IndexedDB and `createImageBitmap`.
- HTTPS for deployment; `localhost` is sufficient for development. WebGPU is
  needed only for compatible learned-model artifacts.

From `web/`:

```sh
npm ci
npm run dev
```

Create a production build:

```sh
npm run build
```

The static PWA is emitted to `dist/`. Serve its contents from the web root; no
application server is required. See [deployment guidance](../docs/WEB.md).

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
[contributing](../CONTRIBUTING.md) for shared code and contribution guidance.

## License

CellCounter is MIT licensed. See [LICENSE](../LICENSE) and
[third-party notices](../THIRD_PARTY_LICENSES.md) for included dependencies.
