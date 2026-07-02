# CellCounter

**Count and size-classify cells in microscope images, on your own machine, without writing code.**

CellCounter is a desktop app for counting cells in phase-contrast (and fluorescence) microscopy images and sorting them into size classes. It wraps [Cellpose](https://github.com/MouseLand/cellpose) in a native GUI, so you can go from a folder of TIFFs to per-image counts, size distributions, and a report — without opening a terminal or writing a Python script.

It was built for one concrete job: counting patient-derived oral keratinocytes and comparing their size distributions across conditions. But nothing in it is tied to that cell type. If Cellpose can segment your cells, CellCounter can count and measure them.

> **Status — July 2026.** v1.0 ships as a native **macOS** app. A cross-platform rebuild (Windows, Linux, and an in-browser WebGPU version that needs no install at all) is underway — see [Roadmap](#roadmap).

_Screenshot: to be added using public / synthetic images (never patient data)._

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

### macOS (v1.0)

1. Download the latest release from the [Releases page](https://github.com/Alperen-Gur/CellCounter/releases).
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

## Roadmap

- [ ] **Windows & Linux desktop** — cross-platform rebuild on Tauri + React
- [ ] **In-browser version** — Cellpose `cyto3` running client-side on WebGPU, no install at all
- [ ] **One-command environment setup** via [`uv`](https://github.com/astral-sh/uv), replacing the current shell installer
- [ ] **Cellpose-GUI parity** for manual editing — draw / merge / split masks, undo/redo, keyboard shortcuts, `_seg.npy` interchange with Cellpose
- [ ] **Train-from-GUI** — fine-tune a model on your own corrected cells (planned; not in v1)

## Citing

If CellCounter is useful in your work, please cite it (a Zenodo DOI will be minted on the first tagged release; see [CITATION.cff](CITATION.cff)) **and** the segmentation model you ran. If you used Cellpose, cite the Cellpose papers — see their [repository](https://github.com/MouseLand/cellpose).

## Built on

Cellpose (BSD-3-Clause) does the segmentation; PyTorch, NumPy, SciPy, scikit-image, and tifffile do the heavy lifting underneath. Full inventory and licenses in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## License

MIT — see [LICENSE](LICENSE). Do what you like with it; keep the notice.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
