# CellCounter feature reference

This is the public feature inventory for the currently documented releases: macOS v1.0.13, Windows v1.0.8,
and Web v0.1.0 preview. It describes user-facing behavior and deliberately omits private implementation details.

Status meanings:

- **Available** — included and usable in the named release.
- **Adapted / limited** — included with a documented platform-specific difference.
- **Preview / build required** — the interface or workflow is present, but a required production component or validation step is not complete.
- **Not available** — intentionally absent from that release.

For installation and operational guidance, see the [main README](../README.md), [Windows guide](WINDOWS.md), and
[web guide](WEB.md).

## Privacy and storage

| Capability | macOS v1.0.13 | Windows v1.0.8 | Web v0.1.0 |
|---|---|---|---|
| Local image analysis with no image-upload path | **Available** | **Available** | **Available** |
| Account-free use | **Available** | **Available** | **Available** |
| Persistent local projects, images, measurements, and corrections | **Available** | **Available** | **Available** in browser-managed storage |
| Offline use after application and required models are installed | **Available** | **Available** | **Available** after PWA installation; learned models remain build required |
| Local data reset | **Available** | **Available** | **Available** |
| Reproducibility metadata with image, model, calibration, and analysis settings | **Available** | **Available** | **Available** |

## Import and calibration

| Capability | macOS v1.0.13 | Windows v1.0.8 | Web v0.1.0 |
|---|---|---|---|
| JPEG, PNG, BMP, TIFF, and OME-TIFF | **Available** | **Available** | **Available**, plus WebP |
| Recursive folder and batch import | **Available** | **Available** | **Available** where the browser supports folder selection |
| Proprietary microscope containers | **Available:** CZI, ND2, LIF, OIF, OIB, OIR | **Available:** CZI, ND2, LIF, OIR, VSI | **Not available**; convert to OME-TIFF locally |
| Z-stack projection | **Available:** max, sum, mean | **Adapted / limited:** maximum projection during image preparation | **Adapted / limited:** first-plane or maximum projection for browser-native analysis |
| Multi-channel inspection, naming, and analysis-channel selection | **Available** | **Adapted / limited:** analysis-channel controls without the macOS naming workspace | **Available** for browser-native assays; learned-model preprocessing is build required |
| OME-Zarr / OME-NGFF multiscale arrays and plates | **Available** in the microscopy workspace | **Not available** | **Not available** |
| Exact duplicate detection and review | **Available** | **Available** | **Available** |
| Calibration from compatible image metadata | **Available** | **Available** with format-specific adaptations | **Available** for OME, ImageJ, and baseline TIFF metadata |
| Manual pixel-size and scale-bar calibration | **Available** | **Available** | **Available** |
| Named calibration presets | **Available** | **Available** | **Available** |
| Preservation of original microscope files during analysis preparation | **Available** | **Available** | **Available** within browser storage |

## Segmentation models

| Model or family | macOS v1.0.13 | Windows v1.0.8 | Web v0.1.0 |
|---|---|---|---|
| Cellpose-SAM v2 | **Available** | **Available** | **Preview / build required:** production weights are not bundled |
| Cellpose-SAM and Cellpose-DINO ViT-L / ViT-B | **Available** | **Not available** | **Not available** |
| Cellpose `cyto3` | **Available** | **Available** | **Preview / build required:** production weights are not bundled |
| Cellpose `cyto3 + restore`, `cyto2`, and `nuclei` | **Available** | **Not available** | **Not available** |
| StarDist versatile fluorescence | **Available** | **Available** | **Preview / build required:** production weights are not bundled |
| StarDist H&E and DSB2018 | **Available** | **Not available** | **Not available** |
| Omnipose bacteria phase, bacteria fluorescence, and `cyto2` | **Available** | **Not available** | **Not available** |
| Classical threshold and watershed: Otsu, triangle, adaptive, manual | **Available** | **Not available** | **Not available** |
| Bring-your-own Cellpose checkpoint or StarDist model | **Available** | **Not available** beyond fine-tuned `cyto3` versions | **Not available** |
| Second-opinion model pairing and disagreement review | **Available** | **Not available** | **Not available** |

Catalog entries that are still undergoing validation remain visibly unavailable and are not counted as usable
models in this table.

## Detection and refinement

