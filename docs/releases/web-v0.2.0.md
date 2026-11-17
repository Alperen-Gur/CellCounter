# CellCounter Web 0.2.0 preview

This preview introduces a redesigned scientific workbench, classical
segmentation and a saved processing workflow. Images and analysis stay in your
browser on this device.

## Interface

- Neutral surfaces and muted blue controls replace the green branding. The
  image has a larger canvas, with Library, Analyze, Processing and Review as
  the main destinations.
- Setup, Selection and Image tabs organize the inspector. Measurements open
  when needed, and one contextual action leads from preview to processing.
- Small screens use an inspector sheet. Screen-scoped shortcuts and in-app help
  cover the available actions.
- A first-visit introduction includes a rotatable 3D point cloud, shape
  morphing and scroll-linked transitions. Pause, rotation controls and
  reduced-motion support are available, and the scene unloads when you enter
  the workspace.
- Icons use the Lucide library. Three.js renders the illustration; license
  notices are included with the static application files.
- An update notice offers a safe reload when a newer PWA is ready.

## Local analysis

Classical Otsu, triangle, adaptive and manual thresholding run in a local
Worker, with source-channel selection, first/max/mean/sum projection,
background subtraction, minimum-area filtering and optional watershed.

Preview a representative image, inspect it, and process the image or study.
The saved preview is reused only when source bytes, parameters, model identity
and calibration still match. Processing jobs keep their settings and saved
results. Pause after the current image, cancel and pause immediately, resume
after reopening, or retry failed images without discarding completed work.

Image, paged table and scatter selection share cell identity. Saved mask
alternatives show change counts in the same image coordinates; applying an
alternative keeps the current mask first. Recorded analysis settings stay
separate from later review settings.

Learned-model inference, training, proprietary microscope formats, OME-Zarr and
layer, sequence and prompt workflows are not part of this preview.

## Install

The download contains the static PWA and license notices. Serve its files over
HTTPS, or use localhost for development; opening `index.html` directly is not
supported. Browser storage can be cleared or evicted, so export results you
want to keep.

See the [browser guide](../WEB.md) and [feature comparison](../FEATURES.md).
