# CellCounter 1.1.0 for Windows

This release fixes the first-analysis **“Sidecar scripts are not staged”** error
and adds a saved **inspect → preview → process → review** workflow.

Requires Windows 10 or 11 x64. The NSIS `.exe` and WiX `.msi` contain the same
application. Installers are unsigned; compare their hashes with the release’s
`SHA256SUMS.txt`. See the [Windows guide](../WINDOWS.md).

## First analysis and large review queues

The app now includes the required analysis scripts and stages them before model
setup or analysis. Missing or damaged staged files are repaired automatically.

First-use Cellpose downloads report progress and clear network errors. A
selected checkpoint is never replaced silently.

Review loads stable pages of candidates. Keep, Reject and diameter corrections
are saved against the latest result, Skip continues through the whole queue,
and **Undo / Ctrl+Z** reverses the last review decision, including across pages,
for the rest of the session. Very large outlines are previewed as labelled
circles; saved contours are unchanged.

## Saved analysis and linked results

- Import and inspect before installing a model. Save task, calibration, source
  channel, projection and analysis parameters before starting a batch.
- Preview a representative image. Matching previews are reused during batch
  processing; changed settings or replaced results trigger a new run.
- Pause after the current image, stop the current operation, resume after
  relaunch and retry failures. Successful images stay saved.
- Select the same cells in the image, paged measurement table and scatter plot.
  Large plots are drawn from a sample; brushing selects across all cells.
- Save and compare mask versions with synchronized viewing. Restoring an
  alternative keeps the current mask first. Recorded run settings stay
  separate from current measurement settings.
- Prevent edits to images still queued for processing, and finish saving edits
  before exports, reruns, imports or navigation replace the current result.
- Screen-scoped shortcuts cover navigation, processing, measurements, mask
  versions and correction tools while keeping normal text editing.

Source analysis supports channel selection plus maximum, mean, sum or middle
plane projection.

## Training and models

Cellpose `cyto3` training requires at least three specimen groups and six epochs.
A `groups.json` file or supported patient-prefix names identify groups, which
stay in separate train/validation/test partitions. Duplicate sources and
invalid pairs are rejected. This pair-folder workflow differs from the macOS
reviewed-library dataset builder.

Supported models are Cellpose-SAM (`cpsam_v2`, a legacy ID for the `cpsam`
checkpoint), Cellpose `cyto3` and StarDist fluorescence, with CPU inference.
See the [platform comparison](../PLATFORM-PARITY.md) and
[feature guide](../FEATURES.md) for differences between editions.

## Update

Install the new release and reopen CellCounter. Existing images and models do
not need a reset.
