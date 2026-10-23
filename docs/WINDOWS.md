# CellCounter for Windows 1.3.0

CellCounter brings image analysis, project workflows and AI-agent access to
Windows. Import images, segment and correct cells, measure signals and export
results. The GUI, CLI, Python SDK and MCP server share the same project operations.

[Download Windows 1.3.0](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0)
· [Features](FEATURES.md) · [Workbench guide](WORKBENCH.md)

## System requirements

- **Windows 10 or 11, x64**
- **Microsoft Edge WebView2 Runtime** — the installer includes its bootstrapper
- Internet access to download runtimes and model weights
- Disk space for images, projects, exports and model environments

The app sets up its analysis environments for you. You do not need to install
Node.js or Rust. The bundled model installers use CPU inference; for a custom
model setup, select the Python environment with the backend you want to use.

## Choose an installer

The [release page](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0)
has two installers and `SHA256SUMS.txt`:

| Installer | Use |
| --- | --- |
| `CellCounter_1.3.0_x64-setup.exe` | Standard installation for an individual workstation |
| `CellCounter_1.3.0_x64_en-US.msi` | Managed deployment with Windows Installer |

Both install the same app. Use the same format for later upgrades.

The installers are unsigned, so SmartScreen may show an unknown-publisher warning.
Check the download hash in PowerShell:

```powershell
Get-FileHash .\CellCounter_1.3.0_x64-setup.exe -Algorithm SHA256
```

Compare it with the matching entry in `SHA256SUMS.txt`.

## Install

1. Download an installer and `SHA256SUMS.txt`, then check the hash.
2. Close any running copy of CellCounter.
3. Run the installer. For the verified download, SmartScreen may offer
   **More info → Run anyway**. On a managed computer, ask your IT team if needed.
4. Open **CellCounter** from the Start menu.
5. Open **Workbench → AI agent access → Install or repair runtime**.
   When setup finishes, choose **Check runtime readiness**.
6. Create a project, import images, check calibration and preview segmentation.

To connect an agent, select a project in **AI agent access** and choose
**Generate connection configuration**. Connections start read-only. Add write
access, folders and trusted executable methods as needed. See
[MCP setup](WORKBENCH.md#mcp-connection).

## Upgrade

1. Stop analysis, close CellCounter and back up your data.
2. Install the new release using the same installer format.
3. Reopen CellCounter and check runtime and model readiness.

Your library is stored separately from the program files. Keep a backup if you
need to return to an older release.

## Uninstall

Use **Windows Settings → Apps → Installed apps → CellCounter → Uninstall**.
Your application data stays on disk. Back it up before removing it manually.

## Install local models

### Registered Workbench models

In the model controls, choose a backend, checkpoint and Python interpreter.
Run the compatibility check, then enable the model. Adapters include Cellpose 3/4,
StarDist 2D, Omnipose and micro-SAM.

See [plugins and local models](WORKBENCH.md#plugins-and-local-learned-models).

### Existing library model installation

Open **Models**, choose a model and click **Install**. Keep the app open while
packages and weights download. Model families use separate environments:

| Model ID | Checkpoint | Environment |
| --- | --- | --- |
| `cpsam_v2` | Cellpose `cpsam` | `py\.venv4` |
| `cp-cyto3` | Cellpose 3 `cyto3` | `py\.venv` |
| `sd-fluo` | StarDist `2D_versatile_fluo` | `py\.venvsd` |

Check the model's readiness before running analysis.

## Microscopy formats and advanced workflows

### Inspect, preview and process

Create a project, import images and select the source channel, time and Z plane.
Check calibration, preview segmentation and adjust the settings. Then run the
analysis, correct masks, review measurements and export the results.

Save branching workflows, parameter sweeps and review gates for repeatable
analysis. Background jobs can pause and resume from saved checkpoints.

The image library also supports saved settings, previews, linked tables and mask
alternatives. Use the migration preview to copy library results into a Workbench
project while keeping the original library.

### Formats, assays and training

Import TIFF/OME-TIFF and common raster images, or select TIFF/NGFF regions. Use
reader plugins for other formats.

Choose an assay and supply its channels, labels and image sequence. For replicate
statistics, assign images to biological specimens. Model adaptation uses annotated
masks and specimen groups. See the [Workbench guide](WORKBENCH.md) for the steps.

## Local data and privacy

Image analysis runs locally. Setup downloads model weights and packages; OMERO
imports connect to your chosen server. Enable executable plugins only if you
trust their source.

The app stores its library and environments under:

- `%APPDATA%\com.alperengur.cellcounter\CellCounter`
  - `store.sqlite`: library records, jobs, measurements and corrections
  - `Images`, `Originals`, `Analysis`: image data
  - `Thumbnails`: previews
  - `Models`: downloaded and adapted weights
  - `Exports`: exported files
- `%APPDATA%\com.alperengur.cellcounter\py`
  - `.venvwb`: Workbench environment
  - `.venv`, `.venv4`, `.venvsd`: model environments
  - Reader environment and analysis scripts

Workbench projects live in the folders you choose. Source data, model files and
custom Python environments may be stored elsewhere.

Optional diagnostic reports are reviewed and saved locally. See
[local diagnostics](INSTALL.md#optional-local-diagnostics).

## Backup and restore

1. Stop background work and close CellCounter.
2. Copy `%APPDATA%\com.alperengur.cellcounter` to backup storage. Keep its
   `CellCounter` and `py` folders together.
3. Back up Workbench project folders and any external images, models or custom
   environments.
4. To transfer a project, export an analysis package.

To restore the library, install CellCounter, close it, restore the complete
app-data directory and reopen. Include the image folders as well as
`store.sqlite`. Reopen Workbench projects from their own folders.

## Reset

**Settings → Data & reset → Reset all data** deletes the image library's batches,
imported image copies, thumbnails, detections, ROIs, ground truth, corrections,
saved jobs and mask versions. This cannot be undone.

It keeps conditions, calibration/bin presets, settings, models and Python
environments. Workbench project folders are managed separately.

## Troubleshooting

### The installer is blocked by SmartScreen

Check the download source and SHA-256. On a managed workstation, ask your IT team
to approve the installer.

### The window is blank or does not open

Repair or install Microsoft Edge WebView2 Runtime, then reopen CellCounter.

### The Workbench runtime is unavailable

Use **Workbench → AI agent access → Install or repair runtime**, then check
readiness. If setup fails, check the error, internet connection, free disk space
and write access to the app-data directory.

### A model install fails

Check the installation log, internet connection, disk space and write access to
`py`, then retry or repair the model.

### Imported images show broken thumbnails or previews

Check that the original source files are still available. If you restored a
backup, check that it includes the image folders.

### First analysis says “Sidecar scripts are not staged”

Reinstall the current app from the release page and retry. Check disk space and
write access to `py` if preparation still fails.

### Detection is slow

First use can include model startup and a weight download. The bundled model
installers use CPU inference. For a custom GPU setup, check the model's Python
environment and backend.

### Imported images or models appear missing after restore

Restore both `CellCounter` and `py` under the app-data path above. Open Workbench
projects from the folders where you saved them.

See the [1.3.0 release notes](releases/windows-v1.3.0.md).
