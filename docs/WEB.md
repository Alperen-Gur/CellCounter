# CellCounter Web 0.3.2 preview

Import images, segment cells, correct masks and export measurements in your
browser. CellCounter Web runs locally and needs no account.

Download the [release archive](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.3.2)
and serve the extracted files over HTTPS or localhost.

## Get started

1. Open the app at its HTTPS or localhost address. Choose **Install app** if
   your browser offers it.
2. Import images or a folder.
3. Choose the source channel and projection, check calibration and select a
   segmentation method.
4. Preview an image and adjust the settings before processing the batch.
5. Correct masks, review measurements and export your results.

Use **Help → Browser capabilities** for browser settings, or see the
[platform comparison](PLATFORM-PARITY.md) for desktop features.

## What is available

| Area | Features |
| --- | --- |
| Import | PNG, JPEG, WebP, BMP, TIFF and OME-TIFF, folder import and duplicate detection. |
| Calibration | Manual scale and OME, ImageJ or TIFF calibration metadata. |
| Segmentation | Otsu, triangle, adaptive and manual thresholding, background subtraction, area filtering and watershed. |
| Correction and review | Add, remove, resize, merge and split objects; undo/redo, ROIs, ground-truth markers, notes and review tools. |
| Measurements | Morphology, size bins, intensity, colocalization, confluence, scratch, spheroid, colony, puncta, spatial, migration, neurite and profile analysis. |
| Batch processing | Saved settings, previews, versioned protocols and jobs with pause, resume and retry. |
| Linked results | Select an object in the image, measurement table or scatter plot to see it in the other views. Save alternative masks for comparison. |
| Microscopy workspace | Local Zarr v2 sources, layers, annotations, painting, translation registration, grid stitching and animation. |
| Export | CSV, provenance JSON, ImageJ ROI ZIP, ROI JSON, GeoJSON, PNG, PDF, NumPy label arrays and sample/dataset exports. |

The [portable workspace guide](PORTABLE-WORKSPACE.md) covers layers, review,
dataset exports and replay.

## Working with TIFF images

TIFF decoding runs in a browser Worker. CellCounter stores the original bytes,
bit depth, channels, planes and source hashes alongside the project.

Choose a channel and a first-plane, maximum, mean or sum projection for analysis.
The preview shows your selection. For physical measurements, use the image's
calibration metadata or enter a known scale.

## Save, export and update

Projects are saved in browser storage. Keep your original images and export
important results regularly, especially before clearing site data or changing
browser profiles.

NumPy export contains a uint32 label array and a JSON sidecar. Dataset exports
include source planes, instance masks and provenance.

When **Update available → Reload app** appears, finish active analysis and use
that action. If an older preview has no update notice, close all CellCounter
tabs and windows, then reopen the same address. Keep site data when updating.

## Privacy and offline behavior

Images, measurements and corrections are processed in your browser. CellCounter
Web has no account or telemetry and does not upload images. Once application
assets are cached, you can use local workflows offline. Open the features you
need while online first so their assets are available.

Optional diagnostics record session timings. You review and export the report
yourself; nothing is submitted automatically. See
[local diagnostics](INSTALL.md#optional-local-diagnostics).

## Run locally

Requirements:

- Node.js `^20.19.0` or `>=22.12.0`
- A current browser with Web Workers, IndexedDB and `createImageBitmap`
- HTTPS for deployment, or localhost for local use

From the repository root:

```sh
cd web
npm ci
npm run dev
```

To build and serve a production preview:

```sh
npm run build
npm run preview
```

Serve the contents of `web/dist/` from the web root over HTTPS.

## Troubleshooting

| Problem | Try this |
| --- | --- |
| A microscope file will not import | Convert it to TIFF/OME-TIFF. For a large acquisition, choose a smaller region or a coarser Zarr level. |
| Calibration is missing | Enter a known scale. |
| A workspace is missing source planes | Reattach the original dataset. |
| A saved study disappeared | Use the same browser profile and address. Restore from your source files and exports if site data was cleared. |
| The installed PWA shows an older version | Finish work, use **Reload app**, or close every CellCounter tab and window before reopening. |

See the [0.3.2 release notes](releases/web-v0.3.2.md).
