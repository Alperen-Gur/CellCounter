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

All of the above are permissive (BSD / MIT / Apache-2.0) and compatible with
CellCounter's MIT license.

## Intentionally excluded: Ultralytics YOLO

Earlier development explored **Ultralytics YOLOv11** for box-only detection.
Ultralytics is licensed **AGPL-3.0**, which is incompatible with shipping this
project under a permissive license. The YOLO inference sidecar has therefore
been **removed from the public repository** and is not part of any release. If a
box-only detector is added back in the future it will use a permissively-licensed
implementation.

## A note on model provenance

CellCounter is a GUI and workflow layer. It does not claim authorship of the
underlying segmentation models. If you use CellCounter in published work, please
cite both CellCounter and the specific model you ran (e.g. Cellpose) — see the
"Citing" section of the README.
