# CellCounter Web

CellCounter Web is a fully client-side, installable PWA for private microscopy
analysis. Imported pixels, model artifacts, measurements, corrections, study
metadata and exports stay in the browser. This version contains no account,
telemetry, image upload or application server path.

## What is available

The in-product **Capabilities** view is the authoritative, source-derived
macOS v1.0.8 parity inventory. It accounts for exactly 47 capabilities and
labels each one as available, build required, or unavailable on the web. The
repository verifier resolves every cited macOS source file and fails closed if
an item or implementation surface disappears.

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
- responsive keyboard-accessible light and dark interfaces

All expensive TIFF, assay, inference and full-resolution export work runs in
dedicated Web Workers. TIFF imports are serialized and checked against a
conservative 384 MB end-to-end working-set budget; startup restores metadata
and thumbnails first and decodes the active source only.

## WebGPU model boundary

The frozen initial catalog contains exactly:

1. `cpsam_v2` — Cellpose-SAM v2
2. `cp-cyto3` — Cellpose cyto3 (the cross-platform default)
3. `sd-fluo` — StarDist versatile fluorescence

The inference adapter is WebGPU-only and never substitutes WASM, CPU, another
model or fixture output. Model weights are not committed. At this revision all
three entries are honestly `buildRequired`: no exact ONNX artifact has yet
passed the repository's checkpoint-lineage, output-parity, operator, checksum
and byte-length gates. Selecting Run therefore shows an actionable artifact
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

The display and current learned-model input are an explicit first-plane 8-bit
RGB PNG normalization. Provenance records its own digest, media type and byte
length separately from the original TIFF identity and names the transform.
It never claims that the original high-bit or multi-plane bytes were fed to the
model. Analysis Lab can read the retained TIFF raster directly and offers
explicit first-plane or maximum projection for browser-native quantitative
assays. Full high-bit, multi-plane learned-model parity remains coupled to the
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

## Run locally

Requirements:

- Node.js `^20.19.0` or `>=22.12.0`
- a current browser with WebGPU, Web Workers, IndexedDB and `createImageBitmap`
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

The production PWA is emitted to `web/dist/`. CI performs the same read-only
checks with a pinned Node runtime and does not deploy, publish or upload an
artifact.

## Honest browser limits

- ND2, CZI, LIF, OIR, VSI and other proprietary SDK-only containers are
  unavailable. Convert them locally to OME-TIFF first.
- Exact `cpsam_v2`, `cp-cyto3` and `sd-fluo` production weights are absent, so
  learned detection, model-coupled preprocessing and watershed parity remain
  build-gated.
- The NumPy export is a safe bare uint32 label array with a JSON sidecar, not a
  Cellpose GUI pickled `_seg.npy` session. Full round-trip import/export remains
  build required.
- Live fine-tuning is unavailable because the exact training weights and native
  training runtime are absent and browser memory limits make parity unsafe.
  Corrected label masks and include/exclude ROI data can be exported for later workflows.
- 3D learned inference and OME-Zarr are not claimed by the current web build.
