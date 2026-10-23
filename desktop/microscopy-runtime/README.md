# Packaged microscopy runtime

Release packaging places the Node runtime and compiled microscopy worker here.

Build the worker with `shared/microscopy-worker/build.mjs` into a new assets
directory. Run `stage-runtime.py` with the pinned official Node archive and the
matching Windows target, then copy the staged directory's contents here. Include
the runtime manifest, JavaScript modules, Node executable and license together.

Release builds need `microscopy-runtime.json`. During development, configure a
local runtime manifest to run workspace operations.
