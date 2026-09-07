# CellCounter Web 0.2.0 preview

CellCounter Web is a fully client-side, installable PWA for private microscopy
analysis. Imported pixels, model artifacts, measurements, corrections, study
metadata and exports stay in the browser. This version contains no account,
telemetry, image upload or application server path.

## What is available

The in-product **Help → Browser capabilities** view records 69 capabilities,
including the native workflows still missing from the browser. Each entry cites
source evidence and distinguishes available, build-required and unavailable
behavior. These source checks establish traceability; they are not proof of full
macOS feature parity.

### New in 0.2.0

- **A research workbench:** Library, Analyze, Processing and Review are the main
  destinations. Analyze reserves most of the workspace for the image; Setup,
  Selection and Image tabs organize its inspector. Measurements open on demand.
- **Working segmentation without model downloads:** classical Otsu, triangle,
  adaptive or manual thresholding, background subtraction, minimum-area
  filtering and optional watershed run locally in a Worker. This method is
  labeled explicitly and never impersonates Cellpose or StarDist.
- **Preview before processing:** inspect a representative field and save its
  whole-image preview. Processing reuses it only when source bytes, model,
  parameters and calibration match.
- **A saved processing queue:** each job retains its settings and progress.
  Pause finishes the current image; cancellation stops it and pauses the job.
  Resume and retry retain completed work. Interrupted jobs wait for explicit
  resume after reopening the app.
- **Linked review:** image selection, a paged measurement table and scatter
  selection share cell identity. Saved mask alternatives use the same image
  coordinates, show change counts and preserve the current mask before restore.
- **An optional introduction:** a rotatable, morphing 3D point illustration
  uses muted blue-white light, explicit controls, scroll-linked transitions
  and reduced-motion support. It unloads on entering the analysis workspace.
  Lucide icons and Three.js include their license notices in `licenses/`.
- **Clearer context:** recorded run settings and calibration remain distinct
  from later review settings. Phone-sized screens use an explicitly dismissible
  inspector sheet; Help contains shortcuts, privacy details and capability limits.

The reusable [design library](design/README.md) explains the research behind this
interface and separates source evidence from design recommendations.

Browser-native functionality includes:

- PNG, JPEG, WebP, BMP, TIFF and OME-TIFF import, plus recursive folder import
- local SHA-256 duplicate detection and per-image OME, ImageJ or TIFF-baseline
  calibration when valid metadata is present
- an image-first workspace with fit, pan and zoom; contours; selection; and
  source-coordinate add, remove, resize, merge and split tools
- bounded undo/redo, ground-truth markers with live precision/recall/F1,
  include/exclude ROIs, notes, confidence and a low-confidence review queue
- calibrated morphology, size bins, focus/illumination QC, intensity and
  colocalization assays, area/confluence/scratch/spheroid/colony assays,
  puncta, spatial statistics, explicit-sequence tracking/migration, neurite
  outgrowth and line profiles
- versioned analysis protocols that are validated before atomic application
- condition summaries and deterministic comparisons
- IndexedDB metadata, OPFS source blobs when supported, lazy image restore and
  local model caching
- Cells CSV, provenance JSON, ImageJ ROI ZIP, ROI JSON, GeoJSON, annotated PNG,
  label-mask PNG, PDF report and a safe bare uint32 NumPy label map
- responsive light and dark interfaces with screen-scoped shortcuts, visible
  focus and modal focus restoration

All expensive TIFF, assay, inference and full-resolution export work runs in
dedicated Web Workers. TIFF imports are serialized and checked against a
conservative 384 MB end-to-end working-set budget; startup restores metadata
and thumbnails first and decodes the active source only.

## WebGPU model boundary

The frozen initial catalog contains exactly:

1. `cpsam_v2` — Cellpose-SAM v2 (browser artifact remains build required)
2. `cp-cyto3` — Cellpose cyto3 (the cross-platform default)
3. `sd-fluo` — StarDist versatile fluorescence

The learned-model adapter is WebGPU-only and never substitutes WASM, CPU,
another model or fixture output. The separate classical method uses a local
CPU Worker and does not need WebGPU. Model weights are not committed. At this revision all
three entries are honestly `buildRequired`: no exact ONNX artifact has yet
passed the repository's checkpoint-lineage, output-parity, operator, checksum
and byte-length gates. Selecting one of those learned models therefore shows an actionable artifact
error; this source revision does **not** claim live learned segmentation.

