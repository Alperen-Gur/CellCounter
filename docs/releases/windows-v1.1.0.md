# CellCounter 1.1.0 for Windows

This release fixes the first-analysis **“Sidecar scripts are not staged”** error
and adds a saved **inspect → preview → process → review** workflow.

Requires Windows 10 or 11 x64. Both the NSIS `.exe` and WiX `.msi` contain the
same application. Installers are **unsigned**; compare their hashes with the
release’s `SHA256SUMS.txt`. See the [Windows guide](../WINDOWS.md).

## First analysis and large review queues

The executable now includes an explicit set of required analysis scripts and
stages them before model setup or analysis. Missing or damaged staged files are
repaired automatically, including files with the expected length but wrong
contents. This removes reliance on the installation folder’s resource layout.
Update and reopen CellCounter; existing images and models do not need a reset.

First-use Cellpose downloads report progress and bounded network errors rather
than failing without context. A selected checkpoint is never silently replaced.

Review loads stable pages of 64 candidates and at most 96 nearby cell outlines.
Keep, Reject and diameter corrections save transactionally against the latest
result. Skip continues through the queue. **Undo / Ctrl+Z** reverses the last Review
decision, including across pages; a newer decision replaces it and a changed
result is protected from stale undo. The undo token lasts for the app session. Very large preview outlines use a
labeled circle approximation; saved contours remain intact.

## Saved analysis and linked results

- Import and inspect before installing a model. Save task, calibration, source
  channel, projection and analysis parameters before starting a batch.
- Preview a representative image. Matching previews are reused during batch
  processing; changed settings or replaced results invalidate reuse.
- Pause after the current image, stop the current operation, resume after
  relaunch and retry failures. Successful images remain saved.
- Select the same cells in the image, paged measurement table and scatter plot.
  Plot drawing is sampled for large results; brushing evaluates all cells.
- Save and compare mask versions with synchronized viewing. Restoring an
  alternative first preserves the current mask. Recorded run settings remain
  separate from current measurement settings.
- Prevent edits to images still queued for processing, and finish saving edits
  before exports, reruns, imports or navigation replace the current result.
- Screen-scoped shortcuts cover navigation, processing, measurements, mask
  versions and actual correction tools while retaining normal text editing.

Source analysis supports channel selection plus maximum, mean, sum or middle
plane projection. The setup viewer still shows the imported display preview;
it does not yet display each selected source plane.

## Training and platform limits

Cellpose `cyto3` training requires at least three specimen groups and six epochs.
A `groups.json` file or supported patient-prefix names identify groups, which
stay in separate train/validation/test partitions. Duplicate sources and
invalid pairs fail explicitly. This is a pair-folder workflow, distinct from
the macOS reviewed-library dataset builder.

The three supported model identities remain Cellpose-SAM (`cpsam_v2`, a legacy
ID for the `cpsam` checkpoint), Cellpose `cyto3`, and StarDist fluorescence.
Inference remains CPU-only. The in-app capability inventory explicitly records
additional native models, OME-Zarr/layer tools, prompt/sequence correction and
other workflows that have not been ported. **Full macOS parity is not claimed.**

## Validation boundary

Focused tests cover embedded-script recovery, source projections, specimen
splits, saved-job recovery, mask restoration and bounded review behavior. The
release packaging workflow builds the frontend and Rust backend on a native
Windows x64 runner and produces both installers with checksums.

A physical Windows workstation’s installer policies, first model downloads,
vendor reader DLLs and representative-image performance remain outside this
local verification. Automated builds do not establish biological accuracy.
