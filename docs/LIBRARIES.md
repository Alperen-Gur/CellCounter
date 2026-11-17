# Libraries and batch archives

On macOS, the existing image library keeps your batches, imported images, cell outlines,
measurements, corrections and calibration in one folder. You can keep several libraries,
for example one per project or per year, and move finished batches into self-contained
archives that you can restore at any time.

Open the library tools from **Existing library** in the sidebar. For project-based analysis,
see the [Workbench guide](WORKBENCH.md).

## Libraries

Each new library is a folder with the `.cellcounterlibrary` extension. Its database and
images travel together, so a library can live on an external or network drive.

Your existing data stays where it is and opens as the **Default Library**
(`~/Library/Application Support/CellCounter`). Models, Python environments and analysis
protocols are installed once and shared by every library.

The sidebar shows the open library's name and image count under **Existing library**.
**Library overview** shows the same summary with **Show in Finder**.

### Library commands

All commands are in the **File** menu.

| Command | What it does |
| --- | --- |
| **New Library…** | Creates an empty library and opens it. Leave **Copy calibration presets, size-bin presets and conditions from “…”** selected to start with the settings of the library that is open now. |
| **Open Library…** | Opens a library or a batch archive. |
| **Open Recent Library** | Lists recently opened libraries and archives. Libraries on a disconnected drive are shown as not available. **Clear Menu** empties the list. |
| **Open Default Library** | Returns to the Default Library. |
| **Show Library in Finder** | Reveals the open library's folder. |

CellCounter opens one library at a time. Switching saves your work and relaunches the app
with the other library, which stays open on the next launch.

Finish or pause running work before you switch. CellCounter asks you to wait while images
are importing, an analysis is running or queued, a model is training, library data is being
copied into a project, or the Workbench is busy or has unsaved changes.

If the remembered library cannot be found at launch, for example because its drive is
disconnected, CellCounter opens the Default Library and shows **Library not available**.
Connect the drive and choose **File → Open Recent Library**.

### What a library folder contains

| Item | Contents |
| --- | --- |
| `store.sqlite` | Batches, images, cell outlines and measurements, corrections, regions of interest, review decisions, saved mask versions and calibration. |
| `Images/` | Imported image files, named by image ID. |
| `DisplayImages/` | Viewable copies of microscope-vendor files. |
| `Thumbnails/` | Small previews. |
| `Embeddings/` | Image caches for prompt-assisted correction. CellCounter rebuilds them when needed. |
| `analysis-jobs.json` | Saved processing jobs. |
| `Backups/` | Safety copies of the database made before an upgrade. See [Upgrade from an earlier version](INSTALL.md#upgrade-from-an-earlier-version). |
| `CellCounterLibrary.json` | The library's name and type. |

Keep the folder together. Moving or renaming files inside it breaks the link between the
database and the images.

## Archive a batch

Archiving moves a batch out of your library into its own folder, with its images, cell
outlines, measurements and calibration. The space it used in your library is freed, and you
can restore it whenever you need it.

Start an archive from any of these places:

- **Archive…** in the batch header.
- **Archive Batch…** in the batch list's context menu or the **Recent** list in **Library overview**.
- **File → Archive Batch…** while a batch is open.

Choose where to save the archive. CellCounter suggests
`~/Documents/CellCounter Archives/<batch> – archived <date>.cellcounterlibrary`. The
archive must be outside the library folder, and CellCounter never replaces an existing
folder.

CellCounter then copies the batch, writes CSV files and a README, and checks the copy
against the original record by record and file by file. Only then does it remove the batch
from your library. If you cancel or anything fails before that point, the incomplete archive
is removed and your library is unchanged.

A batch that is still being analyzed cannot be archived. Pause or finish its analysis under
**Processing jobs** first.

### What an archive contains

An archive is a complete library holding one batch. It does not depend on the library it
came from.

| Item | Contents |
| --- | --- |
| `README.txt` | Batch name, condition, dates, image and cell counts, model, scale and where each part is stored. |
| `store.sqlite` | The batch with every detected cell, corrections, regions of interest, review decisions, saved mask versions, ground-truth points, run settings and calibration. |
| `Images/`, `DisplayImages/`, `Thumbnails/` | The original image files, viewable copies and previews. |
| `Exports/images.csv` | Image IDs mapped to original file names, with pixel dimensions, checksum, the scale found in the file and cell count. |
| `Exports/cells/` | One CSV per analyzed image, one row per cell. |
| `Exports/per-image-summary.csv` | One row per image: counts, mean diameter and size bins. |
| `Exports/provenance.json` | Model, settings and calibration recorded for each image. |
| `CellCounterLibrary.json` | Machine-readable description of the archive. |

The CSV files open in Excel, R or Python. Lines starting with `#` record the confidence
cut-off, size bins, model and scale. As in other CellCounter exports, the CSV files leave
out cells below an image's confidence cut-off; the database keeps every detected cell.

To browse an archive without restoring it, open it with **File → Open Library…**.

### Restore an archived batch

Choose **File → Restore Archived Batch…** and select the archive folder. The batch returns
to the open library with the same IDs, outlines, measurements and calibration. The archive
itself is not changed, so you can keep it as a backup.

CellCounter does not restore a batch that is already in the open library.

## Delete a batch

Deleting a batch from the trash button or **Delete Batch…** asks
**Archive or delete this batch?**

- **Archive…** (the default) starts an archive as described above.
- **Delete Permanently** removes the batch's images, cell outlines, measurements and
  calibration from this Mac after a second confirmation. This cannot be undone.

## Saved mask versions

When you analyze an image again, CellCounter keeps the previous mask as a saved version.
Find them under **Saved mask variants** in the **Review & validation** and
**Smart correction** tools of the results view.

| Action | Result |
| --- | --- |
| **Compare** | Shows the saved and current masks side by side with linked pan and zoom. |
| **Use** | Swaps the saved version with the current mask. The current mask, including any unsaved edits, is kept as a version. |
| Trash button | Deletes that version. |

Saved versions are stored compressed, and identical masks are stored only once.

Choose how many versions each image keeps in **Settings → General → Saved mask versions**:

| Setting | Options |
| --- | --- |
| **Mask versions kept per image** | 3, 5 (default), 10 or **Keep all**. When a new version is saved, older versions beyond this number are removed. The current mask is never affected. |
| **Remove older versions now** | Applies the limit to every image in the library after you confirm. Removed versions cannot be restored. |

## Large libraries

CellCounter is built to stay responsive as a library grows:

- Cell outlines and measurements are stored compactly, separately from image records.
- Batch lists, the image library and **Compare conditions** read compact measurements stored
  with each image instead of decoding every cell outline.
- Older libraries are converted gradually in the background after an upgrade, and unused
  image caches are cleaned up, while you keep working.
- Every detector keeps its model loaded between images in a batch.
- Per-cell measurement is faster.
- Caches are released when macOS asks apps to free memory.
- Exports process one image at a time.

If a library still feels slow, open **Support → Local diagnostics & performance…** and
include **library size and Mac summary** in the report. It lists counts and storage sizes
only, with no names, paths or IDs. See [Optional local diagnostics](INSTALL.md#optional-local-diagnostics).

## Back up a library

Quit CellCounter, then copy the whole library folder. For the Default Library, copy
`~/Library/Application Support/CellCounter`; it also holds your installed models and Python
environments. Archives are ordinary folders and can be backed up the same way.
