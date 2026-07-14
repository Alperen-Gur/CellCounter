# Researcher-feedback fixes & v2 polish (native macOS app)

This document records a batch of fixes to the **native macOS (Swift) app**
(`CellCounting/`) driven by researcher feedback (Jonas' 11-point review) plus a
round of v2 polish. It is written so the **same changes can be re-applied to the
cross-platform Tauri app (`desktop/`) later** — each item has a "Tauri port"
note pointing at the equivalent file/seam.

Status at time of writing:
- All changed Swift files pass `swiftc -parse` (syntax gate). ✅
- Full Xcode type-check / build and interactive visual QA were **not** run here
  (this environment only has Command Line Tools, not full Xcode). Those are the
  remaining gate — see [Verification & open items](#verification--open-items).
- The Tauri port is **deliberately deferred** — nothing under `desktop/` was
  changed in this batch.

---

## Runtime facts you need before porting

- **The native app bundles `CellCounting/python/*.py`**, via a Copy-Files build
  phase in `CellCounting.xcodeproj/project.pbxproj` (`$(SRCROOT)/CellCounting/python/…`).
  At first run these are staged into `~/Library/Application Support/CellCounter/python/`
  (`FileStore.pythonDir`). **That is the live tree** the detection sidecars run from.
- The top-level **`Resources/python/`** is a **stale, ~640-line-divergent legacy
  copy** (older monolithic `cellpose_detect.py` that used `diameter=None`, no
  `cellpose4_detect.py`). It is **not** referenced by the build and was left
  untouched. It should be removed or reconciled in a separate cleanup (see open
  items) — do **not** treat it as a source of truth.
- The Tauri app has its **own** sidecars in `desktop/python/` (a third tree),
  untouched here.
- **Detection runs inline** (foreground `.processing` screen → results), one
  batch at a time, `maxParallel = 1`. There is **no background job queue**.

---

## Shared contracts (honor these exactly across apps)

### C1 — the `--diameter` CLI contract (Swift ↔ Python)
- Flag name is exactly **`--diameter`**, value in **micrometers (µm)**, a float.
- Swift appends `--diameter <value>` **only when the user's expected diameter
  is > 0** ("Custom"). When it is `0` ("Auto"), the flag is **omitted entirely**.
- Python declares `--diameter type=float default=0.0`. When `> 0` it **overrides**
  the size prior; when `<= 0`/absent it keeps the **bins-derived** value. This is
  fully backward-compatible: an old caller that never passes the flag behaves
  byte-identically to before.
- The value is transported via `UserDefaults` key **`cc-expected-diameter`**
  (see note in item 4 about promoting this to a real `DetectionInput` field).

### C2 — size bins are N-bin generic (`BinMath`)
- `Domain/SizeBin.swift` `BinMath.bins(from: [Double])` returns **N+1** `SizeBin`s
  for any-length threshold list; `BinMath.binIndex(for:thresholds:)` buckets a
  cell. **Never hardcode 3 categories** (`small/intermediate/large`). Both the
  CSV export and the on-screen bins already consume `BinMath`.
- Rust already ports this as `bin_labels()` / `bin_index()` in
  `desktop/src-tauri/src/export/csv.rs`.

---

## 1. Large-cell accuracy: decouple the diameter prior from the size bins

**Why.** Cellpose segments better when told the expected cell diameter. The
sidecars were deriving it from the size-classification bins:
`expected_diam_um = (small_threshold + large_threshold) / 2`. So editing the
**display** bins silently **re-segmented** the image — the single biggest source
of "why did my counts change?" and of poor large-cell accuracy. The fix gives the
user an explicit diameter that overrides the bin-derived prior.

**How (Swift).**
- `AppState.expectedDiameterUm: Double` (`0` == Auto), persisted under
  `cc-expected-diameter` with the same `didSet` + `suppressDefaultsWriteback`
  guard as `pxPerUm`/`confidence`; restored in `init`, mirrored in
  `refreshFromDefaults()`.
- Both `CellposeDetectionService` (cyto3) and `CellposeSAMDetectionService`
  (cpsam) append `--diameter <µm>` when the value is `> 0`.
- `ResultsView` gains an **`ExpectedDiameterPanel`** (directly under
  `SizeBinsPanel`): an Auto/Custom segmented control; Custom reveals a µm field
  seeded from the bins' midpoint. Caption explains Auto = bin-derived (old
  behavior), Custom = decoupled (recommended for large/uniform cells), and that
  it applies on the next detection / ⌘R.
- `SettingsView` "Reset all settings" clears `cc-expected-diameter` too.

**How (Python).** In `cellpose_detect.py` and `cellpose4_detect.py`: add the
`--diameter` arg; branch `if args.diameter > 0: expected_diam_um = args.diameter`
else the existing bins formula; the `max(15.0, expected_diam_um * pxPerUm)` px
clamp is unchanged; the log line now names the source (`explicit --diameter` vs
`bins …`). No other use of `expected_diam_px` changed.

**Tauri port.**
- Argv: `desktop/src-tauri/src/detection/sidecar.rs` — push `--diameter` after the
  `--small-threshold`/`--large-threshold` block, gated on a new
  `expected_diameter_um > 0` param.
- State/UI: thread an `expectedDiameterUm` (0 = Auto) through the analysis params
  (`src/pages/home/importFlow.ts`, `src/pages/results/useResultsData.ts`), add a
  control near confidence/size-bins in `src/pages/results/AnalysisSidebar.tsx`,
  default in `SettingsPage.tsx`.
- Python: apply the identical `--diameter` branch to `desktop/python/cellpose_detect.py`.

## 2. Make Cellpose-SAM a first-class option for large/irregular cells

**Why.** cyto3 (Cellpose 3) is the default and what the researcher was using;
Cellpose-SAM (cpsam / Cellpose 4) generalizes better to large/irregular cells and
is already fully wired (`cellpose4_detect.py`, `CellposeSAMDetectionService`,
`CellposeSAMDownloader`), just under-surfaced.

**How.** The `--diameter` override also flows through the SAM service (item 1). A
discoverable hint was added in the diameter panel: *"Large or irregular cells?
Cellpose-SAM (install from the Models tab) usually segments them better."* No
restructuring of the model-selection system.

**Tauri port.** Mirror the hint near the model/analysis controls; the Tauri app
currently ships cyto3-only, so SAM is a larger port (new sidecar + downloader) —
track separately.

## 3. Editor: preserve cell contours through resize & merge

**Why.** Cells can carry a traced/segmented outline (`contourPx`, equivalent
diameter via shoelace area). Resizing overwrote only the diameter and left the
contour frozen (mask and reported size silently desynced); merging discarded both
outlines and collapsed to a bare circle.

**How (`Views/Results/EditableOverlay.swift`).**
- **Resize:** if `contourPx` exists, scale each vertex about the centroid by
  `newDiameterPx/oldDiameterPx` and re-derive the equivalent diameter from the
  scaled polygon (uniform scale ⇒ area×s² ⇒ diameter×s, so contour and diameter
  stay locked; drag-in/out telescopes back to the original). Contour-less cells
  keep the old circle/box path.
- **Merge:** if either cell has a contour, build a **convex hull** (Andrew's
  monotone chain) over the union of both footprints (real contour points, or 16
  sampled perimeter points for a plain circle); merged center = hull bbox center,
  diameter = hull-area-equivalent. Degenerate (<3 pts) → legacy averaged merge.
- Numerical guards throughout; undo/redo unaffected (resize via `onEdit`, merge
  snapshots carry full cells).
- *Known minor limitation:* `hitTest`'s centroid-distance pre-filter
  (`bound = diameterPx`) can make the extreme tip of a very elongated merged hull
  un-clickable (center stays clickable). Fine for normal/adjacent merges.

**Tauri port.** Logic lives in `desktop/src/kernel/overlay/MaskEditEngine.ts`
(`resize` ~L374, `merge` ~L289); contour field is `contourPx?: [number,number][]`
on the cell type in `desktop/src/kernel/types.ts`. Port the three pieces (scale
on resize, convex-hull on merge, shoelace-area diameter) — check for an existing
shoelace helper near the freeform-draw path first.

## 4. Export: dynamic per-bin CSV columns

**Why.** The per-image **summary** CSV hardcoded `n_small/n_intermediate/n_large`
(only correct for exactly 2 thresholds), silently wrong for any other bin count.
(The per-cell CSV was already N-aware.)

**How (`Services/ExportService.swift`).** `writePerImageSummaryCSV` now derives
columns from `BinMath.bins(from: thresholds)` — one count column per bin, named
`n_bin<i>_<sanitizedLabel>` (e.g. `[20,30]` → `n_bin1_lt_20um, n_bin2_20_30um,
n_bin3_gt_30um`; `[15,25,40,60]` → five columns). Counts via
`BinMath.binIndex(...)` clamped to range; header and row build from the same
`bins` array so they can't drift for any N.

**Tauri port.** Same historical bug in `desktop/src-tauri/src/export/csv.rs`
(`SUMMARY_HEADER` hardcodes the 3 literals; `build_summary_csv` compares manually).
Rust already has `bin_labels()`/`bin_index()` — replace the literals with a
`Vec<String>` from `bin_labels(thresholds)` (format `n_bin{i+1}_{sanitized}` to
match Swift column names) and a counts `Vec` indexed by `bin_index`.

## 5. Review-queue badge = queue contents

**Why.** The sidebar "Review queue" badge count and the actual queue could
disagree. `ReviewQueueView.rebuild()` walks `allBatches() → batch.images →
image.detection.cells` filtering `cell.confidence < cutoff && !corrected`, but
`Repositories.uncorrectedCellCount(below:)` computed an **independent**
`FetchDescriptor<DetectionRecord>` over *all stored* detections — two separately
computed sets kept equal only by convention, free to drift.

**How (`Persistence/Repositories.swift`).** Rewrote `uncorrectedCellCount(below:)`
to use the **identical traversal and predicate** as `rebuild()`, so the count is
literally the length of the same set. Signature unchanged (no `AppState` edit
needed); `SidebarReviewExt.swift` still just displays `state.reviewQueueCount`
(doc comment added).

**Tauri port.** Audit for the same anti-pattern: a badge/count computed by one
query and a list/view computed by another over nominally the same data. Prefer one
function whose length backs both.

## 6. Batch navigation finish ("C1") & honest processing status

**Why.** Finish dangling batch/library-nav integration and stop showing a fake
"processing queue."

**How (`Views/Batch/BatchView.swift`).**
- **Row-tap bug fixed:** a batch-table row tap now opens *that row's* image. The
  tap closure passes the row's stable `imageId`; `openImage(_:)` resolves it to
  the index in the `importedAt`-sorted array (the exact ordering
  `AppState.currentImage` indexes into) — never the filename-display sort index.
  Previously a tap just set `state.view = .results`, opening whatever index was
  already current (usually image 0).
- **Honest inline status:** replaced the perpetual "N in queue" spinner with a
  determinate **"N of M analyzed"** readout; row statuses reworded
  (`.queued` "Queued" → "Not analyzed", `.running` fake "Analyzing 64%" →
  "Analyzing…"). Renamed `queueCount` → `pendingCount`.
- Verified already-present from earlier work (no edit needed): `ReviewNavItem`
  spliced in `Sidebar.swift`, the dead "Queue" nav item already removed,
  `BatchListSidebar`/`BatchConditionControl` placed and wired.
- *Left latent (needs `AppState`, out of scope here):* a true per-image
  queued→running→done animation needs AppState to expose the in-flight image id +
  a per-image completion notification. Documented in-code.

**Tauri port.** Open the results viewer by **stable image id → canonical
`importedAt` order**, never the display-sort index (cross-platform footgun). Don't
reproduce a "Queue" tab / "N in queue" badge — detection is inline; the honest
surface is "N of M analyzed" + per-row done/not-analyzed/error.

---

## Verification & open items

**Done:** `swiftc -parse` clean on every changed Swift file; the `--diameter`
contract verified consistent across `AppState` ↔ both detection services ↔ both
Python sidecars; contract is backward-compatible.

**Remaining gate (must run on a machine with full Xcode):**
1. `xcodebuild`/CI `swift-build` full type-check + build of the app.
2. Interactive visual QA: expected-diameter Auto/Custom re-run (⌘R) actually
   changes segmentation; >5 bins add/remove; per-bin CSV columns; contour survives
   resize/merge; review badge == queue length; batch row-tap opens the right image.

**Follow-ups (flagged, not done here):**
- Promote `cc-expected-diameter` from a `UserDefaults` read inside the detection
  services to a real `DetectionInput` field (owned by `Detection/DetectionService.swift`)
  and thread it from AppState's two construction sites — cleaner than the current
  side-channel (which is functional and covers all detection paths).
- Remove/reconcile the stale, non-bundled `Resources/python/` tree.
- `Tokens.binColor` has a 5-stop ramp; bins ≥6 reuse the last color (cosmetic —
  binning is still correct).
- Latent per-image `.running` state in BatchView (needs AppState plumbing).
