# Release status and feature parity

Snapshot: **8 September 2026**, for macOS **1.0.13**, Windows **1.1.0**, and
Web **0.2.1 preview**. The two reported desktop defects have fixes in published
downloads. Windows and Web share the main analysis workflow with macOS, but
neither has complete macOS feature parity.

## Reported issues and released fixes

| Platform | Report | Published fix | Evidence and remaining confirmation |
| --- | --- | --- | --- |
| macOS | [Issue #9](https://github.com/Alperen-Gur/CellCounter/issues/9): Review Queue crashes after processing more than 300 images and accumulating over 1,000 candidates | [1.0.13](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.0.13): bounded contour cache, stable 96-candidate pages, smaller card previews, and reliable saved decisions/undo across pages | Nineteen targeted tests passed, including 320 images and 1,280 candidates. The reporter's exact library and crash report were unavailable; confirmation on that library remains pending. |
| Windows | First analysis fails with “Sidecar scripts are not staged” | [1.1.0](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.1.0): required scripts are embedded in the executable, staged before Python operations, and repaired when missing or damaged | Recovery tests and [native Windows installer CI](https://github.com/Alperen-Gur/CellCounter/actions/runs/34170823672) passed. Installation and first model setup on the reporter's physical PC have not been confirmed. |

Earlier macOS improvements to Models-page responsiveness, keyboard commands and
image preview loading are included in 1.0.13 through the
[1.0.11](releases/v1.0.11.md) and [1.0.12](releases/v1.0.12.md) changes.

The [resolution reply to Jonas](https://github.com/Alperen-Gur/CellCounter/issues/9#issuecomment-5577159003)
links the macOS download and upgrade steps. Issue #9 remains open for his
confirmation with the original library.

## Shared workflow, different capabilities

| Workflow | macOS 1.0.13 | Windows 1.1.0 | Web 0.2.1 |
| --- | --- | --- | --- |
| Import, save setup, preview, then process | Available | Available; setup shows the imported display preview | Available for classical segmentation |
| Saved jobs, pause/resume, interruption recovery, failed-image retry | Available | Available | Available |
| Linked image, measurement table and scatter selection | Available | Available | Available |
| Saved mask alternatives and recorded run settings | Available | Available | Available |
| Review uncertain objects | Paged queue with Skip and undo across pages | Paged queue with Skip and one last-decision undo across pages during the session | Accept, reject and resize; no dedicated queue Skip or decision-undo control |
| Learned segmentation | Broader native catalog; some entries remain visibly unavailable | Cellpose-SAM, Cellpose `cyto3`, StarDist fluorescence; CPU-only | Unavailable: three learned-model artifacts are not bundled |
| Classical threshold/watershed segmentation | Available | Not included as a standalone detector | Available locally without model downloads |
| Training | Reviewed-library Cellpose 3.x workflow with grouped splits and held-out evaluation | Grouped image/mask-folder `cyto3` training | Unavailable |

Shared workflow names do not imply identical controls, model results, data
formats or performance. Windows `cpsam_v2` is a legacy ID for the **`cpsam`
checkpoint**, not a distinct Cellpose-SAM v2 checkpoint. The browser's classical
detector is explicitly labeled and does not substitute for an unavailable model.

## Inventory snapshot

| Inventory | Included | Adapted | Requires additional build artifacts | Unavailable | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| Windows | 45 ready | 7 | — | 15 pending | 67 |
| Web | 48 available | Included in each entry's notes | 4 | 17 unsupported | 69 |

These counts come from the
[Windows inventory](../desktop/src/platform/windowsParity.ts) rendered in
**Support → Platform parity**, and the
[Web inventory](../web/src/parity/capabilities.json) rendered in
**Help → Browser capabilities**. The inventories group capabilities differently;
the totals are not completion percentages or equivalent units of work.
“Available” entries can still have explicit limits, and source-reference checks
do not establish performance or scientific equivalence.

The four browser items requiring artifacts are the three learned detectors and
the Cellpose GUI `_seg.npy` round-trip. Exporting a bare NumPy label array is
already possible; it is not a Cellpose GUI session export.

## Main remaining differences

- **Windows:** exact selected source-plane display, the wider native model
  catalog, OME-Zarr and layered multidimensional workspaces, registration and
  stitching, workspace replay/animation/lineage, pixel-class painting,
  prompt/sequence refinement, advanced preprocessing/optimization, bulk grid
  curation, reviewed-library training snapshots, and linked source-channel
  inspection remain unported. Inference is CPU-only and the interface is
  intentionally light-only.
- **Web:** learned weights, training, proprietary microscope-container readers,
  the complete native source/plane viewer, additional models, workspace layers
  and OME-Zarr, registration, lineage, painting, replay, animation, prompt and
  sequence correction, advanced optimization, and workspace extensions remain
  unavailable. Browser storage and source-size limits also differ from native
  storage; see the [browser guide](WEB.md).
- **macOS:** remains the broadest native implementation. This does not mean
  every catalog entry is runnable or every export exists: for example, it does
  not provide Windows' Cellpose GUI `_seg.npy` round-trip. Check the
  [detailed feature matrix](FEATURES.md) for the specific workflow needed.

## Updating after the reported failures

On macOS, quit the old copy, install **CellCounting.app** from 1.0.13, and reopen
**Review Queue**. Existing images and corrections are preserved; no library
reset is required. See the [installation guide](INSTALL.md#large-review-queues).

On Windows, quit CellCounter and install the 1.1.0 `.exe` or `.msi`, preferably
using the same installer format as before. Retain application data and reopen
the app; required scripts are staged or repaired automatically. Model setup can
still require internet access for its first package/weight download. See the
[Windows upgrade and troubleshooting guide](WINDOWS.md).

The macOS download is universal, ad-hoc signed and not notarized. Windows
installers are unsigned x64 packages. Those packaging properties are separate
from the two code fixes. Web 0.2.1 is a static PWA release archive; publishing it
does not create a hosted analysis service.
