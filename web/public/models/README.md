# CellCounter Web model assets

Production segmentation weights are not included in the v0.2.0 web release.
The application reports learned inference as unavailable and does not upload
images or silently substitute another model.

Future web releases may provide validated, same-origin model assets for local
WebGPU inference. The native macOS and Windows releases are currently the
recommended choice when learned segmentation is required.

The explicitly selected Classical threshold + watershed detector is included in the application and runs locally on the CPU without model weights. It is not Cellpose or StarDist.
