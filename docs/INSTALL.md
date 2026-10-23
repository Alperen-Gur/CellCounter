# Install CellCounter

| Platform | Download | Guide |
| --- | --- | --- |
| macOS 15+, Intel and Apple Silicon | [1.1.0](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.1.0) | Steps below |
| Windows 10/11, x64 | [1.3.0](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0) | [Windows guide](WINDOWS.md) |
| Browser | [0.3.2 preview](https://github.com/Alperen-Gur/CellCounter/releases/tag/web-v0.3.2) | [Browser guide](WEB.md) |

For scripts and notebooks, see the [Python SDK](WORKBENCH.md#python-sdk).

## macOS v1.1.0

Requires **macOS 15 or later**. The universal app runs on Intel and Apple Silicon.

### Install and open

1. Download `CellCounter-v1.1.0.zip` and its SHA-256 file from the
   [release page](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.1.0).
2. Check the download in Terminal:
   `shasum -a 256 ~/Downloads/CellCounter-v1.1.0.zip`.
   Compare the result with the supplied hash.
3. Unzip it and move **CellCounting.app** to **Applications**. Quit an older
   copy before replacing it.
4. Open the app.

The app is ad-hoc signed and not notarized. If macOS blocks the official download,
open **System Settings → Privacy & Security → Open Anyway**. On a managed Mac,
your IT team may need to approve installation.

### Start with your images

1. Open **Workbench → AI agent and command-line access → Install or repair**
   to set up the analysis environment.
2. Create a project and import images. Choose the channel and time/Z selection,
   then check calibration.
3. Preview segmentation and adjust the settings. To use a learned model, add its
   checkpoint and Python environment in the model controls.
4. Run analysis, correct masks and review measurements. Save the workflow to use
   it again, or save a processing job to pause and resume later.
5. Export images, tables or an analysis package.

See the [Workbench guide](WORKBENCH.md) for the full workflow.

### Connect an AI agent or use the command line

Open **AI agent and command-line access**, select a project and generate the
connection configuration for your MCP client. Connections start read-only. Add
write access, source/export folders and trusted models or plugins as needed.

The app's `--workbench` command, Python SDK and MCP server use the same operations
as the GUI. See the [CLI examples](WORKBENCH.md#cli-example) and
[MCP setup](WORKBENCH.md#mcp-connection).

### Existing library workflow

1. Open images or a folder from **Home** or **File → Open Images…** (`⌘O`).
2. Open **Set up analysis**, choose a representative image and check calibration
   and analysis settings.
3. Install a segmentation model from **Models** if needed.
4. Preview the result, then start processing.
5. Use **Processing** to pause, resume or retry images. You can review completed
   results while the batch continues.

To move library results into a Workbench project, use the migration preview.
It creates a copy and keeps the original library.

### Find keyboard shortcuts

Open **Help → Keyboard Shortcuts** with `⌘/`, or find them in **Settings**.
Canvas shortcuts work when the image has focus.

## Backup and portable projects

Keep your original images. Export an analysis package to transfer a project,
and back up project folders with the app and background workers closed. Include
any source images, model files or plugin environments stored outside the project.

After changing an analysis, export a new report to include the changes.

## Troubleshooting

| Problem | Try this |
| --- | --- |
| macOS blocks launch | Check the download hash, then use **Privacy & Security → Open Anyway**, or contact your IT team. |
| Analysis runtime is unavailable | Use **Install or repair** in the Workbench access panel, then check readiness. |
| A model will not run | Check its checkpoint, Python interpreter and enabled state. For library models, use **Models** to retry or repair the installation. |
| A download has stalled | Check your connection and retry. Completed downloads are reused. |
| Calibration is missing | Enter the known pixel size or set a scale from a reference. |
| A project changed in another client | Refresh the project before editing again. |
| A source will not open | Try a TIFF/OME-TIFF copy or select a region from an NGFF source. |
| A preview cannot be read | Check the source file. If app resources are damaged, reinstall the current release. |

Report problems on the [issue tracker](https://github.com/Alperen-Gur/CellCounter/issues).
Include the app version, platform, steps and exact error. Remove private image
and sample information before posting.

<a id="optional-local-diagnostics-and-real-workflow-benchmarks"></a>

## Optional local diagnostics

Open **Local diagnostics & performance** in Support (desktop) or Help (browser)
to record timings for your session. Recording starts only when you turn it on.
Review the report, edit it if needed and export it locally before closing the app.
Reports are never uploaded automatically.

## Sharing the application

Send colleagues the release link. Email systems often block app bundles and
installer attachments.
