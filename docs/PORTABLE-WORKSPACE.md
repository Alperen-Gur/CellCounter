# Portable microscopy workspace

Work with image layers, annotations, labels and tracks in a portable workspace.
This guide covers the browser workspace and shared layer tools. For Windows
Workbench projects, see [layer workspaces](WORKBENCH.md#layer-workspaces-and-semantic-journals).

## Sources and coordinates

In the browser, open **Microscopy** and add a library image or a local OME-Zarr
directory. The Zarr v2 reader opens spatial pyramids and plate fields with
uncompressed, zlib or gzip chunks.

Use the time, Z and channel controls to select a plane. Annotations stay in source
coordinates as you switch pyramid levels. Set calibration before combining
layers for physical measurements.

Use translation registration to align images, or grid stitching to create a
combined raster. Check the alignment before continuing. Original files stay
unchanged.

## Layers, annotations and painting

Add image, label, point, shape, track and surface layers. Adjust display range,
color, opacity and blending in the layer controls. Surface layers appear as
wireframe projections.

Paint class labels with session undo. Export labels as a 16-bit TIFF to preserve
their integer values; use PNG or GIF for presentations.

Create continuation, gap, division and merge links between objects. Review
automatic proximity links and edit them where needed. Links move forward in
time.

## Save, replay and animation

Save a workspace document to keep layers, transforms, annotations, painting,
lineage, recorded operations and animation keyframes. Keep the original datasets
with it, and reattach external sources when reopening on another computer.

Recorded workflows let you repeat workspace operations. Replay runs on a copy
and saves the result when every step succeeds.

Add keyframes to animate positions and view settings, then export a GIF. Reduce
frame size, duration or frame rate if export runs out of memory.

## Review and training snapshots

Review sign-offs record the source, geometry, calibration and analysis settings.
Changing these marks the image for review again.

To export a training dataset, finish the contours, check calibration and assign
biological specimen groups. Keep all fields from the same specimen in one split,
then choose training, validation and test groups.

The exporter checks duplicate planes and overlapping masks, then writes Float32
source TIFFs, 16-bit instance masks and a manifest with hashes.

For installation and troubleshooting, see the [Windows guide](WINDOWS.md) or
[browser guide](WEB.md). See [features](FEATURES.md) for the rest of the workbench.
