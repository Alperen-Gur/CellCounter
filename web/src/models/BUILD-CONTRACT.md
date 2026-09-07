# Audited web-model build contract

The repository intentionally contains no model weights. The three catalog
entries are `buildRequired`, so production inference fails explicitly until a
release engineer packages validated artifacts. Fixture inference must never
change catalog availability.

For each model, the conversion pipeline must:

1. Start from the upstream checkpoint named by the model id and record its
   source URL, source SHA-256, license, conversion environment, exporter commit,
   ONNX opset, and ONNX Runtime Web version in a release audit record.
2. Export a self-contained ONNX graph with input `image`, shape
   `[1,3,tileSize,tileSize]`, normalized float32 NCHW, and output `labels`, an
   integer instance-label map of shape `[1,tileSize,tileSize]`. Model-specific
   Cellpose dynamics/watershed or StarDist NMS must be included in the audited
   build or a separately parity-gated browser postprocessor before the catalog
   may become ready.
3. Prove numerical and instance-mask parity against the macOS v1.0.12 pipeline
   over representative brightfield and fluorescence fixtures. Include empty,
   dense, border-touching, multichannel, and low-contrast images. A conversion
   that merely loads or returns plausible shapes is not sufficient.
4. Run ONNX Runtime Web with the WebGPU execution provider on every graph and
   reject any unsupported operator. CPU/WASM substitution is not allowed.
5. Place the artifact at the same-origin versioned catalog URL. Compute SHA-256
   and byte length from the exact packaged bytes, then atomically replace the
   catalog sentinel, set `availability` to `ready`, and rerun catalog, browser,
   offline-cache, tamper, cancellation, and parity gates.

The current build-required digests are visibly all-zero, non-runnable sentinels.
They are not claims about an ONNX artifact. Release packaging must replace a
sentinel with the digest of the exact packaged bytes in the same change that
sets `availability` to `ready`. The runtime checks availability before network
access, so a sentinel cannot be mistaken for a deployable model.

Current live-artifact blocker: validated ONNX artifacts satisfying this output
contract have not been packaged for `cpsam_v2`, `cp-cyto3`, or `sd-fluo`.


## v0.2.0 investigation and usable detector

The application now includes an explicitly selected Classical threshold + watershed
engine. It uses no ONNX artifact and never replaces a requested learned model.
The learned-model gate remains independent from this usable classical workflow.

Upstream Cellpose inference returns flow fields and cell probability followed by
`cellpose.dynamics` integration. Upstream StarDist `predict` returns probability
and radial distance tensors and uses non-maximum suppression to form instances.
Neither ordinary upstream checkpoint directly satisfies this application's
integer instance-label-map output contract. Downloading weights alone therefore
does not enable these catalog rows. Relevant primary-source implementation:

- https://github.com/MouseLand/cellpose/blob/main/cellpose/dynamics.py
- https://github.com/stardist/stardist/blob/main/stardist/models/base.py
- https://github.com/stardist/stardist/issues/305

A future port can use separately validated browser postprocessors or a fully
converted graph. Source checkpoint identity, numeric/instance fixtures and
WebGPU operator coverage must be checked before changing availability. This
release does not claim learned-model parity from the classical detector tests.
