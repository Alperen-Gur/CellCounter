# CellCounter 1.2.0 for Windows

This release expands local microscopy analysis and review on Windows.

x64 EXE and MSI installers, unsigned.

## Changes

- Local OME-Zarr v2 workspaces, multidimensional layers, registration, grid stitching, label painting, lineage, replay and GIF export.
- Additional Cellpose, StarDist, Omnipose, classical and imported-checkpoint routes, with exact model identity checks and clear readiness errors.
- Source-plane inspection, prompt and sequence corrections, grid review, preprocessing comparisons and source-channel measurements.
- Reviewed training-dataset snapshots and sample folders containing original sources, measurements, reports, geometry and hashes.
- Protection against stale edits, calibration changes, source-integrity problems and cancellation. Historical provenance is kept as recorded rather than rebuilt from currently installed weights.

Overlays rebuild the recorded source selection with a local reader and check the
original source hash. Older results without enough source metadata may need to
be rerun. See the [workspace guide](../PORTABLE-WORKSPACE.md) for supported formats.

## Update

Install the EXE or MSI, preferably using the same installer format as before.
Existing library data is preserved. Model setup needs network access to download
runtimes and weights; images stay local. Inference runs on the CPU.
