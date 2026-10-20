# Third-party licenses

CellCounter itself is released under the MIT License (see [LICENSE](LICENSE)).
It builds on open-source models and libraries. Model weights are not included in
the source package. Canonical Workbench model registration uses an explicitly
selected local checkpoint and interpreter, without downloading weights or
installing dependencies. Legacy model setup may download upstream weights after
the user chooses a model; those weights retain their upstream terms.

## Segmentation models

| Component | Role in CellCounter | License | Upstream |
|---|---|---|---|
| **Cellpose** | Registered Cellpose 3 inference/training; compatible legacy models | BSD-3-Clause | Stringer & Pachitariu, MouseLand/cellpose |
| **Cellpose-SAM** (CPSAM) | Optional SAM-based segmenter | BSD-3-Clause | MouseLand/cellpose |
| **StarDist 2D** | Optional registered local weights, configuration and thresholds | BSD-3-Clause | stardist/stardist |
| **μSAM** (Segment Anything for Microscopy) | Optional registered local checkpoint and explicit inference mode | MIT | computational-cell-analytics/micro-sam |
| **Omnipose** | Optional registered checkpoint and explicit architecture in a separate interpreter | See the installed version's upstream license and dependencies | kevinjohncutler/omnipose |

## Runtime libraries (Python sidecar)

Desktop releases also bundle Node.js 24.22.0 for the shared microscopy workspace
worker. Node.js is MIT-licensed and includes third-party notices; the complete
upstream `LICENSE` is retained as `node/LICENSE` in each packaged microscopy
runtime. The runtime archive is pinned and verified during packaging.

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

The Python SDK contains CellCounter's shared runtime source and pinned dependency
requirements. Optional MCP, reporting and local OME-Zarr environments install
their own upstream distributions and license notices. The OMERO client is an
explicitly configured separate environment; its client, Ice runtime and server
licenses remain applicable. These optional environments and model checkpoints
are not bundled into the SDK wheel. Vendor compatibility readers use the packages
listed above; registration of a local interpreter does not relicense its packages
or models.

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
