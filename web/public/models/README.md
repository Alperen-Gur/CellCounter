# CellCounter Web model assets

Qualified learned-segmentation weights are not included in the **0.3.2 preview**.
The application reports learned inference as unavailable. It does not upload
images or silently substitute another model.

The explicitly selected **Classical threshold + watershed** detector runs locally
in a CPU Worker without model weights. It is separate from Cellpose and StarDist.
Use the [desktop releases](../../../README.md#download) when learned segmentation
is required.

Browser learned-model adapters require compatible, same-origin artifacts for
local WebGPU inference. The [model build contract](../../src/models/BUILD-CONTRACT.md)
describes checkpoint identity, validation and manifest requirements for supplying
such artifacts. See the [browser guide](../../../docs/WEB.md#webgpu-model-boundary)
for the published preview's limits.
