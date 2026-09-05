# Installing CellCounter

## macOS v1.0.12

CellCounter requires **macOS 15 or later**. The macOS download is a **universal build for Intel and Apple Silicon Macs**. Python environments and model dependencies are installed separately for your Mac when needed.

The application is **ad-hoc signed and not notarized**. macOS may block its first launch because Apple has not verified the developer or notarized the app.

### Install and open

1. Download `CellCounter-v1.0.12.zip` from the [Releases page](https://github.com/Alperen-Gur/CellCounter/releases).
2. Unzip the download and drag **CellCounting.app** into **Applications**. The application is called CellCounter; its bundle on disk is named `CellCounting.app`. Quit an older copy before replacing it. Replacing the application is separate from resetting its saved library.
3. Open the application. If macOS blocks it, dismiss the message without moving the app to Trash.
4. Open **System Settings → Privacy & Security** and find the message about CellCounter being blocked. Choose **Open Anyway**, then confirm **Open** when prompted. Depending on your Mac's security policy, administrator approval may be required.
5. Open CellCounter again if it did not launch automatically. Subsequent launches should use the same installed copy.

The release uses ad-hoc signing; it does not include an Apple Developer ID signature or Apple notarization. Managed institutional Macs may require your IT administrator to approve installation.

### Start with your images

1. On **Home**, open or drop supported images, or use **File → Open Images…** (`⌘O`) or **Open Folder…** (`⌘⇧O`).
2. In **Set up analysis**, inspect a representative image and choose a task, calibration, model, channels and Z projection as appropriate. You can import and inspect images before installing a segmentation model. Some proprietary formats require optional Python readers.
3. If you want segmentation, install the selected model from **Models**. Return to **Processing → Continue setup** to continue the saved setup.
4. With the model installed, run **Preview** on the representative image, inspect the masks, and adjust the settings before starting the batch. Matching preview results are reused.
5. Use **Processing** to follow progress, pause after an image, resume or retry failed images. Open completed images to review them while the remaining images process. Interrupted jobs are restored as paused after relaunch.

Task presets provide starting points. Marker positivity and wound closure need their corresponding assay settings and measurements; choosing a preset does not itself perform the assay.

### Install a segmentation engine

1. Open **Models** and choose the model you intend to use.
2. Use its installation action. Cellpose 3 and Cellpose 4/SAM have separate environments; other model families may have their own requirements.
3. Allow the required Python packages and model weights to download. Installation can take several minutes. The installation dialog shows progress and a live log.
4. If installation fails, retain the log and the model name for a bug report, then use the available retry or repair action.

The application download does not include all Python dependencies or model weights. After the required components are installed, image analysis runs locally. Local fine-tuning additionally requires the Cellpose 3.x environment, existing compatible weights and reviewed segmentation masks; see the [v1.0.11 release notes](releases/v1.0.11.md).

### First preview and model downloads

Ordinary PNG, JPEG and BMP previews do not need Python startup when their pixel layout is supported. The original image stays visible while the selected channel is prepared. Scientific formats may still require their Python reader.

Some Cellpose checkpoints download on the first analysis even after the Python environment is installed. Keep the app open while **downloading weights** shows progress. A stalled connection reports a download failure; restore connectivity and retry the image. After an interrupted session, reopen the app and resume the paused job in **Processing**. Completed model downloads are reused.

**No calibration metadata found** is expected for many screenshots and ordinary photographs. It does not mean segmentation failed. Enter a known pixels-per-micrometre scale for calibrated measurements; a screenshot alone does not establish that scale.

See the [v1.0.12 hotfix notes](releases/v1.0.12.md).

### Find keyboard shortcuts

Open **Help → Keyboard Shortcuts** with `⌘/`, or use the shortcuts section in **Settings**. Menus show the actions available on the current screen; disabled actions have no applicable target. Letter keys for cell editing apply when the image canvas has focus. Search fields and text editors keep normal Mac text selection and undo behavior.

## Other platforms

For the separate Windows application, see the [Windows guide](WINDOWS.md). This macOS release does not include a native Linux package. The [web guide](WEB.md) describes the browser preview and its separate capability limits.

## Sharing with colleagues

Some institutional mail servers reject application bundles or archives that contain them. Share the official release link instead of attaching the application to an email.
