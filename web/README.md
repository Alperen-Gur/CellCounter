<div align="center">

# CellCounter Web

Private microscopy analysis in an installable, fully client-side PWA.

[![Web preview](https://img.shields.io/badge/Web-v0.2.1%20preview-5b5bd6?logo=pwa&logoColor=white)](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.2.1)
[![CI](https://img.shields.io/github/actions/workflow/status/Alperen-Gur/CellCounter/web.yml?branch=main&label=Web%20build)](https://github.com/Alperen-Gur/CellCounter/actions/workflows/web.yml)
[![License](https://img.shields.io/badge/license-MIT-blue)](../LICENSE)

[Download](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.2.1) · [Browser guide](../docs/WEB.md) · [Main project](../README.md)

</div>

---

CellCounter Web brings the microscopy workspace to modern browsers without an account, image upload,
telemetry, or application server. Imported images, measurements, corrections, study metadata, and exports stay
on the device.

> [!IMPORTANT]
> Version 0.2.1 includes local classical threshold/watershed segmentation, but production weights for its
> three learned segmentation models are not bundled. The interface reports learned inference as unavailable instead of substituting another model.
> Use the native macOS or Windows release when live model inference is required.

## Highlights

- A continuous landing page with a full-viewport point illustration that changes with native scrolling,
  clear section links, motion controls and immediate workspace access

- Research workbench with Library, Analyze, Processing and Review navigation, a larger image canvas,
  a tabbed inspector and an on-demand measurement panel
- Local Otsu, triangle, adaptive and manual thresholding, with explicit source channel/Z projection
- Saved whole-image previews, matching-preview reuse, paused/resumable jobs and failed-image retry
- Linked image/table/scatter selection and reversible saved mask alternatives

- PNG, JPEG, WebP, BMP, TIFF, and OME-TIFF import, including folders
- Image navigation, contours, selection, add/remove/resize/merge/split corrections, and undo/redo
- Calibrated morphology, intensity, colocalization, confluence, wound, spheroid, puncta, spatial, tracking,
  neurite, and line-profile analysis
- Local project storage with lazy image restoration and offline PWA support
- CSV, JSON, ImageJ ROI, GeoJSON, annotated image, label mask, NumPy label map, and PDF exports
- Responsive, keyboard-accessible light and dark interfaces

Proprietary microscope containers such as ND2, CZI, LIF, OIR, and VSI are not available in the browser. Convert
them locally to OME-TIFF before import. See the [browser guide](../docs/WEB.md) for the complete format and
capability notes.

## Privacy

All image processing happens in the browser. CellCounter Web does not include an upload or remote-inference
route. Projects are stored in browser-managed local storage and can be removed from **Settings**. When production
model assets become available, they will be loaded from the same origin and verified before local use.

## Run locally

Requirements:

- Node.js `^20.19.0` or `>=22.12.0`
- A current browser with Web Workers, IndexedDB, and `createImageBitmap`; WebGPU is only needed for learned models
- HTTPS for production use; `localhost` is sufficient for development

```sh
npm ci
npm run dev
```

Create a production build:

```sh
npm run build
```

The static PWA is emitted to `dist/` and can be served from any HTTPS origin. No application server is required.

## Verify

```sh
npm test -- --run
npm run verify:privacy
npm run verify:workflow
npm run verify:models
npm run verify:core
npm run verify:parity
npm run verify:parity-analysis
```

## License

MIT — see the repository-level [LICENSE](../LICENSE).
