# Installing CellCounter

## macOS v1.1.0

CellCounter requires **macOS 15 or later**. The macOS download is a **universal build for Intel and Apple Silicon Macs**. Python environments and model dependencies are installed separately for your Mac when needed.

The application is **ad-hoc signed and not notarized**. macOS may block its first launch because Apple has not verified the developer or notarized the app.

### Install and open

1. Download `CellCounter-v1.1.0.zip` from the [macOS release](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.1.0).
2. Unzip the download and drag **CellCounting.app** into **Applications**. The application is called CellCounter; its bundle on disk is named `CellCounting.app`. Quit an older copy before replacing it. Replacing the application is separate from resetting its saved library.
3. Open the application. If macOS blocks it, dismiss the message without moving the app to Trash.
4. Open **System Settings → Privacy & Security** and find the message about CellCounter being blocked. Choose **Open Anyway**, then confirm **Open** when prompted. Depending on your Mac's security policy, administrator approval may be required.
5. Open CellCounter again if it did not launch automatically. Subsequent launches should use the same installed copy.

The release uses ad-hoc signing; it does not include an Apple Developer ID signature or Apple notarization. Managed institutional Macs may require your IT administrator to approve installation.

### Start with your images

1. Open **Workbench**. Use **AI agent and command-line access → Install or repair** to set up the dedicated Workbench environment with Python 3.11 or later and the pinned analysis, MCP, Zarr and reporting dependencies.
2. Create or open a local project. Import supported acquisitions, choose their source channel/projection and confirm calibration before analysis.
3. Preview segmentation, save masks and correct them before running measurements or assays. Classical analysis needs no learned checkpoint; registered models require an explicitly selected compatible checkpoint and interpreter.
4. Save workflows for repeatable processing. Existing Jobs controls can advance checkpoints or start a background worker; a stop request pauses after the current unit.
5. Export scientific files or a project package. For an agent connection, copy the configuration from **AI agent and command-line access**; it uses the installed executable's `--workbench` entry point and explicit project permissions.

The dedicated runtime is installed only by your explicit action. Agent invocation does not automatically install software. Model environments and optional OMERO configuration remain separate. See the [Workbench guide](WORKBENCH.md) for limits, source formats, revision checks and executable-code permissions.

### Existing library workflow

Older library data remains available. The migration controls preview a copy into a new Workbench project and retain historical evidence; they do not replace the original library or turn historical contours into exact instance masks.

1. On **Home**, open or drop supported images, or use **File → Open Images…** (`⌘O`) or **Open Folder…** (`⌘⇧O`).
2. In **Set up analysis**, inspect a representative image and choose a task, calibration, model, channels and Z projection as appropriate. You can import and inspect images before installing a segmentation model. Some proprietary formats require optional Python readers.
3. If you want segmentation, install the selected model from **Models**. Return to **Processing → Continue setup** to continue the saved setup.
4. With the model installed, run **Preview** on the representative image, inspect the masks, and adjust the settings before starting the batch. Matching preview results are reused.
5. Use **Processing** to follow progress, pause after an image, resume or retry failed images. Open completed images to review them while the remaining images process. Interrupted jobs are restored as paused after relaunch.

Task presets provide starting points. Marker positivity and wound closure need their corresponding assay settings and measurements; choosing a preset does not itself perform the assay.

### Install a segmentation engine for the existing library

1. Open **Models** and choose the model you intend to use.
2. Use its installation action. Cellpose 3 and Cellpose 4/SAM have separate environments; other model families may have their own requirements.
3. Allow the required Python packages and model weights to download. Installation can take several minutes. The installation dialog shows progress and a live log.
4. If installation fails, retain the log and the model name for a bug report, then use the available retry or repair action.

The application download does not include all Python dependencies or model weights. After the required components are installed, image analysis runs locally. Local fine-tuning additionally requires the Cellpose 3.x environment, existing compatible weights and reviewed segmentation masks; see the [v1.0.11 release notes](releases/v1.0.11.md).

### Existing library previews and model downloads

