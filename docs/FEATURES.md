# CellCounter features

Import images, segment cells, review masks and turn measurements into experiment results.
The desktop Workbench keeps images, settings, corrections and analysis history together in
one project.

Available as **macOS 1.1.0**, **Windows 1.3.0** and a **Web 0.3.2 preview**.
See the [edition comparison](PLATFORM-PARITY.md), [Workbench guide](WORKBENCH.md) or
[comparison with other microscopy tools](COMPARISON.md).

## Import and organize

| Feature | What you can do |
| --- | --- |
| Images | Import TIFF/OME-TIFF, PNG, JPEG and BMP; choose channels, projections and time points. |
| Large images | Browse overviews and import original-resolution TIFF or NGFF regions. Run tiled threshold analysis. |
| OME-Zarr / OME-NGFF | Read NGFF 0.4/Zarr v2 and 0.5/Zarr v3 datasets with their storage dependencies. |
| OMERO | Connect to your server and import image regions using a local connection profile. |
| Calibration | Read image metadata or enter X, Y and Z spacing. Measurements update when calibration changes. |
| Image libraries | Search and browse acquisitions, inspect their history, and copy existing libraries into Workbench projects. |
| Experiments | Organize conditions, plates, wells and biological specimens. Record sample assignments and exclusions. |

## Segment, correct and review

| Feature | What you can do |
| --- | --- |
| Classical segmentation | Use Otsu, manual, triangle, Li, Yen, mean or adaptive thresholds, with hole filling and watershed. Use Otsu/manual thresholding and watershed for 3D volumes. |
| AI models | Run Cellpose 3, Cellpose 4 / Cellpose-SAM, StarDist 2D, Omnipose or micro-SAM with a local model environment and checkpoint. |
| External masks | Import integer TIFF or NPY instance labels for a plane or volume. |
| Mask editing | Add, delete, merge and edit objects with polygons and brushes. Edit volume slices, undo changes and revisit correction history. |
| Mask comparisons | Keep multiple masks for the same source, including nuclear and whole-cell masks, and compare their agreement. |
| Review | Review flagged objects, sample results at random, run blinded reviews and record independent decisions and adjudication. |
| Model adaptation | Choose images for annotation, train Cellpose 3 and compare the adapted model on separately assigned specimens. |

## Measure and interpret

| Feature | What you can do |
| --- | --- |
| Object measurements | Measure counts, area, volume, morphology, centroids, intensity and 3D shape. |
| Cellular assays | Analyze marker positivity, colocalization, live/dead classes, DNA content, nuclear-to-cytoplasmic intensity and puncta. |
| Spatial and temporal analysis | Measure neighborhoods, time series, wound closure and motion. |
| Tracking and lineage | Link objects across frames, adjust displacement and gap settings, correct tracks and review proposed divisions. |
| Biological replicates | Compare specimens with Welch or paired t-tests and linear models, including interactions and subject/block effects. |
| Statistical reports | Export input tables, effect estimates, JSON reports and SVG effect plots. |

See [experimental designs and statistical reports](WORKBENCH.md#experimental-designs-and-statistical-reports)
for setup and examples.

## View and process images

- Explore linked XY, XZ and YZ slices and a rotatable volume view.
- Combine channels, adjust intensity and gamma, and save display presets.
- Work with image, label, point, shape, track and surface layers.
- Paint labels, add annotations, replay edits and export GIF presentations.
- Build preprocessing recipes for smoothing, background correction, normalization, contrast and sharpening.
- Run Richardson–Lucy deconvolution with a Gaussian PSF.
- Align 2D images by translation and stitch image grids.

## Workflows and export

| Feature | What you can do |
| --- | --- |
| Saved workflows | Build linear or branching workflows, preview steps, run parameter sweeps and add review gates. |
| Resumable jobs | Process in the background, pause and resume jobs, and recover from saved checkpoints. |
| Portable tasks | Prepare, transfer and collect analysis work packets. |
| Updating results | Mask edits update measurements. Review and refresh related results in dependency order while keeping earlier outputs in the project history. |
| Scientific exports | Export calibrated images, labels, tables, annotations, overlays, lineage files and analysis history. |
| Analysis packages | Bundle source images, masks, results, settings and history to share or reopen an analysis. |

## Automation and plugins

The desktop app, CLI, Python SDK and MCP server share the same project operations and history.
Connect an AI agent to inspect projects, run analyses, edit masks and export results. Choose
its project access, allowed folders and permission to make changes in the desktop app's
**AI agent and command-line access** panel. See [MCP setup](WORKBENCH.md#mcp-connection).

Add local plugins for **image readers, segmentation, measurements and exports**.
Model and environment records travel with the analysis history.

## Browser preview

The browser app includes classical segmentation, measurements, mask correction, portable
layer workspaces, processing jobs and file exports. Images are processed locally in your browser.
See the [browser guide](WEB.md) for setup and workspace tools.

For desktop installation, see the [macOS guide](INSTALL.md) or [Windows guide](WINDOWS.md).
Release notes: [macOS](releases/v1.1.0.md), [Windows](releases/windows-v1.3.0.md),
[browser](releases/web-v0.3.2.md).
