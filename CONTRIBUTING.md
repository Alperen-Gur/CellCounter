# Contributing to CellCounter

Bug reports, documentation improvements and focused pull requests are welcome.

## Report a problem

Open a [GitHub issue](https://github.com/Alperen-Gur/CellCounter/issues) with:

- Your operating system and CellCounter version.
- Steps to reproduce the problem, what you expected and what happened.
- The file format, model or operation involved, plus any error message.
- A small example using synthetic or shareable data, if possible.

Remove credentials and private data from logs or screenshots before sharing. A
[local diagnostics report](docs/INSTALL.md#optional-local-diagnostics) can help with
performance problems.

## Repository structure

| Directory | Contents |
| --- | --- |
| `CellCounting/` | Native macOS app (SwiftUI) and its Python detection scripts |
| `CellCountingTests/` | macOS app tests |
| `desktop/` | Windows app (React, TypeScript, Tauri) |
| `web/` | Browser PWA and workers |
| `shared/python/` | Workbench runtime, CLI, Python SDK and MCP server |
| `shared/workbench/` | Typed operation contracts |
| `shared/microscopy/`, `shared/microscopy-worker/`, `shared/viewer/` | Shared microscopy engine, its Node worker and the volume viewer |
| `docs/` | User guides, architecture and release notes |

Start with the [architecture guide](docs/ARCHITECTURE.md), then set up the component
you're changing: [macOS](#build-the-macos-app), [Windows](desktop/README.md#development),
[browser](web/README.md#run-locally) or [Python SDK](shared/python/README.md).

## Build the macOS app

You need macOS 15 or later, Xcode and Node.js. The app bundles a pinned Node runtime
for the shared microscopy engine, which must be staged before a full build:

1. Install the JavaScript dependencies and build the worker assets into a new folder:

   ```sh
   npm ci --prefix desktop --ignore-scripts
   node shared/microscopy-worker/build.mjs --output /tmp/microscopy-assets
   ```

2. Download the Node archive pinned in
   [`node-runtime.json`](shared/microscopy-worker/node-runtime.json) for each Mac
   architecture and stage it:

   ```sh
   python3 shared/microscopy-worker/stage-runtime.py --platform darwin-arm64 \
     --archive ~/Downloads/node-v24.22.0-darwin-arm64.tar.gz \
     --assets /tmp/microscopy-assets \
     --output shared/microscopy-worker/dist/darwin-arm64
   ```

   Repeat with `darwin-x64` for Intel.

3. Open `CellCounting.xcodeproj` and run the **CellCounting** scheme, or run the tests
   from Terminal:

   ```sh
   TEST_RUNNER_CELLCOUNTER_DATA_ROOT="$(mktemp -d)" xcodebuild test \
     -project CellCounting.xcodeproj -scheme CellCounting \
     -destination 'platform=macOS' -only-testing:CellCountingTests
   ```

Set `CELLCOUNTER_DATA_ROOT` to the absolute path of an empty folder when you run a
development build, so it works on its own data instead of your Default Library. App
preferences are still shared with an installed copy, which uses the same bundle
identifier. The `swift-build` job in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) is the
reference build.

## Prepare a pull request

Explain the problem, what changed and how you checked it. Keep the change focused
and update the relevant documentation. Add a regression test when it helps
protect against the bug returning.

Use small synthetic test fixtures. Keep datasets, model weights, environments,
build output, credentials and private working material out of Git. Preserve
licenses and attribution; check [third-party notices](THIRD_PARTY_LICENSES.md)
when adding dependencies or models.

Workbench operations should behave consistently across the GUI, CLI, SDK and
MCP clients. Keep request revisions, measurement history and permissions intact
when changing them.

Contributions are licensed under the [MIT License](LICENSE).
