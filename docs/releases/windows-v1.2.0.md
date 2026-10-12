# CellCounter 1.2.0 for Windows

This release expands local microscopy analysis and review on Windows.

- Local OME-Zarr v2 workspaces, multidimensional layers, registration, grid stitching, label painting, lineage, replay and GIF export.
- Additional Cellpose, StarDist, Omnipose, classical and imported-checkpoint routes, with exact model identity checks and explicit readiness failures.
- Source-plane inspection, prompt and sequence corrections, grid review, preprocessing comparisons and source-channel measurements.
- Reviewed training-dataset snapshots and sample folders containing original sources, measurements, reports, geometry and hashes.
- Guards for stale edits, calibration changes, source integrity, cancellation and large workloads. Historical provenance is retained rather than reconstructed from currently installed weights.

Install the x64 EXE or MSI, preferably using the same installer format as before.
Existing library data is preserved. Installers are unsigned. Model setup requires
network access for runtimes and weights; images remain local. Inference is CPU-only.

Overlays reconstruct the recorded source selection through a local reader and
verify the original source hash. Historical results without sufficient source
metadata may need to be rerun. Supported formats and resource limits are described
in the [workspace guide](../PORTABLE-WORKSPACE.md).

The release uses production compilation, installer generation and checksum checks.
Automated tests, interactive installation/app checks and inference were not run.
This release does not claim scientific validation or complete macOS equivalence.
