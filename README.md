# CellCounter

CellCounter is a desktop application for counting cells in phase-contrast and fluorescence microscopy images and classifying them by size. It wraps [Cellpose](https://github.com/MouseLand/cellpose) in a graphical interface. From a folder of TIFF images it produces per-image counts, size distributions, and a report, without use of a terminal or a Python script.

The tool was written for one task: counting patient-derived oral keratinocytes and comparing their size distributions across conditions. It is not tied to that cell type. If Cellpose can segment a given cell type, CellCounter can count and measure it.

Status, July 2026. The current download is CellCounter 1.0.3 for macOS (requires macOS 15 or later), a native application built as an Apple-silicon and Intel universal binary. A cross-platform desktop rebuild (Tauri; version 0.1.4) is available as a preview — Windows and macOS installers are on the [Releases page](https://github.com/Alperen-Gur/CellCounter/releases), and it also builds on Linux in continuous integration. The preview installs and runs but has not been verified at runtime on real data. An in-browser WebGPU version is planned but not started. See [Roadmap](#roadmap).

_Screenshot: to be added._

## Why it exists

Cellpose provides its own graphical interface, and CellCounter does not replace it. CellCounter exists to cover requirements that the general-purpose tools do not provide directly:

- Installation without environment setup for the person doing the counting. Running the installer sets up the Python environment in the background. There is no conda, pip, or PATH configuration.
- Size classes in addition to masks. Cells are binned into size categories in micrometres, using a pixel size read from the image metadata. The result is a size distribution, not only an outline.
- Comparison between conditions. Two conditions can be compared directly with a Mann-Whitney U test and an effect size.
- Local processing. Everything runs on the local machine. For images derived from patient material this is a requirement.

## What it does

Counting and segmentation

- Cellpose `cyto3`, `cyto2`, `nuclei`, and `cyto3 + restore` models, plus Cellpose-SAM for large or irregular cells.
- Single-image runs or batch processing of a folder.
- An explicit expected-cell-diameter control, separate from the size bins. On Auto the diameter is inferred; set to a value, it is passed to the segmentation model as the size prior. The size prior mainly affects large or isolated cells, which are otherwise under-segmented.
- Manual correction of the model output: add a missed cell, delete a false positive, merge or split, resize, or trace a cell outline by hand. Corrections persist, and the exported count is the corrected count.

Measurement

- Automatic calibration (µm/pixel) from OME-TIFF or EXIF metadata, with a manual override when metadata is absent.
- Size classification into any number of configurable bins. Bins are applied after segmentation, so adding, editing, or removing a bin re-classifies the existing cells at once and does not re-run detection.
- Per-cell area, per-image counts, per-bin counts, and size histograms.

Comparison and statistics

- Comparison of two conditions with the Mann-Whitney U test and rank-biserial effect size.
- Scoring a detector against hand-counted ground truth (F1, precision, recall).

Output

- PDF report and annotated images, with cells drawn along their segmented outlines.
- ImageJ-compatible ROI sets.
- CSV of per-cell measurements, and a per-image summary CSV with one count column per size bin.
- Duplicate-image detection (SHA-256), so the same field is not counted twice.

Privacy

- Processing is local. There is no account, no upload, and no network transfer of image data.

## Install

### macOS (v1.0.3, current release)

1. Download `CellCounter-v1.0.3.zip` from the [Releases page](https://github.com/Alperen-Gur/CellCounter/releases/latest).
2. Unzip it and move CellCounter into the Applications folder.
3. The first launch is blocked by Gatekeeper because the app is not notarized. To allow it, open System Settings, Privacy and Security, scroll to the bottom, and click Open Anyway. A full walkthrough is in [docs/INSTALL.md](docs/INSTALL.md).
4. On first use, click Install Cellpose in the Models tab. The app downloads and sets up its own Python environment. This takes a few minutes and happens once.

If macOS reports the app as "damaged and can't be opened," the app is not damaged. This message is Gatekeeper blocking an unsigned, quarantined download. Move the app to Applications and run the following in Terminal:

```
xattr -cr /Applications/CellCounter.app
```

Then open the app normally. This applies to the unsigned macOS builds, including the cross-platform `.dmg`.

### Windows / macOS / Linux (cross-platform preview)

A preview of the cross-platform rebuild is on the [Releases page](https://github.com/Alperen-Gur/CellCounter/releases) under the latest `desktop-v*` prerelease:

- **Windows**: `CellCounter_*_x64-setup.exe` (or the `.msi`). Unsigned — SmartScreen may warn; choose More info, then Run anyway.
- **macOS**: `CellCounter_*_universal.dmg`. Unsigned — right-click, then Open.
- **Linux**: builds in continuous integration; a packaged installer is not published yet.

It is a preview: it installs and runs but has not been verified at runtime on real data. `uv` is bundled, so no separate install is needed; on first run, open the Models tab and install Cellpose, which downloads the Python environment. A browser (WebGPU) version is planned but not started.

## Quick start

1. Open a folder of images (phase-contrast or fluorescence TIFF/PNG).
2. Select Cellpose cyto3 in the Models tab and install it if needed.
3. Set the pixel size. CellCounter fills this in automatically when the TIFF files carry calibration metadata.
4. Run detection. Review the overlay and correct any misses or false positives by hand.
5. Open Compare to test two conditions, or Export for a PDF, CSV, or ROI set.

## How it works

CellCounter is a graphical interface that drives Cellpose in a local Python sidecar process. The interface handles loading, calibration, correction, size-binning, statistics, and export. The sidecar performs the segmentation. They communicate over a pipe. No data leaves the computer.

```
   Your images ──▶  CellCounter GUI  ──▶  Python sidecar (Cellpose)
                         ▲                        │
                         └────── masks, counts ───┘
                    calibration · size bins · stats · export
```

## Statistical notes and limitations

CellCounter is a counting and measurement tool. Its built-in statistics are for exploration. Several points apply before a value from it is used in a publication:

- The replication unit is the biological replicate, not the cell. The Compare tab's Mann-Whitney U test currently pools every individual cell across all images in a condition and treats them as independent observations. For inferring condition-level differences this is pseudoreplication: it inflates the sample size by orders of magnitude and reports very small p-values for biologically trivial differences. For publication, aggregate to the true experimental unit first. Export the per-cell CSV, compute one summary per image (or per patient or well), for example the median diameter, and run the test on those replicate-level values, or use a mixed-effects model with image or patient as a random effect. Treat the in-app pooled test as descriptive only.
- No multiple-comparison correction. When more than two conditions are compared by re-selecting pairs, the p-values and significance markers are uncorrected. Apply Holm or Benjamini-Hochberg correction (or an omnibus Kruskal-Wallis test first) when reporting several contrasts.
- Segmentation is not bit-for-bit reproducible across machines. Counts depend on the Cellpose model version, the device (GPU or CPU), and the PyTorch and NumPy versions. Expect small run-to-run and machine-to-machine differences. For a reproducible methods section, record the model, the app version, and the resolved dependency versions. The exported provenance sidecar captures the model, calibration, and parameters.
- "Size" is an equivalent diameter. Each cell's size is the diameter of a circle with the same segmented area (`2·√(area/π)`), a shape-agnostic proxy rather than a measured long or short axis. Per-cell "confidence" is a monotonic transform of Cellpose's cell-probability, not a calibrated probability.
- Automated test coverage is limited. The applications have been through multi-pass code review, but the automated unit-test suite for the measurement, statistics, and export code is a work in progress. Validate counts against your own hand-counts (the built-in F1-vs-ground-truth tool helps) before relying on them.

## Roadmap

The cross-platform rebuild (Tauri + React, in `desktop/`) is in progress. The following are complete and passing in continuous integration, and are in preview pending end-to-end verification before release:

- [x] Windows, Linux, and macOS desktop from one Tauri + React codebase, compiling on all three operating systems in CI.
- [x] One-command environment setup via [`uv`](https://github.com/astral-sh/uv), replacing the shell installer.
- [x] Cellpose-GUI parity: manual editing (draw, merge, split), undo/redo, keyboard shortcuts, and `_seg.npy` interchange.
- [x] Persistent-worker detection engine: the model stays loaded across a batch instead of reloading per image.

Not yet done:

- [ ] Public cross-platform release, after the detection pipeline is verified on real batches.
- [ ] In-browser version: Cellpose `cyto3` client-side on WebGPU, with no installation.
- [ ] Train-from-GUI: fine-tuning a model on your own corrected cells.

## A note on the name

Several tools share the name "Cell Counter." This project is not affiliated with, and is distinct from, the 2014 open-source application CELLCOUNTER: Novel Open-Source Software for Counting Cell Migration and Invasion In Vitro (BioMed Research International, 2014, for Boyden-chamber migration and invasion assays) and the ImageJ / Fiji "Cell Counter" plugin (manual tally counting). CellCounter here is a Cellpose-driven counting and size-classification desktop application. Cite it by the DOI or identifier below to disambiguate.

## Citing

If CellCounter is useful in your work, please cite it (a Zenodo DOI will be minted on the first tagged release; see [CITATION.cff](CITATION.cff)) and the segmentation model you ran. Because the segmentation is entirely Cellpose-mediated, cite the relevant Cellpose papers:

- Stringer, C., Wang, T., Michaelos, M., & Pachitariu, M. (2021). Cellpose: a generalist algorithm for cellular segmentation. Nature Methods 18, 100-106.
- Pachitariu, M., & Stringer, C. (2022). Cellpose 2.0: how to train your own model. Nature Methods 19, 1634-1641.
- If you use the `cyto3 + restore` or Cellpose-SAM models, also cite the corresponding Cellpose 3 and Cellpose-SAM papers listed in the [Cellpose repository](https://github.com/MouseLand/cellpose).

## Built on

Cellpose (BSD-3-Clause) performs the segmentation. PyTorch, NumPy, SciPy, scikit-image, and tifffile provide the underlying computation. A full inventory and the licenses are in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## License

MIT. See [LICENSE](LICENSE).

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
