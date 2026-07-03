# CellCounter desktop

Cross-platform rebuild of CellCounter, a desktop application that wraps
[Cellpose](https://github.com/MouseLand/cellpose) to count and size-classify
cells in microscopy images. This directory targets Windows, Linux, and macOS.

The top-level `CellCounting/` directory contains the original, stable native
macOS app written in Swift. This `desktop/` build is a separate implementation
that brings the same workflow to all three platforms. See the top-level
`README.md` for the project as a whole.

## Status

Preview (version 0.1.0). The code compiles in CI on Windows, Linux, and macOS,
but it has not yet been runtime-verified on real data. Prebuilt installers are
published on the GitHub Releases page under `desktop-v*` tags.

## Tech stack

- Tauri v2 with a Rust backend (`src-tauri/`).
- React and TypeScript frontend built with Vite (`src/`).
- A Python sidecar that runs Cellpose (`python/`).

## Prerequisites

- Node.js (with npm).
- The Rust toolchain (`rustup`, which provides `cargo`). See the
  [Tauri v2 prerequisites](https://v2.tauri.app/start/prerequisites/) for the
  platform-specific system dependencies.
- [uv](https://docs.astral.sh/uv/) for the Python environment used by the
  Cellpose sidecar in `python/`.

## Development

Install the frontend dependencies, then start the app in development mode:

```
npm install
npm run tauri dev
```

`npm run tauri dev` starts the Vite dev server and launches the Tauri window.

## Build

Build the installers for the current platform:

```
npm run tauri build
```

This produces the native installers for the host operating system, for example
`.msi` and `.exe` on Windows and `.dmg` on macOS.

## Directory layout

- `src/` React and TypeScript frontend (Vite).
- `src-tauri/` Rust backend, Tauri configuration (`tauri.conf.json`), and
  bundled resources.
- `python/` Python sidecar that runs Cellpose, with its dependencies managed by
  uv (`pyproject.toml`, `uv.lock`).

## License

See the `LICENSE` file at the top level of the repository.
