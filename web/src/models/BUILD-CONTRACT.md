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
3. Prove numerical and instance-mask parity against the macOS v1.0.8 pipeline
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
