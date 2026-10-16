# Release status and feature parity

Release series: **17 October 2026** — macOS **1.0.17**, Windows **1.2.1**,
and Web **0.3.1 preview**.

Windows and Web now include local OME-Zarr v2 workspaces, multidimensional layers,
translation registration, grid stitching, label painting, lineage, project replay
and GIF export. Review, source-plane selection, preprocessing comparisons,
reviewed dataset snapshots and sample exports have also expanded.
See the [portable workspace guide](PORTABLE-WORKSPACE.md) for supported formats,
coordinates, limits and workflow details.

| Capability | Windows 1.2.1 | Web 0.3.1 preview |
| --- | --- | --- |
| Local microscopy workspace | Included with bounded source loading | Included entirely in the browser |
| Review, corrections and source inspection | Native source reader; recorded selection and verified source identity | Local raster/TIFF and Zarr sources; explicit plane selection |
| Learned segmentation | Local Cellpose, StarDist, Omnipose and imported checkpoint routes; installation and exact checkpoint verification required | Compatible qualified artifacts are not bundled |
| Classical segmentation | Included | Included without model downloads |
| Reviewed dataset snapshots | Grouped local TIFF/mask datasets | Grouped local TIFF/mask ZIP export with size limits |
| Training | Existing local cyto3 training workflow | Unavailable |
| Proprietary microscope readers | Local reader dependencies required | Unavailable |
| Sample exports | Local folder, source, measurements, reports and hashes | Local ZIP, source, measurements, reports and hashes |

Full macOS parity has not been reached. Portable algorithms, supported codecs,
resource limits and output formats differ. Model setup remains CPU-only on
Windows. The web app has no local companion or image-upload service; its learned
model artifacts, proprietary readers and actual training remain unavailable.

The [Windows notes](releases/windows-v1.2.1.md) and
[web notes](releases/web-v0.3.1.md) describe this release. The detailed
[feature tables](FEATURES.md) retain the earlier release baseline and are labeled
accordingly. Current in-app capability inventories describe the new implementation.

Production compilation and artifact checks are required before publishing these
packages. Automated tests, interactive app checks and inference were not run for
this change; packaging does not establish scientific accuracy or runtime parity.
Windows installers are unsigned. Web is a static PWA archive served over HTTPS
or localhost; publication does not create a hosted service.

The macOS diagnostics release is:
[1.0.17](https://github.com/Alperen-Gur/CellCounter/releases/tag/v1.0.17).
Earlier Windows preview-recovery and calibration fixes remain included.

These diagnostics releases add opt-in real-workflow timing sessions and editable
local report exports across all three platforms. Recording starts only by user
choice, and reports have no automatic upload path.
