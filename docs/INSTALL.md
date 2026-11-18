# Install CellCounter

| Platform | Download | Guide |
| --- | --- | --- |
| macOS 15 or later on Apple silicon | [1.3.0](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.3.0) | This page |
| Windows 10/11, x64 | [1.3.0](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0) | [Windows guide](WINDOWS.md) |
| Browser | [0.3.2 preview](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.3.2) | [Browser guide](WEB.md) |

For scripts and notebooks, see the [Python SDK](WORKBENCH.md#python-sdk).

## macOS

CellCounter for macOS runs on Macs with Apple silicon and **macOS 15 or later**.

### Install

1. Download `CellCounter-v1.3.0.zip` and its `.sha256` file from the
   [release page](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.3.0).
2. Check the download in Terminal and compare the result with the supplied hash:

   ```sh
   shasum -a 256 ~/Downloads/CellCounter-v1.3.0.zip
   ```

3. Unzip it and move **CellCounting.app** to **Applications**.
4. Open the app.

The app is ad-hoc signed and not notarized. If macOS blocks the first launch, open
**System Settings → Privacy & Security** and choose **Open Anyway**. On a managed Mac,
your IT team may need to approve the app.

### Upgrade from an earlier version

Quit CellCounter, then replace **CellCounting.app** in Applications with the new copy.
Your libraries, projects, models and Python environments are kept.

When a new version first opens a library that uses an older storage format, it upgrades
the library and first saves a verified copy of its database in the library's `Backups/`
folder (for the Default Library, `~/Library/Application Support/CellCounter/Backups/`).
A banner shows where the copy is. If the copy cannot be made, the library is not opened
and nothing in it changes.

After the upgrade, do not open that library with an older version of CellCounter. To go
back to an older version, quit CellCounter and put the saved copy in place of the
library's `store.sqlite`. Changes made since the upgrade are lost.

#### Cellpose-SAM 4.2.1.1

CellCounter installs and tests Cellpose-SAM with **Cellpose 4.2.1.1** (PyTorch 2.12,
torchvision 0.27, OpenCV 4.13, NumPy 2), in a Python 3.12 or later environment. If your
Cellpose-SAM environment has an older Cellpose, **Models** shows
**Update Cellpose-SAM to 4.2.1.1**. Nothing changes until you click it: analyses keep
using the installed version. Results can differ slightly from runs made with the older
version. Every result records the Cellpose, PyTorch and NumPy versions, the device and
the weights file it used, in its CSV header, `provenance.json` and report. Before the
update, the current package list is saved next to the environment
(`venv4-packages-before-cellpose-<version>.txt`). If the update stops before it changes
anything (no network connection, no suitable Python), the installed version stays in use.
An environment made with a Python older than 3.12 is moved aside
(`venv4.before-python-upgrade-…`) and a new one is created.

**Cellpose-SAM v2** (`cpsam_v2`) is the revised model. It needs Cellpose 4.2.1.1 and its
own one-time download of about 1.2 GB. **Cellpose-DINO** models are listed but cannot be
chosen: they need the `dinov3` package, which CellCounter does not install.

### Analyze images in the Workbench

1. Open **Workbench**, choose **AI agent and command-line access…** and click
   **Install or repair** to set up the analysis runtime. **Check readiness** confirms it.
2. Create a project with **File → New Microscopy Project…** (`⌘N`) and import images.
   Choose the channel and Z projection, then check calibration.
3. Preview segmentation and adjust the settings. To use a learned model, register its
   checkpoint and Python environment under **Models…**.
4. Run the analysis, correct masks and review measurements. Save a workflow to reuse
   your settings, or run a job in the background and resume it later.
5. Export images, tables or an analysis package.

The [Workbench guide](WORKBENCH.md) covers the full workflow.

### Connect an AI agent or use the command line

In **AI agent and command-line access**, open a project and click
**Copy MCP configuration**, then paste it into your MCP client. Connections start
read-only. Turn on **Allow project changes and exports**, add folders under
**Additional import and export paths**, or allow trusted plugins and models as needed.

The app's `--workbench` command, the Python SDK and the MCP server use the same
operations as the app. See the [CLI examples](WORKBENCH.md#cli-example) and
[MCP setup](WORKBENCH.md#mcp-connection).

### Analyze images in the existing library

The existing library organizes images into batches, with review, comparison and
fine-tuning tools. Open it from **Existing library** in the sidebar.

1. In **Library overview**, drop images or a folder, or click **Choose images…** or
   **Choose folder…**.
2. In **Set up analysis**, check the pixel scales found (see below), choose a
   representative image and the analysis settings, then click **Preview this image**.
3. If the model is missing, click **Open Models** to install it.
4. Click **Process batch**. Review finished images while the rest of the batch runs.
5. Use **Processing jobs** to pause, resume or retry images.

#### Pixel scale (px/µm)

Every size in µm depends on the pixel scale, and so does segmentation: the model is told
how large a cell is in pixels. **Each image has its own scale**, so one folder can mix
objectives.

- **From the file.** If an image's file records its scale (TIFF or JPEG resolution,
  OME-XML, ImageJ, or a microscope format), that scale is used for that image.
- **For images without one**, set a scale in **Set up analysis** with **Set scale…**:
  draw a line along the image's scale bar and enter its length, or type px/µm. You can
  save it as a preset named after your microscope and objective (for example
  “Nikon Ts2 · 10×”). Your default for images without a scale is in
  **Settings → Pixel scale**. CellCounter has no built-in scale or presets.
- **Process batch** stays off while any image has no scale. Setup lists the scales it
  found, for example “8 images · 4.1666 px/µm (from file) · 8 images · 8.3333 px/µm
  (from file)”, and warns when file names such as `10x` and `20x` don't match the scales.
- A typed value, a scale-bar measurement or a preset only applies to images without a
  scale. To replace a file's scale, tick **Override the file's scale**. CellCounter shows
  both values and what changes (“Your value is 1.6× smaller than the file's, so sizes
  would be 1.6× larger”) and records it as `manual override (file: X px/µm)`.
- **Changing the scale of analysed images** (Results → **Calibrate…**): if the model uses
  the scale to find cells (Cellpose, Cellpose-SAM, or any model with touching-cell
  splitting), choose **Re-run segmentation** (recommended) or **Only rescale sizes**.
  Rescaled results are marked “segmented at X px/µm, measured at Y px/µm” on screen and
  in exports.
- The strip above each image shows its scale and where it came from, for example
  “4.1666 px/µm · from file”. Exports record each image's px/µm, its source and, when it
  differs, the scale it was segmented at (`px_per_um`, `px_per_um_source`,
  `segmented_px_per_um` in the summary CSV; `pxPerUm`, `pxPerUm_source`,
  `segmented_pxPerUm` in per-cell CSV headers and `provenance.json`).
- **Batches analysed with an older version** keep their numbers. Their images show the
  batch's scale. If an image's file says otherwise, the image shows “Measured at X
  px/µm; the file says Y px/µm” with **Re-run** (at the file's scale) or **Keep X**
  (records X as your override). Nothing changes automatically.

#### Model resource use

**Settings → General → Performance** sets how much of your Mac the models may use. You
can also change it while an analysis runs: from the **Resource use** menu next to
**Pause** and **Cancel**, from **CellCounting → Model Resource Use** in the menu bar, or in
**Set up analysis**.

| Choice | CPU | GPU memory | Priority |
|---|---|---|---|
| **Light** | 2 cores | capped at about 35% of RAM (at least 4 GB) | background: your Mac stays fully usable, but analysis can be much slower |
| **Balanced** (default) | about half the performance cores | cached memory is freed above about 50% of RAM; a run is never stopped for memory | below your apps |
| **Maximum** | all cores | no limit | normal |
| **Custom** | 1 to all cores | capped at the amount you choose | below your apps |

Priority, CPU cores and a higher memory cap apply to the running model at once, without
reloading it. A lower memory cap starts after the current image, so a running image is
not stopped. If a capped run needs more memory, it stops with a message naming the
limit; raise it or choose **Maximum** and run the image again. The setting covers
analyses, Workbench model runs and training. macOS cannot limit a process's total
memory, so the memory setting caps GPU memory for PyTorch models (Cellpose,
Cellpose-SAM, Omnipose, SAM) and sets how many models stay loaded between images.

You can keep several libraries, archive finished batches and restore them later. See
[Libraries and batch archives](LIBRARIES.md).

To bring library results into a Workbench project, choose
**Copy library data into a project…** from the **Existing library** menu. It copies the
data and leaves the library unchanged.

### Keyboard shortcuts

Open **Help → Keyboard Shortcuts** (`⌘/`) or **Settings → Shortcuts**. Canvas shortcuts
work when the image has focus.

## Back up your data

Keep your original images. Quit CellCounter and stop background work before copying:

- **Libraries:** copy the whole library folder. See
  [Back up a library](LIBRARIES.md#back-up-a-library).
- **Workbench projects:** copy each project folder, or export an analysis package.
- **External files:** include source images, model files and plugin environments stored
  outside the project.

After changing an analysis, export a new report to include the changes.

## Troubleshooting

| Problem | Try this |
| --- | --- |
| macOS blocks the first launch | Check the download hash, then use **Privacy & Security → Open Anyway**, or contact your IT team. |
| The analysis runtime is unavailable | Use **Install or repair** in **AI agent and command-line access**, then **Check readiness**. |
| A model will not run | Check its checkpoint, Python interpreter and enabled state. For library models, retry or repair the installation in **Models and installation**. |
| A download stalls | Check your connection and retry. Completed downloads are reused. |
| Calibration is missing | Enter the known pixel size or set the scale from a reference. In the existing library, use **Set scale…** in **Set up analysis** for the images listed as having no scale. |
| Sizes look 2× too large or small | Check each image's scale in the strip above it. A mixed 10×/20× folder needs each image at its own scale; don't override the files' scales with one value. |
| A project changed in another client | Click **Refresh project** before editing again. |
| A source will not open | Try a TIFF/OME-TIFF copy, or select a region from an NGFF source. |
| A preview cannot be read | Check the source file. If app resources are damaged, reinstall the current release. |
| **Library not available** at launch | Connect the drive that holds the library, then choose **File → Open Recent Library**. |
| Library switching has to wait | Finish or pause imports, analyses and training, and save Workbench changes. |

Report problems on the [issue tracker](https://github.com/Alperen-Gur/CellCounter/issues).
Include the app version, platform, steps and the exact error. Remove private image and
sample information before posting.

<a id="optional-local-diagnostics-and-real-workflow-benchmarks"></a>

## Optional local diagnostics

Open **Local diagnostics & performance** from **Support** (desktop) or **Help** (browser)
to record timings for a session. Recording starts only when you turn it on. Review the
report, edit it if needed and export it before closing the app. Reports are never
uploaded.

On macOS, the report can include the size of your library as plain numbers: batches,
images, cells and storage used, with your macOS version, Mac model, memory and processor
cores. It contains no names, paths or IDs.

## Share the application

Send colleagues the release link. Email systems often block app bundles and installer
attachments.