Ordinary PNG, JPEG and BMP previews do not need Python startup when their pixel layout is supported. The original image stays visible while the selected channel is prepared. Scientific formats may still require their Python reader.

Some Cellpose checkpoints download on the first analysis even after the Python environment is installed. Keep the app open while **downloading weights** shows progress. A stalled connection reports a download failure; restore connectivity and retry the image. After an interrupted session, reopen the app and resume the paused job in **Processing**. Completed model downloads are reused.

**No calibration metadata found** is expected for many screenshots and ordinary photographs. It does not mean segmentation failed. Enter a known pixels-per-micrometre scale for calibrated measurements; a screenshot alone does not establish that scale.

See the [v1.0.12 hotfix notes](releases/v1.0.12.md).

### Historical Review Queue fixes

macOS v1.0.15 adds further protection against deleted review records and malformed saved measurements. Resetting all data clears orphaned analysis records as well as batches; updating the app does not reset the library. Review saves and undo retain the earlier protections against delayed Results edits. Missing thumbnails can use a bounded preview of the imported image.

Quit the old copy, replace the application, and reopen Review Queue. Existing images and corrections are preserved; a data reset is unnecessary. Older libraries may briefly prepare their review index. Read or save failures are shown explicitly instead of appearing as an empty queue.

The follow-up report is [issue #10](https://github.com/Alperen-Gur/CellCounter/issues/10). The universal release archive was built, but automated tests and interactive validation were not run for this release. The reporter's exact crash remains unconfirmed. See the [v1.0.15 release notes](releases/v1.0.15.md).

### Find keyboard shortcuts

Open **Help → Keyboard Shortcuts** with `⌘/`, or use the shortcuts section in **Settings**. Menus show the actions available on the current screen; disabled actions have no applicable target. Letter keys for cell editing apply when the image canvas has focus. Search fields and text editors keep normal Mac text selection and undo behavior.

## Other platforms

For the separate Windows application, see the [Windows guide](WINDOWS.md). This macOS release does not include a native Linux package. The [web guide](WEB.md) describes the browser preview and its separate capability limits.

## Sharing with colleagues

Some institutional mail servers reject application bundles or archives that contain them. Share the official release link instead of attaching the application to an email.

## Optional local diagnostics and real-workflow benchmarks

**Local diagnostics & performance** is available in Support (macOS and Windows)
or Help (web), beginning with macOS 1.0.17, Windows 1.2.1 and Web 0.3.1 preview.

Choose **Start recording**, then use real images and the normal import,
processing, review, workspace, assay and export controls. Normal analysis retains
its normal results. There are no synthetic workloads or automatic reruns.
Choose a 10-minute, 30-minute or two-hour limit; a visible Stop control remains
available while navigating. Stop early or erase the recorded timings at any time.

Recording is disabled initially and must be started each app session. It stores
only bounded numeric aggregates under fixed operation categories, in memory:
counts, durations, failures where known, unfinished operations and recent latency
percentiles. Foreground interface scheduling is measured during recording.
Names, paths, image content, saved measurements, IDs, device identifiers, raw
logs, free-form errors, wall-clock timestamps and event order are excluded.
A crash or app exit loses unsaved results; this is not a crash-dump collector.

Afterward, explicitly include the optional state summary and/or recorded timings,
prepare the editable preview, remove any lines you do not want to share, and mark
it inspected. Export writes exactly that text, up to 64 KiB, with no attachments
or automatic uploads. Editing clears the inspection confirmation. Sharing is a
separate manual action. The chosen file destination may be synced by other
software. Counts and timings can reveal workload characteristics, so inspection
is still important; absolute anonymity cannot be guaranteed for text users add.

Timings cover instrumented real workflow boundaries and include waiting, cache
and scheduling effects. Nested categories overlap. Unobserved operations are
listed rather than estimated, and incomplete work is marked explicitly. Native
exports and other boundaries that cannot classify their final outcome report it
as unspecified. Timing summaries do not establish segmentation accuracy or expose
CPU/GPU kernel profiles. Startup before opt-in and work before recording began
are not measured. Keep input/settings consistent when comparing sessions.
