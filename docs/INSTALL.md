# Install CellCounter

Choose the application for your computer:

| Platform | Current release | Installation guide |
| --- | --- | --- |
| macOS 15 or later, Intel or Apple Silicon | [1.1.0](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.1.0) | Steps below |
| Windows 10/11, x64 | [1.3.0](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0) | [Windows guide](WINDOWS.md) |
| Browser | [0.3.2 preview](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.3.2) | [Browser guide](WEB.md) |

There is no native Linux application package in this release. The standalone
[Python SDK](WORKBENCH.md#python-sdk) provides a separate programmatic interface.

## macOS v1.1.0

The macOS application requires **macOS 15 or later** and is a **universal build**
for Intel and Apple Silicon. Its ZIP contains the application; Python analysis
environments and model weights are installed separately when you choose to use them.

### Install and open

1. Download `CellCounter-v1.1.0.zip` and its SHA-256 file from the
   [official release](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.1.0).
2. Compare the archive's SHA-256 with the supplied value. In Terminal, run
   `shasum -a 256 ~/Downloads/CellCounter-v1.1.0.zip`.
3. Unzip it and move **CellCounting.app** to **Applications**. CellCounter is the
   product name; its bundle on disk is named `CellCounting.app`. Quit an older
   copy before replacing it.
4. Open the installed application.

The application is **ad-hoc signed and not notarized**. It does not have an Apple
Developer ID signature. If macOS blocks a verified official download, dismiss the
message, open **System Settings → Privacy & Security**, then use **Open Anyway**
and confirm **Open** if your security policy permits it. Managed Macs may require
your IT administrator's approval. Do not override a warning for a download with
an uncertain source or a mismatched checksum.

Replacing the application does not reset its saved library. Before upgrading,
stop ongoing analysis and back up important projects and results.

### Start with your images

1. Open **Workbench**. In **AI agent and command-line access**, choose
   **Install or repair** to prepare the dedicated analysis environment. This
   downloads the analysis, MCP, chunked-storage and reporting dependencies.
2. Create or open a local project and import supported images. Check the source
   channel, time/Z selection and spatial calibration before analysis.
3. Preview segmentation and inspect the masks. Classical analysis needs no
   learned checkpoint. A registered learned model needs its compatible local
   interpreter, exact checkpoint and explicit configuration.
4. Run analysis, correct labels and review measurements. Save a workflow to
   repeat supported steps or use a saved job for resumable processing.
5. Export scientific images, tables or an analysis package to a new destination.

The dedicated environment is installed only by an explicit action. Agent commands
do not install software automatically. Model environments and optional OMERO
configuration remain separate. See the [Workbench guide](WORKBENCH.md) for supported
formats, operations and limits.

### Connect an AI agent or use the command line

Open the Workbench's **AI agent and command-line access** panel and check runtime
readiness. Create or select the intended project, choose the permissions it needs,
and generate the connection configuration for your MCP client. Read-only access is
the default. Grant project writes, source/export folders and trusted executable
methods separately.

The installed application supplies the `--workbench` entry point. The CLI, SDK
and MCP server use the same project operations as the GUI, including revision
checks and retained history. Follow the [CLI examples](WORKBENCH.md#cli-example)
or [MCP connection guide](WORKBENCH.md#mcp-connection) for standalone use.

### Existing library workflow

Existing libraries remain available. Their migration controls preview a copy into
a new Workbench project and retain historical evidence; they do not replace the
original library or turn historical contours into exact instance masks.

To continue using the image library:

1. Open images or a folder from **Home** or **File → Open Images…** (`⌘O`).
2. Inspect a representative image in **Set up analysis**. Confirm calibration,
   source settings and analysis parameters before processing the batch.
3. If needed, open **Models** and install the chosen segmentation engine.
   Model families can use separate Python environments and checkpoints.
4. Run a preview, review the result, then start the saved processing job.
5. Use **Processing** to pause, resume or retry failed images. Completed images
   can be reviewed while the remaining images process.

You can import and inspect images before installing a detector. Some scientific
formats require optional readers. Interrupted jobs reopen as paused, and completed
model downloads are reused.

### Find keyboard shortcuts

Open **Help → Keyboard Shortcuts** with `⌘/`, or use the shortcuts section in
**Settings**. Image-editing letter keys apply when the canvas has focus. Text
fields retain normal macOS selection and undo behavior.

## Backup and portable projects

Retain your original acquisitions. Export an analysis package when transferring
a Workbench project, and keep a separate backup of its project folder when the
application and background workers are closed. Also retain externally referenced
sources and any host-local model/plugin runtime configuration needed to rerun it.

Restoration verifies packaged artifacts and does not automatically enable
executable models or plugins. Previously exported reports are historical
snapshots; export new files after changing an analysis.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| macOS blocks launch | Verify the official download and checksum, then follow the first-launch guidance above or contact your administrator. |
| Runtime is unavailable | Use the Workbench access panel's installation/repair and readiness controls. Keep the specific dependency error if repair fails. |
| A model will not run | Confirm its exact checkpoint, compatible interpreter and enabled state. For the existing library, retain the Models installation log and use its retry/repair action. |
| Initial analysis is waiting on a download | Keep the application open while required weights download. Restore connectivity and retry after a failed download; cached completed downloads are reused. |
| No calibration metadata is found | Enter a known scale when physical measurements are required. Ordinary photographs and screenshots often have no usable microscopy calibration. |
| A project changed in another client | Refresh, inspect the current result, then submit the intended edit against the current revision. |
| An imported source exceeds a limit | Use a supported region or prepared TIFF/NGFF input; consult the [feature limits](FEATURES.md#current-operating-limits). |
| A preview or review record cannot be read | Retain the specific error. Reinstall the current release if application resources are damaged; avoid resetting scientific data as a first troubleshooting step. |

For a reproducible problem, use the repository's
[issue tracker](https://github.com/Alperen-Gur/CellCounter/issues). Include the
application version, platform, operation and exact error. Remove private image,
sample and file-path information before sharing a report.

<a id="optional-local-diagnostics-and-real-workflow-benchmarks"></a>

## Optional local diagnostics

**Local diagnostics & performance** in Support (desktop) or Help (browser) can
record timing summaries for workflows you run. Recording is off by default and
must be started each session. It stores bounded in-memory counts, durations,
failures where known, incomplete work and latency summaries, rather than image
content, filenames or a chronological activity log. Exiting the app loses unsaved
recording results.

You can prepare and edit a diagnostic preview, inspect it, and export that text
locally. There is no automatic upload or attachment. Inspect anything you add:
workload counts, timings and user-authored text can still disclose information.
A saved report may also be synchronized by other software at its chosen location.
These timings describe observed workflows, not segmentation accuracy or a CPU/GPU
profiler.

## Sharing the application

Share the official release link with colleagues. Institutional email systems
often block attached application bundles or installer archives.
