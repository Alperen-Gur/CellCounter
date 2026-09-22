# Release status and feature parity

Snapshot: **22 September 2026**, for macOS **1.0.14**, Windows **1.1.1**, and
Web **0.2.1 preview**. The macOS download contains further review fixes. Windows
1.1.1 contains local image-access and preview-recovery fixes. Windows and Web share the main analysis workflow with macOS, but neither
has complete macOS feature parity.

## Reported issues and released fixes

| Platform | Report | Published fix | Evidence and remaining confirmation |
| --- | --- | --- | --- |
| macOS | [Issue #10](https://github.com/Alperen-Gur/CellCounter/issues/10): Review Queue crashes persist after the earlier large-queue update | [1.0.14](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.0.14): stale-entry repair, bounded background decoding, guarded saves and undo, delayed-edit protection, and synchronized calibration | Universal archive built. Automated tests and interactive validation were not run for this patch. The reporter's exact crash remains unconfirmed. |
| Windows | Broken thumbnails and full previews after successful imports | [1.1.1](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.1.1): corrected library access and native preview recovery | Native installer packaging and checksum checks only; no automated tests or interactive validation for this patch. |
| Windows | First analysis fails with “Sidecar scripts are not staged” | [1.1.0](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.1.0): required scripts are embedded in the executable, staged before Python operations, and repaired when missing or damaged | Recovery tests and [native Windows installer CI](https://github.com/Alperen-Gur/CellCounter/actions/runs/34170823672) passed. Installation and first model setup on the reporter's physical PC have not been confirmed. |

Earlier macOS improvements to Models-page responsiveness, keyboard commands and
image preview loading are included in 1.0.13 through the
[1.0.11](releases/v1.0.11.md) and [1.0.12](releases/v1.0.12.md) changes.

Issue #9 is closed; the follow-up crash report is tracked in [issue #10](https://github.com/Alperen-Gur/CellCounter/issues/10). Windows 1.1.1 includes corrected local image access and preview recovery. Automated tests and interactive validation were not run for this patch; behavior on the reporter's PC remains unconfirmed.

## Shared workflow, different capabilities

| Workflow | macOS 1.0.14 | Windows 1.1.1 | Web 0.2.1 |
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

On macOS, quit the old copy, install **CellCounting.app** from 1.0.14, and reopen
**Review Queue**. Existing images and corrections are preserved; no library
reset is required. See the [installation guide](INSTALL.md#large-review-queues).

On Windows, quit CellCounter and install the 1.1.1 `.exe` or `.msi`, preferably
using the same installer format as before. Retain application data and reopen
the app; required scripts are staged or repaired automatically. Model setup can
still require internet access for its first package/weight download. See the
[Windows upgrade and troubleshooting guide](WINDOWS.md).

The macOS download is universal, ad-hoc signed and not notarized. Windows
installers are unsigned x64 packages. Those packaging properties are separate
from the two code fixes. Web 0.2.1 is a static PWA release archive; publishing it
does not create a hosted analysis service.
