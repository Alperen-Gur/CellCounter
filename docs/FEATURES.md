# CellCounter features

CellCounter is a local microscopy analysis application for importing images,
segmenting and reviewing objects, measuring results, and exporting an analysis
with its provenance. The current desktop releases are **macOS 1.1.0** and
**Windows 1.3.0**. **Web 0.3.2 preview** provides a smaller browser-based workflow.

The tables below describe the current desktop **Workbench**. Existing image-library
and portable microscopy tools remain available, with platform-specific behavior.
See the [platform comparison](PLATFORM-PARITY.md) for these distinctions and the
[Workbench guide](WORKBENCH.md) for operation-level details.
For other microscopy tools, see the [feature comparison](../README.md#feature-comparison)
and [commercial software comparison](COMPARISON.md).

## Import and organize

| Capability | Current support |
| --- | --- |
| Scientific images | TIFF/OME-TIFF, PNG, JPEG and BMP, with explicit source channel, supported projection and time selection. Supported TIFF axis layouts and decoding limits apply. |
| Large source regions | Bounded overviews and original-resolution regions from supported TIFF and NGFF sources; selected tiled threshold analysis. |
| OME-Zarr / OME-NGFF | Supported NGFF 0.4/Zarr v2 and 0.5/Zarr v3 routes through the dedicated storage dependencies; not every codec or remote store is supported. |
| OMERO | Read-only raw-region import through an explicitly configured local profile and isolated runtime. Credentials remain host-local. |
| Calibration | Metadata-derived or explicit independent X, Y and Z spacing; unknown spacing stays unknown. Changing calibration updates applicable measurements. |
| Acquisition library | Searchable, paged catalogues with retained source identity, provenance, history and explicit repair/migration controls. |
| Experimental structure | Conditions, plates, wells, biological specimens, assignments and reasoned exclusions. Image fields do not automatically become biological replicates. |

Proprietary-format availability depends on the reader and workflow in use. The
shared Workbench does not provide a built-in VSI reader. A format accepted by an
existing library importer is not automatically supported by every shared operation.

## Segment, correct and review

| Capability | Current support |
| --- | --- |
| Classical segmentation | Otsu, manual, triangle, Li, Yen, mean and adaptive thresholds for planes, with supported polarity, hole-filling and watershed controls; Otsu/manual thresholding and watershed for selected volumes. |
| Registered learned models | Explicit local Cellpose 3/4, StarDist 2D, Omnipose and micro-SAM adapters with retained checkpoint/configuration identity and a compatible selected interpreter. These adapters perform 2D inference. |
| External labels | Preview and import integer TIFF or NPY instance masks on an exactly matching plane or volume grid. |
| Exact corrections | Add, delete, merge and edit object labels; volume slice polygons and spherical-brush edits; undo and retained correction history. |
| Independent masks | Separate analyses on the same immutable source, including nuclear and whole-cell masks; agreement comparison on compatible grids. |
| Structured review | Flags, deterministic random sampling, blinded review presentation, independent declared reviewers, adjudication and retained decisions. Reviewer identities are local declarations, not authenticated accounts. |
| Model adaptation | Guided review selection, supported Cellpose 3 training and retained evaluation on separately assigned specimens. Model activation is explicit. |

A model catalogue entry does not imply that its packages or checkpoint are
installed. Registered methods and executable plugins require explicit local
configuration and trust; the Workbench does not silently substitute another model.

## Measure and interpret

| Area | Current support |
| --- | --- |
| Object measurements | Counts, calibrated area/volume, morphology, centroid and intensity measurements; 3D surface/shape measurements within declared extraction bounds. |
| Fluorescence and cellular assays | Marker/reporter positivity, colocalization, live/dead classification, DNA-content estimates, nuclear:cytoplasmic intensity and puncta measurements. Each assay declares its required masks, channels and dimensions. |
| Spatial and temporal analysis | Spatial neighborhoods, ordered time-series analyses, wound-closure series and motion summaries, with explicit timestamps and input dependencies. |
| Tracking and lineage | Bounded matching with displacement/gap controls, manual link corrections, temporal inference and reviewed lineage/division relationships. Division proposals are heuristic and require review. |
| Biological-replicate statistics | Specimen-level input tables, independent Welch contrasts, paired-subject t contrasts and typed linear models with selected interactions and optional subject/block fixed effects. |
| Statistical exports | Retained input/effect tables, complete JSON reports and vector SVG effect plots, including exclusions, currentness and declared multiplicity handling. |

Statistical designs require explicit biological specimen assignments. General
mixed/random-effects, permutation and nonparametric methods are not part of the
shared statistical engine. Assay thresholds and statistical assumptions require
scientific judgment. See [experimental designs and statistical reports](WORKBENCH.md#experimental-designs-and-statistical-reports).

## View and process multidimensional images

- Linked XY, XZ and YZ slices and a rotatable volume display, with shared source coordinates.
- Multi-channel color composites, intensity windows, gamma and versioned display presets.
- Layer workspaces with image, label, point, shape, track and surface layers; painting, annotations, semantic journals, replay and GIF presentation export.
- Ordered preprocessing recipes with smoothing, background correction, normalization, contrast enhancement and supported sharpening/restoration methods.
- Richardson–Lucy deconvolution with an explicitly synthetic Gaussian PSF; measured-PSF restoration is not supplied.
- Bounded 2D translation registration and supported grid stitching, retaining transforms and acquired-support masks.

Viewing controls do not change scientific intensities or labels. Volume rendering
uses at most **128 samples per axis**; scientific measurements and edits use the
original voxels of the selected volume, within the computation limits below.

## Repeat, refresh and export

| Capability | Current support |
| --- | --- |
| Saved workflows | Linear and branching graphs, previews, parameter sweeps, review gates and frozen method/input references. Branches execute sequentially. |
| Resumable processing | Saved jobs, background workers, checkpoints, pause/resume and explicit recovery after interruption. |
| Portable tasks | Explicit preparation, transfer and collection of isolated work packets; not an automated remote scheduler or a merge into coordinator masks. |
| Correction-aware results | Immediate canonical measurements after mask edits; stale-result reporting and explicit dependency-ordered refresh of supported derived results. Previous outputs remain in history. |
| Scientific files | Calibrated source/label images, measurement tables, annotations, overlays, lineage files and provenance in the formats offered by each export catalogue. |
| Analysis packages | Hash-verified, resumable packages retaining scientific sources, labels, results and method provenance. Restored executable methods remain disabled until explicitly configured and enabled. |

Refresh reapplies stored registration transforms; it does not re-estimate
alignment. It does not universally rerun segmentation or overwrite exported
reports. Export a new report when results change.

## Automation and extension

The desktop GUI, installed CLI, Python SDK and MCP server use the same project
operations, revision checks and history. MCP connections default to read-only
access and can grant project writes, particular source/export folders and trusted
executable methods. Compact discovery lets agents request relevant schemas as
needed. See [agent connection setup](WORKBENCH.md#mcp-connection).

Local executable plugins support **reader, segmentation, measurement and exporter**
roles. Processor, tracker and assay plugin roles are not currently implemented.
Environment inventories record observed versions; they are not installable lockfiles
or a guarantee of identical numerical results on another computer.

## Current operating limits

| Scope | Limit or boundary |
| --- | --- |
| Standard imported source | 512 MiB source file; 256 MiB decoded data; supported single-series TIFF layouts |
| Selected plane | 16 million pixels; up to 32 channels and 20,000 objects |
| Selected scientific volume | 8 million voxels |
| Automatic tracking | 2,000 objects per frame |
| Tiled segmentation | Supported plane threshold/connected-components workflow; no general tiled learned-model inference |
| Indexed project | Up to 100,000 acquisitions and 500,000 retained artifacts |
| Streamed project package | Up to 32 GiB; computation limits still apply after restoration |
| Workflow execution | No general conditional execution or automated cluster queue |

These are supported bounds, not throughput or accuracy claims. Some operations
have narrower limits. Use the installed capability descriptions and the
[Workbench guide](WORKBENCH.md) when preparing a specific dataset.

## Browser preview

The browser provides local classical segmentation, measurements, correction,
portable layer workspaces, processing jobs and file exports. It does not run the
desktop filesystem-backed Workbench, CLI or MCP server. Qualified learned-model
artifacts, native model training and proprietary readers are not included.
See the [browser guide](WEB.md) for formats, storage and memory limits.

For installation, see the [macOS guide](INSTALL.md) or [Windows guide](WINDOWS.md).
Release-specific changes remain in the [macOS](releases/v1.1.0.md),
[Windows](releases/windows-v1.3.0.md) and [browser](releases/web-v0.3.2.md) release notes.
