# CellCounter 1.2.1 for Windows

This release adds optional local diagnostics and real-workflow performance recording.

- Start a 10-minute, 30-minute or two-hour session, then use real images and normal import, processing, review, workspace, assay and export controls.
- Inspect aggregate latency, completion/failure counts, unfinished work and recent percentiles. Unobserved operations and omitted observations are explicit; nested timings overlap.
- Prepare an editable report, remove any lines, confirm inspection, then export exactly the reviewed text.
- Recording is off initially. Timings and drafts remain in memory; unsaved results are lost on a crash or app exit. No automatic uploads, image content, names, paths, IDs, device identifiers, raw logs or crash dumps are included.

Timing summaries do not establish segmentation accuracy. Existing browser/native format and model limits remain. See the [diagnostics guide](../INSTALL.md#optional-local-diagnostics-and-real-workflow-benchmarks).

Production compilation and package/checksum checks are used for these releases. Automated tests, app launches, inference and actual benchmarks were not run.

Unsigned x64 EXE/MSI installers for Windows 10/11. Install using the same installer format as before. Existing data is retained; inference remains CPU-only.
