# CellCounter for Windows 1.0.8

CellCounter for Windows is the React interface packaged as a native Tauri 2
application. The Windows build is local-first: imported microscopy images,
measurements, corrections, and inference stay on the PC. The live **Support →
Platform parity** screen is the source of truth for features that are ready,
Windows-adapted, or not yet available.

## System requirements

- 64-bit Windows 10 or Windows 11. The 1.0.8 workflow and bundled `uv` helper
  target `x86_64-pc-windows-msvc`; Windows on ARM is not an initial release
  target.
- Microsoft Edge WebView2 Runtime. The installer embeds Microsoft's small
  WebView2 bootstrapper and can install the runtime silently, which may require
  an internet connection if WebView2 is absent.
- Internet access for the first installation of each detection model. Image
  analysis is local after its environment and weights are cached.
- Enough free disk space for the application, copied source images, thumbnails,
  exports, and three separate Python/model environments. These can use several
  gigabytes; keep additional working space available during installation.
- The Windows v1.0.8 model runtimes are intentionally CPU-only. A GPU driver is
  not required, and the app does not present an acceleration control it cannot
  honor. A separately validated CUDA runtime may be added in a later release.

End users do not need to install Node.js, Rust, Python, or `uv`. Those are build
requirements only; the application bundles `uv` and provisions its own Python
environments.

## Choose an installer

Every validated Windows build produces both formats and a `SHA256SUMS.txt` file:

- **NSIS `.exe`** — the default choice for an individual workstation. It
  installs for the current Windows user and does not require administrator
  rights under normal policy.
- **WiX `.msi`** — intended for Windows Installer tooling and managed lab or IT
  deployment. Organization policy may require elevation.

Use the same format for later upgrades when possible. Both packages contain the
same CellCounter executable, bundled Python scripts, native icon, and pinned
`uv` helper.

CI artifacts are currently unsigned. Windows SmartScreen may therefore show an
unknown-publisher warning. Only continue when the file came from the official
CellCounter release or GitHub Actions run and its SHA-256 matches
`SHA256SUMS.txt`. In PowerShell:

```powershell
Get-FileHash .\CellCounter_1.0.8_x64-setup.exe -Algorithm SHA256
```

Compare the printed hash with the matching `nsis/...` or `msi/...` entry in the
manifest. Do not bypass SmartScreen for an unverified copy.

## Install

1. Download the `.exe` or `.msi` plus `SHA256SUMS.txt` and verify the hash.
2. Close any running CellCounter window.
3. Run the installer. With an unsigned `.exe`, Windows may require **More info →
   Run anyway** after verification. An `.msi` may be installed through your
   organization's normal software-management tool.
4. Launch **CellCounter** from the Start menu.
5. Open **Models** and install at least one of the three supported models before
   starting detection.

The installer can bootstrap WebView2, but model packages and weights are
downloaded only when you choose **Install** on a model card.

## Upgrade

1. Close CellCounter and make a backup of the app-data directory described
   below.
2. Install the newer package using the same installer format as before.
3. Launch the app and confirm that the expected model cards report **Installed**.

The WiX package uses the fixed upgrade code
`9d098d8e-800d-416c-a340-9b6754ea88d0`, so future MSI releases retain one Windows
product lineage. Installers reject version downgrades. Application data lives
outside the installation directory and is not intentionally replaced during an
upgrade, but a backup remains the safest rollback path.

## Uninstall

Open **Windows Settings → Apps → Installed apps**, find **CellCounter**, and
choose **Uninstall**. Managed MSI installations can also be removed with the
organization's normal Windows Installer tooling.

The package has no custom data-removal hook, so uninstalling the program does
not remove the app-data directory. This protects microscopy work during a
reinstall. To remove the data too, first use the reset guidance below, then
delete the remaining model/environment folders only after making any required
backup.

## Install the three models

The runnable 1.0.8 catalog contains exactly three explicit model IDs:

| App model ID | Pipeline | Local environment |
| --- | --- | --- |
| `cpsam_v2` | Cellpose-SAM v2 using the exact `cpsam` checkpoint | `py\.venv4` |
| `cp-cyto3` | Cellpose 3 using the exact `cyto3` checkpoint | `py\.venv` |
| `sd-fluo` | StarDist using the exact `2D_versatile_fluo` checkpoint | `py\.venvsd` plus app-scoped weights |

Open **Models**, choose one of these cards, and select **Install**. Keep the app
open while the live installation log is running. Each model is independently
provisioned; installing one does not rewrite another model's environment. An
unknown ID fails explicitly, with no silent model substitution.

Model installation uses the network to obtain a Python runtime, pinned package
family, and model weights from their upstream package/model providers. Imported
images are not sent with those requests.

## Microscopy formats and advanced workflows

PNG, JPEG, BMP, TIFF/OME-TIFF, ND2, CZI, LIF, OIR, and VSI inputs remain local.
For proprietary containers, CellCounter keeps the untouched original and makes
a bounded, lossless projected analysis TIFF plus a display PNG. Missing vendor
reader dependencies and images above the safe decode budget fail with an
actionable message; they are never silently converted through another format.
Large acquisitions should be cropped or projected to OME-TIFF first.

