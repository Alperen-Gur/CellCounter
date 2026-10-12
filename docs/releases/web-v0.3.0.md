# CellCounter Web 0.3.0 preview

This browser-only release adds local microscopy workspaces and expanded review.

- OME-Zarr v2 sources, multidimensional layers, translation registration, grid stitching, label painting, lineage, project replay and GIF export.
- Source-plane inspection, preprocessing comparisons, prompt/sequence corrections, review skipping and undo, and clearer calibration handling.
- Reviewed dataset TIFF/mask snapshots, sample bundles, reports and artifact hashes.
- Revision-aware saves preserve concurrent edits; source selection, decoding, contour extraction and dense matching have explicit limits.

Images remain in the browser; no native companion or image-upload service is used.
Learned model artifacts, proprietary microscope readers and actual model training
remain unavailable. Algorithms and limits differ from native platforms; see the
[workspace guide](../PORTABLE-WORKSPACE.md).

Serve the ZIP contents from a web root over HTTPS or localhost. This is a static
PWA archive, not a newly hosted service. Existing installations can use Reload app
when an update is offered. Retain exported backups before clearing site data.

Production compilation and artifact checks are used for this release. Automated
tests, interactive browser checks and inference were not run. Preview status and
scientific-validation limitations remain.
