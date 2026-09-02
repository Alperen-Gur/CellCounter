# CellCounter feature reference

This is the public feature inventory for the currently documented releases: macOS v1.0.10, Windows v1.0.8,
and Web v0.1.0 preview. It describes user-facing behavior and deliberately omits private implementation details.

Status meanings:

- **Available** — included and usable in the named release.
- **Adapted / limited** — included with a documented platform-specific difference.
- **Preview / build required** — the interface or workflow is present, but a required production component or validation step is not complete.
- **Not available** — intentionally absent from that release.

For installation and operational guidance, see the [main README](../README.md), [Windows guide](WINDOWS.md), and
[web guide](WEB.md).

## Privacy and storage

| Capability | macOS v1.0.10 | Windows v1.0.8 | Web v0.1.0 |
|---|---|---|---|
| Local image analysis with no image-upload path | **Available** | **Available** | **Available** |
| Account-free use | **Available** | **Available** | **Available** |
| Persistent local projects, images, measurements, and corrections | **Available** | **Available** | **Available** in browser-managed storage |
| Offline use after application and required models are installed | **Available** | **Available** | **Available** after PWA installation; learned models remain build required |
| Local data reset | **Available** | **Available** | **Available** |
| Reproducibility metadata with image, model, calibration, and analysis settings | **Available** | **Available** | **Available** |

## Import and calibration

| Capability | macOS v1.0.10 | Windows v1.0.8 | Web v0.1.0 |
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

| Model or family | macOS v1.0.10 | Windows v1.0.8 | Web v0.1.0 |
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

| Capability | macOS v1.0.10 | Windows v1.0.8 | Web v0.1.0 |
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

| Capability | macOS v1.0.10 | Windows v1.0.8 | Web v0.1.0 |
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

| Capability | macOS v1.0.10 | Windows v1.0.8 | Web v0.1.0 |
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

| Capability | macOS v1.0.10 | Windows v1.0.8 | Web v0.1.0 |
|---|---|---|---|
| Persistent image library and duplicate groups | **Available** | **Available** | **Available** |
| Batches, conditions, and aggregate summaries | **Available** | **Available** | **Available** |
| Two-condition comparison with Mann–Whitney U and effect size | **Available** | **Available** | **Available** |
| Comparison and summary CSV | **Available** | **Available** | **Available** |
| Versioned analysis protocols for model, calibration, bins, and preprocessing | **Available** | **Available** | **Available** |
| Local fine-tuning | **Preview:** training and version history are present; guided labeling and evaluation contain illustrative preview elements | **Available:** Cellpose `cyto3` only | **Not available** |
| Fine-tuned checkpoint version history and rollback or explicit activation | **Available** | **Available** for locally trained `cyto3` versions | **Not available** |
| Searchable model catalog with installation and storage management | **Available** | **Available** for the three supported models | **Adapted / limited:** three-model catalog and local cache status, but artifacts are not bundled |
| Keyboard shortcuts and accessible navigation | **Available** | **Available** with Windows-adapted shortcuts | **Available** |
| Light and dark presentation | **Available** | **Adapted / limited:** intentionally light-only | **Available** |
| In-app support and platform-capability disclosure | **Available** | **Available** | **Available** |

The built-in comparison treats individual cells as independent observations. For publication-level inference,
aggregate by the true biological replicate or use an appropriate hierarchical model; see the
[statistical notes](../README.md#statistical-notes-and-limitations).

## Export and interoperability

| Capability | macOS v1.0.10 | Windows v1.0.8 | Web v0.1.0 |
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

The following layer-based exploratory workspace is currently specific to macOS v1.0.10:

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
- Fine-tuning availability is intentionally described per platform because the macOS guided labeling and
  evaluation screens still contain clearly labeled preview elements, while Windows provides the validated
  `cyto3` training workflow.
