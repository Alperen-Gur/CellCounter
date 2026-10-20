This directory holds generated, release-staged runtime assets. It contains no downloaded runtime in the source repository.

Compile the shared microscopy worker with `shared/microscopy-worker/build.mjs` into a new assets directory, then use `stage-runtime.py` with the pinned local official Node archive and the matching Windows target. Stage into a new directory and copy its complete contents here before release packaging. The runtime manifest, JS modules, pinned Node executable and its license ship together. Neither application launch nor the staging tools download or install dependencies.

Release builds require `microscopy-runtime.json`. Development without it can use an explicitly configured canonical runtime manifest; otherwise the corresponding workspace operations report that the runtime is unavailable.
