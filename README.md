<div align="center">

# CellCounter

**Count and size-classify cells in microscopy images — without a terminal or a Python script.**

A local, no-code desktop application built on [Cellpose](https://github.com/MouseLand/cellpose).
Point it at a folder of images and get per-cell measurements, size distributions, assays and a report.

[![Latest release](https://img.shields.io/github/v/release/Alperen-Gur/CellCounter?label=macOS&color=0a7ea4)](https://github.com/Alperen-Gur/CellCounter/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/Alperen-Gur/CellCounter/ci.yml?branch=main&label=CI)](https://github.com/Alperen-Gur/CellCounter/actions)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-15%2B-lightgrey?logo=apple&logoColor=white)](#macos--current-release)
[![Windows · Linux](https://img.shields.io/badge/Windows%20·%20Linux-preview-orange)](#windows--macos--linux--cross-platform-preview)

[Install](#install) · [Quick start](#quick-start) · [What it does](#what-it-does) · [Limitations](#statistical-notes-and-limitations) · [Citing](#citing)

</div>

---

CellCounter was written for one task: counting patient-derived oral keratinocytes and comparing their size
distributions across conditions. It is not tied to that cell type — if Cellpose can segment it, CellCounter can
count and measure it. Everything runs on your machine; no account, no upload, no network transfer of image data.

<!-- SCREENSHOTS: add docs/images/hero.png and the gallery below. See docs/images/README.md. -->

## Why it exists

Cellpose has its own GUI, and this does not replace it. CellCounter covers what the general-purpose tools leave to you:

|  | |
|---|---|
| **No environment setup** | The installer builds its own Python environment in the background. No conda, no pip, no PATH. |
| **Sizes, not just masks** | Cells are binned into micrometre size classes using the pixel size read from image metadata. |
| **Assays, not just counts** | Marker-positive %, colocalization, confluence, wound closure, foci per cell, and more. |
| **Local by default** | Nothing leaves the computer. For patient-derived material that is a requirement, not a preference. |

## What it does

### Segmentation

| Model | Best for |
|---|---|
| **Cellpose-SAM** | Large or irregular cells — where `cyto3` merges neighbours into one mask |
| **Cellpose** `cyto3` `cyto2` `nuclei` | General cytoplasm and nuclei |
| **StarDist** | Crowded, roughly convex nuclei |
| **Omnipose** | Bacteria and elongated / filamentous cells |
| **Threshold + watershed** | No weights, no download, no GPU — instant and deterministic |
| **Your own model** | Load a fine-tuned Cellpose checkpoint or a StarDist model directory |

Plus a **second-opinion** mode: run two detectors and review only the cells where they disagree.

### Images

Reads Zeiss `.czi`, Nikon `.nd2`, Leica `.lif`, Olympus `.oif` `.oib` `.oir`, and TIFF / OME-TIFF / PNG —
no conversion step. Handles **Z-stacks** (max / sum / mean projection) and **multi-channel** images,
including which channel to segment on.

### Measurements and assays

<table>
<tr><td valign="top" width="50%">

**Per cell**
- Area, perimeter, equivalent diameter
- Circularity, aspect ratio, solidity, eccentricity
- Per-channel intensity
- Size class

</td><td valign="top" width="50%">

**Per image**
- Counts, per-bin counts, size histogram
- Confluence (% area covered)
- Colony counts
- Nearest-neighbour distance, density, clustering index

</td></tr>
<tr><td valign="top">

**Fluorescence**
- % marker-positive (Ki67, EdU, BrdU, caspase)
- Transfection efficiency
- Nuclear:cytoplasmic ratio
- Colocalization — Pearson, Manders M1/M2
- Live/dead, cell-cycle from DNA content
- Puncta / foci per cell

</td><td valign="top">

**Time series & morphology**
- Scratch / wound-healing closure
- Cell tracking — speed, directionality
- Spheroid and organoid size
- Neurite length per cell

</td></tr>
</table>

### Correction, comparison, export

- **Manual correction** — add, delete, merge, split, resize, or trace a cell by hand. Corrections persist and the exported count is the corrected count.
- **Compare** two conditions with a Mann-Whitney U test and effect size — read the [limitations](#statistical-notes-and-limitations) first.
- **Score against ground truth** — F1, precision, recall vs. your own hand counts.
- **Export** — PDF report, annotated images, per-cell CSV, per-image summary CSV with one column per size bin, ImageJ ROI sets, and GeoJSON (QuPath).
- **Analysis protocols** — save model, diameter, bins and calibration to a file so a whole lab runs identical settings.
- **Duplicate detection** (SHA-256) so the same field is never counted twice.

## Install

### macOS — current release

[![Download](https://img.shields.io/github/v/release/Alperen-Gur/CellCounter?label=Download%20for%20macOS&style=for-the-badge&color=0a7ea4)](https://github.com/Alperen-Gur/CellCounter/releases/latest)

Requires **macOS 15 or later**. Universal binary (Apple silicon and Intel).

1. Download `CellCounter-v*.zip` from the [Releases page](https://github.com/Alperen-Gur/CellCounter/releases/latest).
2. Unzip and move **`CellCounting.app`** into Applications.
   *(The application is called CellCounter; the bundle on disk is still named `CellCounting.app`.)*
3. The app is not notarized, so the first launch is blocked. Open **System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway**. Full walkthrough: [docs/INSTALL.md](docs/INSTALL.md).
4. On first use, open the **Models** tab and click Install. The app sets up its own Python environment — a few minutes, once.

<details>
<summary>macOS says the app is "damaged"</summary>

It isn't. That message is Gatekeeper blocking an unsigned, quarantined download. Move the app to Applications and run:

```bash
xattr -cr /Applications/CellCounting.app
```

Then open it normally. This applies to all unsigned builds here, including the cross-platform `.dmg`.
</details>

### Windows · macOS · Linux — cross-platform preview

A rebuild (Tauri + React, in [`desktop/`](desktop/)) is published as a `desktop-v*` **prerelease**:

| Platform | File | Note |
|---|---|---|
| Windows | `CellCounter_*_x64-setup.exe` | Unsigned — SmartScreen warns; **More info → Run anyway** |
| macOS | `CellCounter_*_universal.dmg` | Unsigned — right-click → Open |
| Linux | — | Builds in CI; no packaged installer yet |

`uv` is bundled, so nothing extra to install. On first run, open the Models tab and install Cellpose.

> [!NOTE]
> The preview installs and runs but has **not** been verified at runtime on real data, and it lags the macOS
> app: it has Cellpose-SAM and the per-cell shape metrics, but not the vendor formats, Z-stacks or the assay suite.

## Quick start

1. Open a folder of images.
2. Pick a model in the **Models** tab and install it if needed.
3. Set the pixel size — filled in automatically when the files carry calibration metadata.
4. Run detection, then review the overlay and fix any misses by hand.
5. Open **Compare** to test two conditions, or **Export** for a PDF, CSV, ROI set or GeoJSON.

## How it works

The interface handles loading, calibration, correction, size-binning, assays, statistics and export.
A local Python sidecar does the segmentation. They talk over a pipe. No data leaves the computer.

```
   Your images ──▶  CellCounter GUI  ──▶  Python sidecar (Cellpose)
                         ▲                        │
                         └────── masks, counts ───┘
                    calibration · size bins · assays · stats · export
```

## Statistical notes and limitations

> [!IMPORTANT]
> CellCounter is a measurement tool; its built-in statistics are for exploration. Read this before a number
> from it goes into a paper.

<details>
<summary><strong>The replication unit is the biological replicate, not the cell</strong></summary>

The Compare tab's Mann-Whitney U test pools every individual cell across all images in a condition and treats
them as independent. For condition-level inference this is pseudoreplication: it inflates n by orders of
magnitude and returns very small p-values for biologically trivial differences.

For publication, aggregate first. Export the per-cell CSV, compute one summary per image (or per patient, or
per well) — for example the median diameter — and test on those replicate-level values, or use a mixed-effects
model with image or patient as a random effect. Treat the in-app pooled test as descriptive only.
</details>

<details>
<summary><strong>No multiple-comparison correction</strong></summary>

Comparing more than two conditions by re-selecting pairs gives uncorrected p-values and significance markers.
Apply Holm or Benjamini-Hochberg (or an omnibus Kruskal-Wallis first) when reporting several contrasts.
</details>

<details>
<summary><strong>Segmentation is not bit-for-bit reproducible across machines</strong></summary>

Counts depend on the model version, the device (GPU or CPU), and the PyTorch and NumPy versions. Expect small
run-to-run and machine-to-machine differences. For a reproducible methods section, record the model, the app
version and the resolved dependency versions — the exported provenance sidecar captures model, calibration and
parameters.
</details>

<details>
<summary><strong>"Size" is an equivalent diameter</strong></summary>

Each cell's size is the diameter of a circle with the same segmented area (`2·√(area/π)`) — a shape-agnostic
proxy, not a measured long or short axis. Per-cell "confidence" is a monotonic transform of Cellpose's
cell-probability, not a calibrated probability.
</details>

<details>
<summary><strong>Assay results are withheld rather than guessed</strong></summary>

Where a number cannot be produced honestly the app says so. For example, % marker-positive is withheld when the
population shows no evidence of two distinct groups — an automatic threshold will otherwise split a single
uniform population and report a confident, meaningless percentage.
</details>

<details>
<summary><strong>Automated test coverage is limited, and nothing is validated against reference data</strong></summary>

Both applications have been through multi-pass code review and adversarial audit, and the measurement code is
checked against synthetic fixtures with known ground truth — but the unit-test suite is a work in progress and
no release has been validated against hand-counted reference data. Check counts against your own before relying
on them; the built-in F1-vs-ground-truth tool exists for exactly this.
</details>

## Roadmap

Done and in CI:

- [x] Windows, Linux and macOS from one Tauri + React codebase
- [x] One-command environment setup via [`uv`](https://github.com/astral-sh/uv)
- [x] Cellpose-GUI parity — draw, merge, split, undo/redo, `_seg.npy` interchange
- [x] Persistent-worker engine — the model stays loaded across a batch

Not yet:

- [ ] Automatic scale-bar detection
- [ ] Verified cross-platform release, after the pipeline is checked on real batches
- [ ] Feature parity between the cross-platform app and macOS
- [ ] In-browser version — Cellpose `cyto3` client-side on WebGPU, no installation
- [ ] Train-from-GUI — fine-tune a model on your own corrected cells

## A note on the name

Several tools share the name "Cell Counter". This project is not affiliated with, and is distinct from, the 2014
application *CELLCOUNTER: Novel Open-Source Software for Counting Cell Migration and Invasion In Vitro* (BioMed
Research International, for Boyden-chamber assays) and the ImageJ / Fiji **Cell Counter** plugin (manual tally
counting). CellCounter here is a Cellpose-driven counting and size-classification desktop application.

## Citing

If CellCounter is useful in your work, please cite it (see [CITATION.cff](CITATION.cff)) **and** the segmentation
model you ran. Because segmentation is entirely Cellpose-mediated:

- Stringer, C., Wang, T., Michaelos, M., & Pachitariu, M. (2021). Cellpose: a generalist algorithm for cellular segmentation. *Nature Methods* **18**, 100–106.
- Pachitariu, M., & Stringer, C. (2022). Cellpose 2.0: how to train your own model. *Nature Methods* **19**, 1634–1641.
- Using `cyto3 + restore` or Cellpose-SAM? Also cite the Cellpose 3 and Cellpose-SAM papers listed in the [Cellpose repository](https://github.com/MouseLand/cellpose).
- Using StarDist or Omnipose? Cite their papers too.

## Built on

[Cellpose](https://github.com/MouseLand/cellpose) (BSD-3-Clause) performs the segmentation. PyTorch, NumPy,
SciPy, scikit-image and tifffile provide the computation; vendor microscope formats are read with permissive
BSD-3 readers. Full inventory and licenses: [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## License

MIT — see [LICENSE](LICENSE). Contributions welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).