The Results screen includes local intensity, area/wound/spheroid, puncta,
tracking, neurite, spatial-statistics, and line-profile workflows. Long-running
advanced assays and fine-tuning runs have explicit cancellation and clean up
their staged input/checkpoint files.

Fine-tuning is limited to the `cp-cyto3` family. Choose image/mask pairs in
**Fine-tune**, train and evaluate locally, then explicitly activate the saved
version. A derived version is recorded as `cp-cyto3@<version-id>` and does not
become a fourth built-in model. Checkpoints must remain regular files inside the
app-owned `Models` directory. Windows v1.0.8 trains on CPU and does not offer a
mixed-precision control.

## Local data and privacy

CellCounter stores its Windows data below these identifier-scoped directories:

- `%APPDATA%\com.alperengur.cellcounter\CellCounter`
  - `store.sqlite` — batches, measurements, corrections, ROIs, presets, and
    provenance
  - `Images` — application-owned copies of imported source images
  - `Originals` — untouched proprietary microscope containers
  - `Analysis` — lossless projected TIFFs used by detection and assays
  - `Thumbnails` — local previews
  - `Models` — app-scoped downloaded and fine-tuned weights, including
    StarDist's Keras cache
  - `Exports` — locally generated CSV, PDF, ROI, GeoJSON, and provenance files
- `%APPDATA%\com.alperengur.cellcounter\py`
  - `.venv` — `cp-cyto3`
  - `.venv4` — `cpsam_v2`
  - `.venvsd` — `sd-fluo`
  - `.venvio` — isolated, hash-locked microscopy container readers
  - staged, bundled sidecar scripts

Microscopy images never upload or leave this PC as part of detection. The app
does make outbound downloads when WebView2 or a selected model runtime is not
already present. There is no server inference path in the Windows 1.0.8 build.

## Backup and restore

1. Close CellCounter completely so `store.sqlite` and any model installation
   process are no longer writing.
2. In File Explorer, enter `%APPDATA%\com.alperengur.cellcounter` in the address
   bar.
3. Copy the entire directory to protected storage. Keeping `CellCounter` and
   `py` together preserves the database, imported copies, exports, environments,
   and model caches as one snapshot.
4. To restore, install the same or a compatible newer CellCounter version, close
   it, replace the identifier-scoped directory with the backup, and relaunch.

Do not copy only `store.sqlite`: its image records refer to files in `Images`,
and an incomplete backup can leave records without their source pixels.

## Reset

**Settings → Data & reset → Reset all data** deletes batches, imported display,
original and analysis image copies, thumbnails, detections, ROIs, ground truth,
and corrections after a confirmation. It preserves conditions,
calibration/bin presets, settings, downloaded models, and local Python
environments. This operation cannot be undone.

To perform a complete manual factory reset, first uninstall CellCounter, make
any required backup, and then delete
`%APPDATA%\com.alperengur.cellcounter`. Manual deletion removes model downloads
as well as microscopy data; do it only while the app is closed.

## Troubleshooting

### The installer is blocked by SmartScreen

Confirm the download source and SHA-256 first. Current CI artifacts are
unsigned, so a verified file may still show an unknown publisher. Do not bypass
the warning when the checksum or origin is uncertain.

### The window is blank or does not open

Repair or install Microsoft Edge WebView2 Runtime, then relaunch. If the
installer could not bootstrap it, check the workstation's proxy/firewall policy
or ask IT to deploy WebView2 separately.

### A model install fails

Keep the Models log visible and retain its final error. Confirm internet access,
available disk space, and write access to
`%APPDATA%\com.alperengur.cellcounter\py`. Security software may need to allow
the bundled `uv` process to download Python packages. Retry the same model card;
the app will not fall back to a different checkpoint.

### Detection is slow

Windows v1.0.8 uses the validated CPU path for all three models. Initial
inference can be slower while a runtime warms its model; later images with the
same Cellpose configuration reuse warm workers. Reduce parallel jobs if the PC
is memory-constrained. GPU acceleration is not advertised by this release.

### Imported images or models appear missing after restore

Exit the app and verify that both the `CellCounter` and `py` sibling directories
were restored under the exact identifier-scoped path. A database-only copy is
not a complete backup.

## Validation boundary

The Windows workflow runs on GitHub's `windows-latest` x64 image with pinned
Node.js, Rust, npm/Cargo lockfiles, and a checksum-pinned `uv` archive. It runs
the portable release audits, production frontend build, Rust tests, native MSI
and NSIS builds, installer discovery, SHA-256 generation, and artifact upload.

Before calling a public release fully qualified, a physical Windows test must
still exercise both installer UIs, upgrade/uninstall behavior, SmartScreen or a
real signing certificate, WebView2 bootstrap policy, the three model downloads,
CPU inference on representative public and vendor-format images, assay and
fine-tune cancellation, derived-checkpoint activation, provenance checksum
capture, and data restore. CI proves the packages build and contain the declared
resources; it cannot prove native reader DLL behavior, organization policy, or
real workstation performance.
