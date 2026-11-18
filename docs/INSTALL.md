# Install CellCounter

| Platform | Download | Guide |
| --- | --- | --- |
| macOS 15 or later on Apple silicon | [1.2.0](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.2.0) | This page |
| Windows 10/11, x64 | [1.3.0](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0) | [Windows guide](WINDOWS.md) |
| Browser | [0.3.2 preview](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.3.2) | [Browser guide](WEB.md) |

For scripts and notebooks, see the [Python SDK](WORKBENCH.md#python-sdk).

## macOS

CellCounter for macOS runs on Macs with Apple silicon and **macOS 15 or later**.

### Install

1. Download `CellCounter-v1.2.0.zip` and its `.sha256` file from the
   [release page](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.2.0).
2. Check the download in Terminal and compare the result with the supplied hash:

   ```sh
   shasum -a 256 ~/Downloads/CellCounter-v1.2.0.zip
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
2. In **Set up analysis**, choose a representative image, check the pixel calibration
   and analysis settings, then click **Preview this image**.
3. If the model is missing, click **Open Models** to install it.
4. Click **Process batch**. Review finished images while the rest of the batch runs.
5. Use **Processing jobs** to pause, resume or retry images.

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
| Calibration is missing | Enter the known pixel size or set the scale from a reference. |
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