| Capability | macOS v1.0.13 | Windows v1.0.8 | Web v0.1.0 |
|---|---|---|---|
| Single-image and batch detection with progress | **Available** | **Available** | **Preview / build required** until a production model is bundled |
| Cancellation without discarding the previous result | **Available** | **Available** with Windows-native process handling | **Available** for worker tasks; learned inference remains build required |
| Expected-diameter and confidence controls | **Available** | **Available** | **Available** for persisted analysis settings |
| Background subtraction and preprocessing presets | **Available** | **Available** | **Preview / build required** for learned-model parity |
| Z projection and segmentation-channel selection | **Available** | **Available** | **Preview / build required** for learned inference |
| Touching-cell watershed split | **Available** | **Available** | **Preview / build required** for model-coupled postprocessing |
| Rerun detection while preserving source images | **Available** | **Available** | **Preview / build required** |
| Exact model identity and explicit failure reporting | **Available** | **Available** | **Available** |
| Hardware acceleration control | **Available** where supported | **Adapted / limited:** validated CPU path | **Adapted / limited:** WebGPU only, with no CPU or server fallback |

## Measurements and assays

| Capability | macOS v1.0.13 | Windows v1.0.8 | Web v0.1.0 |
|---|---|---|---|
| Count and configurable size-bin summaries | **Available** | **Available** | **Available** |
| Area, perimeter, equivalent diameter, circularity, aspect ratio, solidity, and eccentricity | **Available** | **Available** | **Available** |
| Per-channel intensity and intensity histograms | **Available** | **Available** | **Available** |
| Focus and illumination quality indicators | **Available** | **Available** | **Available** |
| Confluence, colony count, scratch/wound closure, and spheroid/organoid area | **Available** | **Available** | **Available** |
| Marker-positive fraction and transfection efficiency | **Available** | **Available** | **Available** |
| Nuclear:cytoplasmic intensity ratio | **Available** | **Available** | **Available** |
| Colocalization: Pearson and Manders M1/M2 | **Available** | **Available** | **Available** |
| Live/dead and DNA-content cell-cycle summaries | **Available** | **Available** | **Available** |
| Puncta and foci per cell | **Available** | **Available** | **Available** |
| Nearest-neighbour distance, local density, and Clark–Evans spatial statistics | **Available** | **Available** with platform-adapted calculations | **Available** |
| Ordered-sequence tracking, displacement, speed, and directionality | **Available** | **Available** | **Available** |
| Neurite skeleton length attributed to detected somas | **Available** | **Available** | **Available** |
| Calibrated RGB, luminance, and distance line profiles | **Available** | **Available** | **Available** |

Assays return an unavailable or insufficient-evidence state when their required channels, masks, sequence, or
population structure are absent; the application does not fabricate a quantitative result.

## Editing, validation, and review

| Capability | macOS v1.0.13 | Windows v1.0.8 | Web v0.1.0 |
|---|---|---|---|
| Mask fills, contours, boxes, labels, and selection markers | **Available** | **Available** | **Available** |
| Add, remove, resize, merge, split, and freehand-trace corrections | **Available** | **Adapted / limited:** available except freehand tracing | **Adapted / limited:** available except freehand tracing |
| Undo and redo with persisted correction history | **Available** | **Available** | **Available** |
| Include and exclude regions of interest | **Available** | **Available** | **Available** |
| Ground-truth annotations with live precision, recall, and F1 | **Available** | **Available** | **Available** |
| Point- and box-prompt correction | **Available** | **Not available** | **Not available** |
| Propagation, interpolation, and drift-aware sequence correction | **Available** | **Not available** | **Not available** |
| Low-confidence review queue | **Available** | **Available** | **Available** |
| Card and tiled-grid curation | **Available** | **Adapted / limited:** card-based review | **Adapted / limited:** card-based review |
| Reversible mask variants and risk-ranked fields | **Available** | **Not available** | **Not available** |
| Per-image notes and review-confidence labels | **Available** | **Available** | **Available** |
| Confidence, diameter, drift, agreement, and quality-insight summaries | **Available** | **Adapted / limited:** quality indicators without the complete macOS insight panel | **Adapted / limited:** browser-native quality indicators |

## Libraries, studies, and repeatable workflows

