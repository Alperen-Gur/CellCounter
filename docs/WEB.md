# CellCounter Web 0.3.2 preview

CellCounter Web is a local, browser-based microscopy application. It provides
classical segmentation, correction, measurements and exports without an account
or image-upload service. It is a **preview with a smaller feature set than the
desktop applications**.

The [release archive](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.3.2)
contains a static PWA. Serve its extracted files over HTTPS or localhost; opening
`index.html` directly is not supported. The downloadable archive does not provide
a hosted analysis service.

## Get started

1. Open CellCounter from the HTTPS or localhost address where it is served.
   If your browser offers **Install app**, you can install the PWA there.
2. Import supported images or select a folder where the browser permits it.
3. Confirm the source channel, supported projection and calibration. Select the
   separately named classical method; it needs no model download.
4. Preview a representative image, inspect the segmentation and adjust settings
   before processing a batch.
5. Review and correct results, then export the scientific files you need to keep.

For the current comparison with desktop features, see the
[platform comparison](PLATFORM-PARITY.md). The in-app
**Help → Browser capabilities** panel describes available browser functions.

## What is available

| Area | Browser functionality |
| --- | --- |
| Import | PNG, JPEG, WebP, BMP, TIFF and OME-TIFF; supported folder import and local duplicate detection. |
| Calibration | Manual scale and compatible OME, ImageJ or TIFF resolution metadata when valid. Missing scale is not guessed. |
| Classical segmentation | Otsu, triangle, adaptive or manual thresholding; background subtraction, minimum-area filtering and optional watershed in a local Worker. |
| Correction and review | Source-coordinate selection, add/remove/resize/merge/split tools, bounded undo/redo, ROIs, ground-truth markers, notes, confidence and review controls. |
| Measurements | Calibrated morphology, size bins, focus/illumination indicators, intensity, colocalization, confluence/area, scratch/spheroid/colony, puncta, spatial, sequence/migration, neurite and profile workflows where their inputs are available. |
| Repeatable processing | Saved analysis settings, representative previews, processing jobs with pause/resume/retry and versioned protocols. Interrupted jobs wait for explicit resume. |
| Linked results | Image, measurement table and scatter selection; saved mask alternatives retain source coordinates. |
| Portable microscopy | Supported local Zarr v2 sources, layer annotations, painting, translation/grid tools, recorded workspace operations and GIF presentation export within browser limits. |
| Export | Cell/summary CSV, provenance JSON, ImageJ ROI ZIP, ROI JSON, GeoJSON, annotated PNG, label-mask PNG, PDF and bare NumPy label arrays; supported sample/dataset exports. |

Assays need their declared channels, masks and sequence information. Missing
evidence produces an unavailable result rather than an invented measurement.
Saved run settings remain distinct from later review settings.

The [portable workspace guide](PORTABLE-WORKSPACE.md) explains source coordinates,
layer files, review sign-offs, dataset exports and replay. Its plane-based
surfaces are not a substitute for the desktop scientific volume engine.

<a id="webgpu-model-boundary"></a>

## Learned-model availability

**Validated learned-model weights are not included in this preview.** The
Cellpose-SAM, Cellpose cyto3 and StarDist fluorescence catalogue entries therefore
cannot perform live learned segmentation. The usable classical method is labeled
with its actual algorithm and never substitutes for one of those models.

The learned-model adapter requires WebGPU and an exact compatible artifact when
available. It does not silently use another checkpoint, CPU/WASM inference or
fixture output. Classical analysis uses a CPU Worker and does not require WebGPU.

Native Python model environments, proprietary microscope readers and model
training are not part of this browser application.

## TIFF and quantitative-image semantics

TIFF/OME-TIFF decoding runs locally in a Worker. Original bytes, bit depth,
channel/plane information and source hashes are retained in browser storage.
Calibration accepts valid isotropic OME X/Y spacing, ImageJ pixel width or explicit
TIFF resolution units. Missing units are not inferred.

Classical analysis reads retained source rasters with explicit source-channel
selection and first-plane, maximum, mean or sum projection. The prepared preview
shows the chosen transform. Assay source controls can differ from segmentation
controls; confirm the inputs for each measurement.