[`web/src/models/BUILD-CONTRACT.md`](../web/src/models/BUILD-CONTRACT.md)
defines how a release engineer can export, validate and checksum an exact
artifact before changing its manifest atomically to `ready`. There is no silent
model substitution.

## TIFF and quantitative-image semantics

TIFF/OME-TIFF decoding happens locally in a Worker. The original source bytes,
bit depth, channel count, plane count and source SHA-256 are retained in local
storage. OME `PhysicalSizeX/Y`, ImageJ pixel width and explicit TIFF resolution
units are accepted when isotropic and valid; missing resolution units are not
guessed.

The default TIFF display and currently specified learned-model input use an
explicit first-plane 8-bit RGB PNG normalization. Provenance records its own digest, media type and byte
length separately from the original TIFF identity and names the transform.
It never claims that the original high-bit or multi-plane bytes were fed to the
model. The classical method reads retained source rasters with explicit source-channel
selection and first-plane, maximum, mean or sum projection. Prepared source
previews show the selected transform. Assays retains its own source controls;
its available choices should not be confused with learned-model preprocessing.
Full high-bit, multi-plane learned-model parity remains coupled to the
model-artifact validation gate.

## Privacy and offline behavior

The content security policy limits connections to the same origin. Application
image display uses local `blob:` URLs. The only authored `fetch` path is the
same-origin, versioned model loader; it verifies SHA-256 and byte length before
caching or use. A corrupt cache entry is deleted and reported.

The initial UI is split from the inference runtime and assay/export workers, so
they do not block first interaction. ONNX Runtime and the inference worker are
loaded only when learned detection is explicitly requested, rather than during
PWA installation; the browser may then retain those same-origin assets in its
ordinary HTTP cache. Model files remain separately gated and cached only after
their manifests become ready.

Reset in Settings deletes the local project. A future optional server is
outside this release and outside its privacy boundary.

## Updating an installed preview

When a new version is ready, **Update available → Reload app** appears. The
button waits while analysis is active and saves pending image metadata before
reloading. If an older preview predates that notice, close every CellCounter
tab and installed window, then reopen it so the waiting update can activate.
Do not clear site data just to refresh the interface; that would remove the
local study.

## Run locally

Requirements:

- Node.js `^20.19.0` or `>=22.12.0`
- a current browser with Web Workers, IndexedDB and `createImageBitmap`;
  WebGPU is additionally required for future validated learned-model artifacts
- HTTPS in production (`localhost` is sufficient for development)

From `web/`:

```sh
npm ci
npm run dev
```

Run the complete local contract:

```sh
npm run build
npm test -- --run
npm run verify:privacy
npm run verify:workflow
npm run verify:models
npm run verify:core
npm run verify:parity
npm run verify:parity-analysis
```

The production PWA is emitted to `web/dist/`. CI performs these checks with a pinned Node runtime. Release archives contain
the static production files; serve them over HTTPS rather than opening
`index.html` directly. Publishing a downloadable archive does not create a
publicly hosted analysis service.

## Honest browser limits

- ND2, CZI, LIF, OIR, VSI and other proprietary SDK-only containers are
  unavailable. Convert them locally to OME-TIFF first.
- Exact `cpsam_v2`, `cp-cyto3` and `sd-fluo` production weights are absent, so
  learned detection and model-coupled preprocessing remain build-gated. The
  separately named classical method is usable, including its own watershed.
- The NumPy export is a safe bare uint32 label array with a JSON sidecar, not a
  Cellpose GUI pickled `_seg.npy` session. Full round-trip import/export remains
  build required.
- Live fine-tuning is unavailable because the exact training weights and native
  training runtime are absent and browser memory limits make parity unsafe.
  Corrected label masks and include/exclude ROI data can be exported for later workflows.
- 3D learned inference, OME-Zarr, the native layer workspace, registration,
  lineage editing, recorded workspace replay, prompt/sequence correction and
  reviewed-library training are not available in this build.
- Browser storage quotas and site-data deletion can remove local work. Export
  results you need to retain; this release is not a cross-device project sync
  or archival backup service.
