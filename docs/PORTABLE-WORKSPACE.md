# Portable microscopy workspace

This guide describes the microscopy workspaces in **Windows 1.2.0** and
**Web 0.3.0 preview**. Portable implementations have the limits described below.

## Sources and coordinates

Open **Microscopy** and add a library image or choose a local OME-Zarr directory.
Source files remain on the computer. Zarr sources support version 2 arrays,
uncompressed, zlib and gzip chunks, spatial pyramids, and plate fields. Blosc,
Zarr v3, remote datasets and ambiguous multi-image pyramids are not supported.
Choose a supported array or convert it locally first.

Time, Z and channel controls select source planes. Pyramid display levels retain
their relationship to source coordinates; a coarser preview does not change the
meaning of an annotation. Physical pixel sizes are used only when calibration
is present. Combining a calibrated layer with an uncalibrated one requires
resolving the missing calibration first.

Layer transforms are independent of image measurements. Registration estimates
a translation using image correlation and reports a score; inspect the alignment
before using it. Grid stitching creates a derived raster. Neither operation
changes the original files or proves biological correspondence.

## Layers, annotations and painting

Image, label, point, shape, track and surface layers share the workspace view.
Display ranges, colors, opacity and blending affect the display. Surface layers
are shown as projected wireframes, not a volumetric reconstruction.

Painting records semantic class labels and supports session undo. Export labels
as a 16-bit TIFF to preserve integer class values. A colored display PNG or GIF
is a presentation image and must not be used as a numeric training mask.

Lineage links carry explicit continuation, gap, division or merge relationships.
Automatic links are proximity proposals; review them and edit ambiguous links.
A link must move forward in time and cannot create a cycle.

## Save, replay and animation

Save a project to retain layers, positions, transforms, annotations, paint
journals, lineage, recorded operations and animation keyframes. Portable project
files can embed up to 16 MiB of explicitly supplied plane snapshots. Keep the
original datasets: a snapshot does not embed every time point or Z plane, and
external sources must be reattached to navigate them after reopening.

Recorded workflows contain supported workspace operations, rather than arbitrary
scripts. Replay applies to a copy and commits only if all steps succeed.
Generated rasters and live source planes remain subject to memory limits.

Animation interpolates keyframe positions and view settings. GIF export uses a
fixed color palette and centisecond timing; it is intended for presentation.
Reduce frame size, duration or frame rate if the memory limit is reached.

## Review and training snapshots

An image review sign-off binds to its source, geometry, calibration and analysis
settings. Changing these invalidates the sign-off. Exporting a reviewed dataset
requires complete contours and verified calibration; geometry summaries alone
are insufficient.

Assign biological specimen groups explicitly. All fields from one specimen
must stay in the same dataset split. The browser snapshot exporter requires
independent training, validation and test groups, rejects duplicate source
planes and overlapping instance masks, and writes source-plane Float32 TIFFs,
16-bit instance masks, hashes and a manifest. Browser ZIP exports are bounded to
48 MiB of uncompressed artifacts. A reviewed dataset export does not train a
model or create a checkpoint.

## Platform limits

The web application is entirely browser-only and does not use a local native
companion. The browser processes bounded source planes locally. TIFF analysis is limited
to four million pixels per plane, sixteen channels and sixty-four Z planes per
projection. Ambiguous multi-series or multi-file OME-TIFF mappings are rejected.
Large images can be opened at a coarser supported Zarr level or prepared locally.

Browser learned-model inference still requires compatible, qualified model
artifacts. Native Python models, proprietary microscope-container readers and
fine-tuning are not supplied by the static browser application. Classical
segmentation and adaptive prompt refinement are labeled with the method actually
used; they do not silently stand in for a learned model.

Windows uses local Python environments for its detector families. Checkpoint
availability is checked separately from interface availability. Legacy saved
`cpsam_v2` analyses retain their historical `cpsam` checkpoint identity; the
explicit Cellpose 4 checkpoint entries use their own identities.

Windows image overlays and illustrated reports reconstruct the recorded source
plane through the local Python image reader and verify its source hash. They
require that reader environment and a supported source within its limits.
Historical results without a recorded source selection cannot produce an aligned
overlay; sample bundles report the omission explicitly.

These additions have received source review and static checks. Application
launches, inference, automated tests and scientific accuracy evaluation have not
been performed for this change. Production compilation and packaging are required for the release artifacts;
these checks do not establish runtime or scientific accuracy.