The default TIFF display and the learned-adapter input use a recorded first-plane
8-bit RGB PNG normalization. That preview has its own digest and provenance; it
does not mean original high-bit or multiplane pixels were submitted to a learned
model. Learned-model processing remains unavailable without the required artifact.

## Memory, formats and storage limits

- TIFF analysis supports up to **4 million pixels per plane**, **16 channels**
  and **64 Z planes per projection**, within a conservative **384 MB working-set
  budget**. Ambiguous multi-series or multi-file OME-TIFF mappings are rejected.
- The portable Zarr reader supports **Zarr v2**, supported spatial pyramids/plate
  fields and uncompressed, zlib or gzip chunks. Blosc, Zarr v3 and remote stores
  are not supported by this browser reader.
- Portable workspace files can embed up to **16 MiB** of supplied plane snapshots;
  they do not embed every plane of an external acquisition.
- Browser sample/dataset ZIP exports are bounded to **48 MiB of uncompressed
  artifacts**.
- Browser quotas, private-browsing settings and site-data deletion can remove
  local images or results. Browser storage is not an archival backup.

For large acquisitions, prepare supported TIFF inputs or use a compatible coarser
Zarr level. Desktop NGFF and scientific volume limits are separate.

## Save, export and update

Metadata is stored in IndexedDB and source blobs use browser-managed storage,
including OPFS where supported. Retain original acquisitions outside the browser
and export important results regularly. A workspace document or mask download is
not necessarily a complete copy of the study.

The NumPy export is a bare uint32 label array with a JSON sidecar, not a pickled
Cellpose GUI `_seg.npy` session. Dataset snapshots export compatible source planes,
instance masks and provenance; exporting one does not train a model.

When **Update available → Reload app** appears, finish active analysis and use
that action. It saves pending metadata before reloading. If an older preview has
no update notice, close all CellCounter tabs/windows, then reopen the same address.
**Do not clear site data merely to update the interface:** that removes local work.

## Privacy and offline behavior

Images, measurements and corrections are processed in the browser. The application
has no account, telemetry or authored image-upload path. Its content security
policy restricts application connections to the same origin; local images are
displayed from browser-managed URLs.

The host serves application assets and can apply its own hosting/access-log policy.
Where compatible model artifacts are provided, the same-origin model loader checks
their hash and length before caching or use. A corrupt cached artifact is rejected.

After the required application assets are cached, supported local workflows can
be used offline. Some assets load only when their feature is opened, so an initial
installation does not guarantee that every optional component is cached.
No browser-to-desktop synchronization is provided.

Optional local timing summaries and diagnostic exports require explicit recording
and inspection; there is no automatic report upload. See
[local diagnostics](INSTALL.md#optional-local-diagnostics).

## Run locally

Requirements:

- Node.js `^20.19.0` or `>=22.12.0`
- A current browser with Web Workers, IndexedDB and `createImageBitmap`
- HTTPS for deployed use; localhost is sufficient for local development

From the repository root:

```sh
cd web
npm ci
npm run dev
```

To build and serve a local production preview:

```sh
npm run build
npm run preview
```

The production files are written to `web/dist/`. Serve that directory from the
web root over HTTPS for deployment.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| A learned model is unavailable | This preview does not include qualified production weights. Use the explicitly named classical method or a desktop model workflow. |
| A TIFF exceeds the import budget | Prepare a supported smaller image/stack or a compatible coarser Zarr level. The browser does not silently downsample scientific analysis to bypass the limit. |
| Calibration is missing | Enter a known scale. Ordinary images and TIFFs without valid units do not establish physical calibration. |
| A workspace opens but external planes are missing | Reattach its original source data. Embedded snapshots are only a bounded subset. |
| A saved study disappeared | Check that you are using the same browser profile and origin. Clearing site data or storage eviction can remove the local study. Restore from retained sources/exports where available. |
| The installed PWA still shows an older version | Finish active work, use the update action, or close every tab/window and reopen. Preserve site data. |
| A proprietary microscope file will not import | Convert locally to a supported TIFF/OME-TIFF or use a compatible desktop reader. |

See the [0.3.2 release notes](releases/web-v0.3.2.md) for release-specific changes.