| Capability | macOS v1.0.13 | Windows v1.0.8 | Web v0.1.0 |
|---|---|---|---|
| Persistent image library and duplicate groups | **Available** | **Available** | **Available** |
| Batches, conditions, and aggregate summaries | **Available** | **Available** | **Available** |
| Two-condition comparison with Mann–Whitney U and effect size | **Available** | **Available** | **Available** |
| Comparison and summary CSV | **Available** | **Available** | **Available** |
| Versioned analysis protocols for model, calibration, bins, and preprocessing | **Available** | **Available** | **Available** |
| Local fine-tuning | **Available:** reviewed instance masks, grouped train/validation/test splits, real Cellpose 3.x optimization and held-out evaluation | **Available:** Cellpose `cyto3` only | **Not available** |
| Fine-tuned checkpoint version history and rollback or explicit activation | **Available** | **Available** for locally trained `cyto3` versions | **Not available** |
| Searchable model catalog with installation and storage management | **Available** | **Available** for the three supported models | **Adapted / limited:** three-model catalog and local cache status, but artifacts are not bundled |
| Keyboard shortcuts and accessible navigation | **Available** | **Available** with Windows-adapted shortcuts | **Available** |
| Light and dark presentation | **Available** | **Adapted / limited:** intentionally light-only | **Available** |
| In-app support and platform-capability disclosure | **Available** | **Available** | **Available** |

