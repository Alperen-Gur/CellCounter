# CellCounter Web 0.3.1 preview

This release adds optional local diagnostics and real-workflow performance recording.

## Changes

- Start a 10-minute, 30-minute or two-hour session, then use real images and the normal import, processing, review, workspace, assay and export controls.
- Inspect aggregate latency, completion and failure counts, unfinished work and recent percentiles.
- Prepare an editable report, remove any lines, confirm you have inspected it, then export exactly the reviewed text.
- Recording is off until you start it. Timings and drafts stay in memory and are never uploaded. Reports exclude image content, names, paths, IDs, device identifiers, raw logs and crash dumps.

See the [diagnostics guide](../INSTALL.md#optional-local-diagnostics-and-real-workflow-benchmarks).

## Install

Static PWA archive. Serve it from a web root over HTTPS or localhost.
