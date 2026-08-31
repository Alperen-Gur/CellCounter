# Model artifact mount

Release packaging places validated, checksummed ONNX artifacts below this
directory at the exact versioned URLs declared by `src/models/catalog.ts`.
Weights are intentionally ignored by Git and are not present in this source
checkout. See `src/models/BUILD-CONTRACT.md` before changing a manifest from
`buildRequired` to `ready`.