The built-in comparison treats individual cells as independent observations. For publication-level inference,
aggregate by the true biological replicate or use an appropriate hierarchical model; see the
[statistical notes](../README.md#statistical-notes-and-limitations).

## Export and interoperability

| Capability | macOS v1.0.13 | Windows v1.0.8 | Web v0.1.0 |
|---|---|---|---|
| Per-cell CSV | **Available** | **Available** | **Available** |
| Per-image or batch summary CSV | **Available** | **Available** | **Available** |
| Annotated full-resolution PNG | **Available** | **Available** | **Available** |
| PDF lab report | **Available** | **Available** | **Available** |
| Markdown report | **Available** in the sample-folder bundle | **Not available** | **Not available** |
| ImageJ ROI set (`RoiSet.zip`) | **Available** | **Available** | **Available** |
| GeoJSON contours for QuPath and geospatial tools | **Available** | **Available** | **Available** |
| Reproducibility/provenance JSON | **Available** | **Available** | **Available** |
| Ground-truth annotation JSON and CSV | **Available** | **Not available** as a dedicated export | **Not available** as a dedicated export |
| Include/exclude ROI JSON | **Not available** as a dedicated export | **Not available** as a dedicated export | **Available** |
| Label-mask export | **Available:** 16-bit TIFF from the microscopy workspace | **Available:** Cellpose-compatible corrected mask round-trip | **Available:** label-mask PNG and bare NumPy label array |
| Cellpose GUI `_seg.npy` round-trip | **Not available** | **Available** | **Preview / build required**; the current NumPy export is a safe label array, not a GUI session file |
| Self-contained sample folder with source, overlay, tables, ROIs, and reports | **Available** | **Adapted / limited:** whole-batch mirrored export rather than the macOS sample bundle | **Adapted / limited:** individual browser downloads |

## macOS microscopy workspace

The following layer-based exploratory workspace is currently specific to macOS v1.0.13:

- Image, label, point, shape, surface, and track layers with visibility and opacity controls.
- Multidimensional time, Z, and channel navigation.
- Local OME-Zarr / OME-NGFF multiscale arrays, plates, wells, and fields.
- Automatic multiscale resolution selection.
- Translation alignment of image layers.
- Bounded-memory grid mosaics with configurable overlap.
- Automatic lineage construction plus manual split, merge, and gap-closing relationships.
- Label painting with undo and 16-bit training-mask export.
- Saved workspace projects and repeatable recorded workflows.
- Keyframed image-sequence GIF export.
- A curated built-in extension catalog. This release does not download or execute third-party plugin code.

## Deliberate release boundaries

- Web v0.1.0 does not include production model weights. Learned detection is therefore visibly unavailable even
  though the WebGPU interface and three-model catalog are present.
- Web v0.1.0 does not claim proprietary microscope-container import, OME-Zarr, live model training, 3D learned
  inference, or full Cellpose GUI session round-tripping.
- Windows v1.0.8 provides the complete common analysis workflow with three validated models and a CPU-only
  inference path. macOS-only workspace, prompt/sequence correction, and broader model-catalog features are not
  presented as Windows functionality.
- Fine-tuning remains specific to supported model families: macOS supports Cellpose 3.x cytoplasm/nuclei
  bases and compatible custom checkpoints; Windows supports its `cyto3` workflow. Browser training is unavailable.

## macOS v1.0.11 workflow

The macOS v1.0.11 release includes these workflow, interface, and efficiency improvements. Windows and browser
capabilities remain as listed for their separate releases above.

| Workflow | Behavior |
|---|---|
| Models responsiveness | Cached status renders immediately; shared runtime checks use bounded background work, and missing-model results do not trigger another environment refresh. |
| Keyboard navigation | Menus and Help → Keyboard Shortcuts share the actual action registry. Commands operate on the focused screen or canvas and remain disabled when unavailable; text editing and dialogs retain their expected keys. |
| App icon | A microscopy mark is supplied at all ten native macOS icon resolutions, with transparent margins. Source artwork and generation prompts are in docs/branding. |
| Analysis setup | Import without an installed detector, inspect a representative image, set calibration and supported source channels/projection, and run a whole-image preview. Matching previews are reused in the batch. |
| Processing | Jobs and their immutable settings are saved locally before work starts. Pause finishes the current image; resume and retry retain completed work. After an interrupted launch jobs remain paused for explicit resume. Remaining time appears after warm timings exist. |
| Task presets | Cell/nucleus counting opens the overview, positivity leads to measurements/intensity assays, and wound closure leads to area assays. Wound analysis can start with import only. |
| Linked review | Stable cell IDs link image selection, a paged measurement table, and scatter selection. Plot rendering is bounded; brushing evaluates the complete included population. |
| Variant comparison | Two masks share pan and zoom, with classifications for added, removed, and changed objects. Applying an alternative preserves the current mask and restores original run metadata while honoring current measurement calibration. |
| Result context | Per-image job state, recorded model/parameters, current filters, and included/excluded counts distinguish original analysis from later review. Older records explicitly report unknown run settings. |
| Training | Select actual library images, review/correct contours, confirm source planes, and assign specimen groups. Deterministic splits keep groups and duplicate source bytes from leaking across partitions. Validation selects the checkpoint; held-out images are evaluated only after training. |
| Efficiency | Visible-mask culling and path caches reduce redraw work; revision/filter-keyed summaries avoid unrelated recomputation. Assay workers reuse bounded raw-image and mask data, recomputing parameter-dependent outputs. Preparation can overlap a single model execution when estimated memory fits. |

Training currently supports Cellpose 3.x cytoplasm/nuclei bases and compatible custom Cellpose checkpoints.
At least three independent specimen groups and six epochs are required; the default is 40 epochs. Training
uses corrected instance masks and real optimizer progress, and checkpoint activation verifies the resulting
report and file hash. A successful software run does not establish biological accuracy: evaluate performance
on representative independent specimens before interpreting results.

The setup preview covers an entire image. StarDist and SAM retain their existing display-plane input path;
source channel/projection controls are offered only for supported model families. Vendor containers still
require a compatible local Python reader, even when detection is deferred. Runtime/version or weight hashes
that were not recorded at inference remain unknown in exports rather than being inferred from a later install.

The local `scripts/verify-workflow-upgrade.sh` runs the native unit suites, including queue recovery,
pause/resume/retry, preview reuse, source routing, provenance, linked selection, variant comparison, training
validation, geometry indexing, and worker lifecycle tests. The Python worker, training and detection-startup suites also run in CI.

## macOS v1.0.12 preview and startup fixes

- Ordinary single-frame 8-bit PNG/JPEG/BMP previews prepare their selected source channel or RGB luminance natively, before discovering Python. Scientific stacks, high-bit-depth images and unsupported pixel layouts retain the shared source reader.
- Analysis setup displays a bounded original preview while preparing the selected plane. Changes to confidence, calibration or mask results do not restart source decoding.
- The representative-image picker has a valid initial selection, including an explicit empty state. Import completion keeps the presenting screen stable while setup is open.
- Cellpose 3 and 4 report first-use weight-download stages and byte progress. Stalled network operations time out with a retry hint; an interrupted download does not announce completion.
- Images without pixel-size metadata remain usable; calibrated measurements require a known scale.

See the [v1.0.12 release notes](releases/v1.0.12.md) for focused validation and scope.

## macOS v1.0.13 large Review Queues

- Review candidates use stable pages of at most 96 rows, with Skip and undo across page boundaries.
- Decoded cell contours share a cache bounded to six snapshots and an estimated 64 MiB budget.
- Card previews follow their image identity, and overlays render at card size.
- Legacy review-key migration finishes before opening the queue, and older background saves cannot replace a newer correction.

See the [v1.0.13 release notes](releases/v1.0.13.md) for the issue context, focused validation and download checksum.
