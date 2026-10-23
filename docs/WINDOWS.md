# CellCounter for Windows 1.3.0

CellCounter for Windows provides local microscopy analysis and a project
Workbench shared with the macOS application. The GUI, installed CLI, Python SDK
and MCP server use the same project operations, revision checks and history.

Download the current installers from the
[Windows 1.3.0 release](https://github.com/Alperen-Gur/CellCounter/releases/tag/windows-v1.3.0).
See [current features](FEATURES.md), the [platform comparison](PLATFORM-PARITY.md)
and the [Workbench guide](WORKBENCH.md) for supported functions and bounds.

## System requirements

- **64-bit Windows 10 or Windows 11.** The installers target x64; Windows on ARM
  is not a supported native target.
- **Microsoft Edge WebView2 Runtime.** The installer includes its bootstrapper;
  downloading the runtime may require internet access if it is absent.
- **Internet access for selected runtime/model downloads.** Analysis runs locally
  after the required components are installed.
- **Free disk space for source images, projects, exports and model environments.**
  Python environments and weights can occupy several gigabytes in addition to
  your scientific data.
- The bundled Windows model-installation paths use **CPU inference**. Registered
  models require a compatible explicitly selected environment; installed package
  names alone do not establish CUDA support.

The application includes the tools needed to provision its dedicated Workbench
environment and supported model environments. Normal installation does not require
a separate Node.js or Rust installation. Advanced registered models, plugins and
OMERO access require their own explicit local setup.

## Choose an installer

The release provides two installers and a `SHA256SUMS.txt` file:

| Installer | Use |
| --- | --- |
| `CellCounter_1.3.0_x64-setup.exe` | NSIS installer for an individual workstation; normally installs for the current user. |
| `CellCounter_1.3.0_x64_en-US.msi` | MSI package for Windows Installer tooling or managed institutional deployment. |

Both packages contain the same application and bundled resources. Use the same
installer format for later upgrades when possible; organization policy may require
administrator approval.

The current installers are **unsigned**. SmartScreen may show an unknown-publisher
warning. Verify the download source and SHA-256 before deciding whether to continue.
In PowerShell:

```powershell
Get-FileHash .\CellCounter_1.3.0_x64-setup.exe -Algorithm SHA256
```

Compare the hash with the matching filename in `SHA256SUMS.txt`. Do not override
a warning for an uncertain source or a mismatched checksum.

## Install

1. Download the chosen installer and `SHA256SUMS.txt` from the official release,
   then verify the hash.
2. Close CellCounter if an older copy is running.
3. Run the installer, following your organization's software policy. For a
   verified unsigned executable, Windows may offer **More info → Run anyway**.
4. Open **CellCounter** from the Start menu.
5. Open **Workbench → AI agent access** and choose **Install or repair runtime**.
   Wait for installation to finish, then use **Check runtime readiness**.
6. Create a project, import supported images, confirm calibration and source
   settings, then preview classical segmentation.

Classical Workbench analysis needs no learned checkpoint. Install or configure a
model only when you intend to use it. The Workbench runtime, existing library model
environments and optional OMERO runtime are separate.

For an agent connection, select the project and permissions in **AI agent access**,
then choose **Generate connection configuration**. Read-only is the default;
project writes, external folders and executable methods have separate grants.
See [MCP setup](WORKBENCH.md#mcp-connection).

## Upgrade

1. Stop analysis/background workers, close CellCounter and make the backups
   described below.
2. Install the newer release using the same installer format as before.
3. Reopen the application and check runtime/model readiness before new analysis.

Application data is stored separately from installed program files. Upgrading does
not intentionally replace the library or reset its data. Installers reject version
downgrades; keep a backup when you need a rollback path.

## Uninstall

Use **Windows Settings → Apps → Installed apps → CellCounter → Uninstall**.
Managed MSI deployments can use the organization's Windows Installer tooling.

Uninstalling the program does **not remove the app-data directory**. Back up
scientific data before deliberately removing any remaining data or environments.

## Install local models

### Registered Workbench models

Use the Workbench's registered-model controls to select the supported backend,
exact checkpoint/configuration files and compatible local Python interpreter.
Run its compatibility probe, inspect the environment information and explicitly
enable the model. Current adapters include Cellpose 3/4, StarDist 2D, Omnipose and
micro-SAM; they perform selected-plane 2D inference.

The Workbench does not silently install model dependencies or download substitute
weights. Environment capture records observed versions; it is not an installable
environment lockfile. See [plugins and local learned models](WORKBENCH.md#plugins-and-local-learned-models).

### Existing library model installation

Open **Models**, choose a supported card and use **Install**. Keep the application
open while its installation log is running. Packages and weights are downloaded
from the relevant upstream providers. There is **no silent model substitution**.

The original model entries remain:

| App model ID | Checkpoint identity | Local environment |
| --- | --- | --- |
| `cpsam_v2` | Historical app alias for the `cpsam` checkpoint, not a claim of a newer checkpoint | `py\.venv4` |
| `cp-cyto3` | Cellpose 3 `cyto3` | `py\.venv` |
| `sd-fluo` | StarDist `2D_versatile_fluo` | `py\.venvsd` |

Other catalogue entries require their own compatible environment and exact model
files. A visible card alone does not mean the model is ready.

## Microscopy formats and advanced workflows

### Inspect, preview and process

Create/open a Workbench project, import images, confirm source coordinates and
calibration, then preview before saving analysis. Correct exact masks, review
measurements and export scientific files or an analysis package.

Saved workflows support branching graphs, parameter sweeps and review gates.
Background jobs retain checkpoints for resume. The Jobs controls report when a
stop request will take effect; do not assume it discards a completed result.

Existing library processing remains available, with saved setup, representative
previews, linked result tables and mask alternatives. Its interrupted jobs reopen
as paused. Migration to a Workbench project previews a copy and retains historical
evidence without deleting the original library.

### Formats, assays and training

The shared Workbench supports documented TIFF/OME-TIFF, common raster and
TIFF/NGFF-region routes. Optional readers and the existing library importer have
different coverage; support in one route does not establish support in all others.
VSI is not a built-in shared Workbench format. Unsupported or oversized sources
need a compatible prepared input.

Workbench assays declare required channels, labels and dimensions. Biological
replicate statistics require explicit specimen assignments. Training/adaptation
is limited to supported methods and requires suitable masks and specimen-grouped
data; configuring a model does not automatically train it. See the
[Workbench guide](WORKBENCH.md) for exact controls and limits.

## Local data and privacy

During built-in local detection, images do not upload to an inference service.
Model/runtime installation makes network downloads. Explicit OMERO access connects
to its configured server; trusted executable plugins or separately configured
methods have their own behavior.

The existing library and application-managed environments are stored under:

- `%APPDATA%\com.alperengur.cellcounter\CellCounter`
  - `store.sqlite`: library records, saved jobs, measurements and corrections
  - `Images`, `Originals` and `Analysis`: imported sources and prepared data
  - `Thumbnails`: previews
  - `Models`: downloaded and adapted weights
  - `Exports`: generated files
- `%APPDATA%\com.alperengur.cellcounter\py`
  - `.venvwb`: dedicated Workbench environment
  - model-specific environments such as `.venv`, `.venv4` and `.venvsd`
  - isolated reader environment and bundled analysis scripts

**Workbench projects live in the folders you choose**, separately from this
application-data directory. Externally selected interpreters, checkpoints and
OMERO configuration can also live elsewhere.

Optional diagnostics are prepared, inspected and exported locally. There is no
automatic upload. See [local diagnostics](INSTALL.md#optional-local-diagnostics).

## Backup and restore

1. Stop background analysis/model installation and close CellCounter.
2. Copy the entire `%APPDATA%\com.alperengur.cellcounter` directory to protected
   storage. Keep the `CellCounter` and `py` folders together.
3. Back up each Workbench project folder separately. Retain external source data,
   model files and host-local runtime configuration needed to rerun the analysis.
4. For a portable scientific copy, export an analysis package before closing.
   Package restore verifies retained artifacts; executable methods require
   explicit reconfiguration/enabling on the destination computer.

To restore the existing library, install the same or a compatible newer version,
close the application, restore its complete identifier-scoped directory, then
reopen. Copying only `store.sqlite` leaves its source-image references incomplete.

## Reset

**Settings → Data & reset → Reset all data** removes the existing library's
batches, imported image copies, thumbnails, detections, ROIs, ground truth,
corrections, saved jobs and mask versions after confirmation. It preserves
conditions, calibration/bin presets, settings, downloaded models and local Python
environments. Reset is unavailable during a saved processing job and cannot be undone.

This library reset is not a backup or a way to reset separately selected Workbench
project folders. Manage those projects deliberately. To remove all remaining
application-managed data, first back it up, close/uninstall the application, then
remove the identifier-scoped app-data directory. That manual deletion also removes
its downloaded models and environments.

## Troubleshooting

### The installer is blocked by SmartScreen

Check that the download is from the official release and matches its SHA-256.
The current unsigned installers can show an unknown publisher even when intact.
Follow institutional policy or ask your administrator if installation is blocked.

### The window is blank or does not open

Repair or install Microsoft Edge WebView2 Runtime, then reopen CellCounter.
A proxy or deployment policy may prevent its bootstrap download; an administrator
can install WebView2 separately.

### The Workbench runtime is unavailable

Use **Workbench → AI agent access → Install or repair runtime**, then check
readiness. Retain the specific dependency error, and check internet access, disk
space and write access to the application-data directory. Installing a library
model does not replace this dedicated environment.

### A model install fails

Keep the model name and final installation error. Check internet access, free
space and write access to the `py` directory. Security software may restrict the
bundled provisioning tool. Retry or repair the chosen model; replacing it with
another checkpoint changes the analysis method.

### Imported images show broken thumbnails or previews

Reopen the current release and check whether the retained source is available.
Do not reset or reimport the library as a first step. If the app reports a missing
or unreadable source, keep the exact error and verify your backup/restore paths.

### First analysis says “Sidecar scripts are not staged”

Reinstall the current application from the official release, reopen it, and retry.
Its bundled scripts are staged/repaired before use. Check disk space and write
access to the `py` directory if preparation still fails. A model reinstall alone
does not repair a damaged application download.

### Detection is slow

The bundled model installers use CPU inference, and first inference can include
model startup or a weight download. Reuse the installed environment and saved
processing workflow. For a registered method, inspect its actual backend rather
than assuming a GPU package is active.

### Imported images or models appear missing after restore

Verify the complete `CellCounter` and `py` directories under the exact
identifier-scoped path. Also reopen the intended Workbench project folder:
restoring application data alone does not restore projects saved elsewhere.

## Validation boundary

Supported limits are documented in the [feature reference](FEATURES.md) and
[Workbench guide](WORKBENCH.md). Check segmentation and calibration on representative
images before relying on a new assay. Institutional deployment should confirm
installation, upgrade, backup/restore and model availability on its physical Windows
workstations, including local security and WebView2 policies.

CellCounter does not provide a universal accuracy guarantee or automatic biological
interpretation. Source formats, model environments and workstation configuration
can affect available operations.

See the [1.3.0 release notes](releases/windows-v1.3.0.md) for release-specific changes.
