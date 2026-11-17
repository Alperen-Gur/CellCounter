# CellCounter for macOS: Unreleased

This release adds multiple libraries and batch archives, keeps saved mask versions compact,
and keeps large libraries responsive.

Requires **macOS 15 or later**. Universal app for Intel and Apple Silicon, ad-hoc signed and not notarized.

## Libraries and archives

- **Multiple libraries.** Use **File → New Library…**, **Open Library…**, **Open Recent Library**,
  **Open Default Library** and **Show Library in Finder** to keep a separate library per project
  or per year. A library is a `.cellcounterlibrary` folder. Your existing data opens as the
  **Default Library**. Switching libraries relaunches the app.
- **Archive instead of delete.** Removing a batch now offers **Archive…** (the default) or
  **Delete Permanently**.
- **Archive Batch…** moves a batch, with its images, outlines, measurements and calibration, into a
  self-contained `.cellcounterlibrary` folder with CSV exports and a README. The archive is checked
  against the original before the batch leaves the library.
- **Restore Archived Batch…** brings an archived batch back with the same IDs, outlines,
  measurements and calibration. The archive is not changed.

See [Libraries and batch archives](../LIBRARIES.md).

## Saved mask versions

- Saved mask versions are stored compressed, and identical masks are stored once.
- **Use** swaps a saved version with the current mask, so the current mask is kept as a version.
- New **Settings → General → Saved mask versions** options: **Mask versions kept per image**
  (3, 5, 10 or **Keep all**) and **Remove older versions now**.

## Large libraries

- Cell data is stored compactly and separately from image records.
- Batch lists, the image library and **Compare conditions** read compact measurements stored with
  each image instead of decoding every cell outline.
- Older libraries are converted in the background after the upgrade, and unused image caches are
  cleaned up.
- All detectors keep their model loaded between images, not only Cellpose.
- Per-cell measurement is faster.
- Caches are released when macOS reports memory pressure.
- Exports process one image at a time.

## Measurements and diagnostics

- StarDist and SAM detections now include perimeter and circularity.
- The local diagnostics report can include a numbers-only **Library size** section with storage
  sizes and a summary of your Mac.

## Update

Quit the old app and replace **CellCounting.app** in Applications. The first time this version opens
a library, it saves a verified copy of the library's database in its `Backups/` folder and then
upgrades the library to the new storage format. Read [Upgrade from an earlier version](../INSTALL.md#upgrade-from-an-earlier-version)
before going back to an older version.
