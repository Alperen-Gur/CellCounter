# CellCounter Web 0.3.0 preview

This browser release adds local microscopy workspaces and expanded review.

## Changes

- OME-Zarr v2 sources, multidimensional layers, translation registration, grid stitching, label painting, lineage, project replay and GIF export.
- Source-plane inspection, preprocessing comparisons, prompt/sequence corrections, review skipping and undo, and clearer calibration handling.
- Reviewed dataset TIFF/mask snapshots, sample bundles, reports and artifact hashes.
- Revision-aware saves preserve concurrent edits.

Images stay in the browser. Learned models, proprietary microscope readers and
model training are not included; see the [workspace guide](../PORTABLE-WORKSPACE.md)
for supported formats.

## Install

Serve the ZIP contents from a web root over HTTPS or localhost. Existing
installations can use **Reload app** when an update is offered. Export backups
before clearing site data.
