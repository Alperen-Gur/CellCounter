# Building web models

The catalog entries for `cpsam_v2`, `cp-cyto3` and `sd-fluo` start as
`buildRequired`. Package and test the model artifact before setting an entry to
`ready`. Test fixtures must not change catalog availability.

## Artifact format

Export a self-contained ONNX graph with:

- Input `image`: normalized float32 NCHW, shape `[1,3,tileSize,tileSize]`
- Output `labels`: integer instance labels, shape `[1,tileSize,tileSize]`
- WebGPU-compatible operators throughout the graph

Cellpose returns flows and cell probabilities; StarDist returns probabilities
and radial distances. Include Cellpose dynamics/watershed or StarDist NMS in the
graph, or implement and test an equivalent browser postprocessor.

Upstream implementations:

- [Cellpose dynamics](https://github.com/MouseLand/cellpose/blob/main/cellpose/dynamics.py)
- [StarDist models](https://github.com/stardist/stardist/blob/main/stardist/models/base.py)

## Build and package

1. Start from the checkpoint named by the model ID. Record its URL, SHA-256,
   license, conversion environment, exporter commit, ONNX opset and ONNX Runtime
   Web version.
2. Compare numeric outputs and instance masks with the macOS v1.0.12 pipeline.
   Include brightfield, fluorescence, empty, dense, border-touching,
   multichannel and low-contrast fixtures.
3. Run the graph with ONNX Runtime Web's WebGPU provider. Fix unsupported
   operators rather than falling back to CPU/WASM.
4. Place the artifact at its same-origin, versioned catalog URL. Compute the
   SHA-256 and byte length from the packaged file.
5. Replace the catalog's zero-filled digest and set `availability` to `ready`
   together. Run the catalog, browser, offline-cache, tamper, cancellation and
   parity checks before release.

The runtime checks availability before downloading. Keep zero-filled digests
only on `buildRequired` entries.
