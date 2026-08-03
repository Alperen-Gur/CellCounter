# Third-party licenses

CellCounter itself is released under the MIT License (see [LICENSE](LICENSE)).
It builds on a number of open-source models and libraries. Model **weights are
downloaded at runtime from their upstream sources** — they are not redistributed
in this repository.

## Segmentation models

| Component | Role in CellCounter | License | Upstream |
|---|---|---|---|
| **Cellpose** (`cyto3`, `cyto2`, `nuclei`, `cyto3+restore`) | Primary cell segmentation. This is what the shipping app runs. | BSD-3-Clause | Stringer & Pachitariu, MouseLand/cellpose |
| **Cellpose-SAM** (CPSAM) | Optional SAM-based segmenter | BSD-3-Clause | MouseLand/cellpose |
| **StarDist** (2D versatile fluo / H&E / DSB2018) | Planned integration ("Coming soon") | BSD-3-Clause | stardist/stardist |
| **Segment Anything (SAM)** / **MobileSAM** | Planned integration ("Coming soon") | Apache-2.0 | facebookresearch/segment-anything, ChaoningZhang/MobileSAM |
| **μSAM** (Segment Anything for Microscopy: LM / EM generalist) | Planned integration ("Coming soon") | MIT | computational-cell-analytics/micro-sam |
| **patho-sam** | Planned integration ("Coming soon") | see upstream | computational-cell-analytics/patho-sam |

## Runtime libraries (Python sidecar)

| Library | License |
|---|---|
| PyTorch | BSD-style (modified BSD) |
| NumPy, SciPy | BSD-3-Clause |
| scikit-image | BSD-3-Clause |
| tifffile | BSD-3-Clause |
| Pillow | HPND / MIT-CMU |
| imagecodecs | BSD-3-Clause |
| czifile (Zeiss `.czi`) | BSD-3-Clause |
| nd2 (Nikon `.nd2`) | BSD-3-Clause |
| liffile (Leica `.lif`) | BSD-3-Clause |
| oiffile (Olympus `.oif`/`.oib`) | BSD-3-Clause |
| oirfile (Olympus `.oir`) | BSD-3-Clause |

All of the above are permissive (BSD / MIT / Apache-2.0) and compatible with
CellCounter's MIT license.

Vendor microscope formats are read with the pure-Python BSD-3 readers listed
above rather than Bio-Formats. Bio-Formats is GPL-2.0, and its permissive
subset does not include any of the vendor readers — every one of them lives in
its GPL component — so linking it would require relicensing this app. The same
applies to several packages that appear permissive but depend on GPL readers:
`bioio-czi` (GPL-3.0), `bioio-lif` (via `readlif`, GPL-3.0), `bioio-bioformats`
(via `bffile`, GPL-2.0), `aicspylibczi`, `pyometiff` and `czitools`. None of
those are used here.

## No AGPL / Ultralytics components

CellCounter does **not** include, link against, or download any AGPL-3.0
component. In particular it ships **no Ultralytics YOLO** code or weights: there
is no YOLO detection service, downloader, model-catalog entry, or sidecar in the
source tree or in any built release. If a box-only detector is added in the
future it will use a permissively-licensed implementation.

## A note on model provenance

CellCounter is a GUI and workflow layer. It does not claim authorship of the
underlying segmentation models. If you use CellCounter in published work, please
cite both CellCounter and the specific model you ran (e.g. Cellpose) — see the
"Citing" section of the README.
