# CellCounter

**Count and size-classify cells in microscope images, on your own machine, without writing code.**

CellCounter is a desktop app for counting cells in phase-contrast (and fluorescence) microscopy images and sorting them into size classes. It wraps [Cellpose](https://github.com/MouseLand/cellpose) in a native GUI, so you can go from a folder of TIFFs to per-image counts, size distributions, and a report — without opening a terminal or writing a Python script.

It was built for one concrete job: counting patient-derived oral keratinocytes and comparing their size distributions across conditions. But nothing in it is tied to that cell type. If Cellpose can segment your cells, CellCounter can count and measure them.

> **Status — July 2026.** The current download is **CellCounter 1.0.2 for macOS** — a native, extensively code-reviewed app (Apple-silicon + Intel universal build). A cross-platform desktop rebuild (Windows, Linux) is compiling green in CI but is still a pre-release preview pending real-world verification; a planned in-browser WebGPU version is not yet started — see [Roadmap](#roadmap).

_Screenshot: to be added._

---

## Why it exists

Cellpose already has an excellent GUI, and CellCounter isn't trying to replace it. It exists because a lab needed a few things the general-purpose tools don't hand you out of the box:

- **No setup for the person doing the counting.** You run an installer; the Python environment sets itself up in the background. No conda, no pip, no PATH surgery.
- **Size classes, not just masks.** Cells are binned into size categories in micrometres, using a pixel-size read automatically from the image metadata. The result is a size *distribution*, not just an outline.
- **Comparison built in.** Put two conditions side by side and get a Mann–Whitney U test with an effect size — so "the cells look bigger in condition B" becomes a number.
- **Your images stay on your machine.** Everything runs locally. For images derived from patient material, that isn't a nice-to-have.

## What it does

**Counting & segmentation**
- Cellpose `cyto3`, `cyto2`, `nuclei`, and `cyto3 + restore`, plus Cellpose-SAM
- Run a single image or batch a whole folder
- Fix the model's mistakes by hand: add a missed cell, delete a false positive — the count you export is the count you checked

**Measurement**
- Automatic calibration (µm/pixel) from OME-TIFF / EXIF metadata, with a manual override when metadata is missing
- Size classification into bins you configure
- Per-cell area, per-image counts, and size histograms

**Comparison & statistics**
- Compare two conditions with the Mann–Whitney U test and rank-biserial effect size
- Score a detector against your own hand-counted ground truth (F1, precision, recall)

**Output**
- PDF report
- ImageJ-compatible ROI sets
- CSV of per-cell measurements
- Duplicate-image detection (SHA-256) so the same field never gets counted twice

**Privacy**
- Fully local. No account, no upload, no network calls with your data.

## Install

### macOS (v1.0.2 — current release)

1. Download `CellCounter-v1.0.2.zip` from the [Releases page](https://github.com/Alperen-Gur/CellCounter/releases/latest).
2. Unzip it and drag **CellCounter** into your Applications folder.
3. The first launch is blocked by Gatekeeper because the app isn't yet notarized. To allow it:
   open **System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway**. Full walkthrough in [docs/INSTALL.md](docs/INSTALL.md).
4. On first use, click **Install Cellpose…** in the Models tab. The app downloads and sets up its own Python environment — this takes a few minutes and only happens once.

### Windows / Linux / Web

Not released yet. The cross-platform version is in active development — see [Roadmap](#roadmap).

## Quick start

1. Open a folder of images (phase-contrast or fluorescence TIFF/PNG).
2. Pick **Cellpose cyto3** in the Models tab (the sensible default) and install it if you haven't.
3. Set the pixel size — CellCounter fills this in automatically if your TIFFs carry calibration metadata.
4. Run detection. Scan the overlay, and correct any misses or false positives by hand.
5. Open **Compare** to test two conditions, or **Export** for a PDF / CSV / ROI set.

## How it works

CellCounter is a native GUI that drives Cellpose in a local Python "sidecar" process. The GUI handles loading, calibration, correction, size-binning, statistics, and export; the sidecar does the segmentation. They talk over a pipe. Nothing leaves your computer.

```
   Your images ──▶  CellCounter GUI  ──▶  Python sidecar (Cellpose)
                         ▲                        │
                         └────── masks, counts ───┘
                    calibration · size bins · stats · export
```

## Statistical notes & limitations

CellCounter is a counting and measurement tool; its built-in statistics are for quick
exploration. A few things matter before you put a number in a paper:

- **The replication unit is your biological replicate, not the cell.** The **Compare**
  tab's Mann–Whitney U test currently pools *every individual cell* across all images in a
  condition and treats them as independent observations. For inferring condition-level
  differences this is **pseudoreplication** — it inflates the sample size by orders of
  magnitude and reports very small p-values for biologically trivial differences. For
  publication, aggregate to your true experimental unit first: export the per-cell CSV,
  compute one summary per image (or per patient / well) — e.g. the median diameter — and
  run the test on those replicate-level values, or use a mixed-effects model with
  image/patient as a random effect. Treat the in-app pooled test as **descriptive only**.
- **No multiple-comparison correction.** When you compare more than two conditions by
  re-selecting pairs, the p-values and significance markers are uncorrected. Apply
  Holm / Benjamini–Hochberg (or an omnibus Kruskal–Wallis first) yourself when reporting
  several contrasts.
- **Segmentation is not bit-for-bit reproducible across machines.** Counts depend on the
  Cellpose model version, the device (GPU vs CPU), and the PyTorch / NumPy versions; expect
  small run-to-run and machine-to-machine differences. For a reproducible methods section,
  record the model, the app version, and the resolved dependency versions — the exported
  provenance sidecar captures the model, calibration, and parameters.
- **"Size" is an equivalent diameter.** Each cell's size is the diameter of a circle with
  the same segmented area (`2·√(area/π)`) — a shape-agnostic proxy, not a measured
  long/short axis. Per-cell "confidence" is a monotonic transform of Cellpose's
  cell-probability, not a calibrated probability.
- **Automated test coverage is still limited.** The apps have been through extensive
  multi-pass code review, but the automated unit-test suite for the measurement / stats /
  export code is a work in progress — validate counts against your own hand-counts (the
  built-in F1-vs-ground-truth tool helps) before relying on them.

## Roadmap

The cross-platform rebuild (Tauri + React, in `desktop/`) is well underway. Done and green in CI, **in preview** pending end-to-end verification before release:

- [x] **Windows / Linux / macOS desktop** — one Tauri + React codebase, compiling on all three OSes in CI
- [x] **One-command environment setup** via [`uv`](https://github.com/astral-sh/uv), replacing the shell installer
- [x] **Cellpose-GUI parity** — manual editing (draw / merge / split), undo/redo, keyboard shortcuts, `_seg.npy` interchange
- [x] **Persistent-worker detection engine** — model stays warm across a batch instead of reloading per image

Still ahead:

- [ ] **Public cross-platform release** — after the detection pipeline is verified on real batches
- [ ] **In-browser version** — Cellpose `cyto3` client-side on WebGPU, no install at all
- [ ] **Train-from-GUI** — fine-tune a model on your own corrected cells

## A note on the name

Several tools share the name "Cell Counter." This project is **not affiliated with**, and is
distinct from, the 2014 open-source application *CELLCOUNTER: Novel Open-Source Software for
Counting Cell Migration and Invasion In Vitro* (*BioMed Research International*, 2014 — for
Boyden-chamber migration/invasion assays) and the classic **ImageJ / Fiji "Cell Counter"**
plugin (manual tally counting). CellCounter here is a Cellpose-driven counting +
size-classification desktop app; cite it by the DOI/identifier below to disambiguate.

## Citing

If CellCounter is useful in your work, please cite it (a Zenodo DOI will be minted on the first
tagged release; see [CITATION.cff](CITATION.cff)) **and** the segmentation model you ran.
Because the segmentation is entirely Cellpose-mediated, cite the relevant Cellpose papers:

- Stringer, C., Wang, T., Michaelos, M., & Pachitariu, M. (2021). *Cellpose: a generalist
  algorithm for cellular segmentation.* **Nature Methods** 18, 100–106.
- Pachitariu, M., & Stringer, C. (2022). *Cellpose 2.0: how to train your own model.*
  **Nature Methods** 19, 1634–1641.
- If you use the `cyto3 + restore` or Cellpose-SAM models, also cite the corresponding
  Cellpose 3 / Cellpose-SAM papers listed in the [Cellpose repository](https://github.com/MouseLand/cellpose).

## Built on

Cellpose (BSD-3-Clause) does the segmentation; PyTorch, NumPy, SciPy, scikit-image, and tifffile do the heavy lifting underneath. Full inventory and licenses in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## License

MIT — see [LICENSE](LICENSE). Do what you like with it; keep the notice.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
