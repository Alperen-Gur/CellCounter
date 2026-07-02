# Contributing

Thanks for taking a look. CellCounter is a research tool, and contributions —
bug reports, feature requests, pull requests — are welcome.

## Reporting a bug

Open an issue with:
- what you did, what you expected, and what happened instead
- your OS and app version
- if it's a detection/install problem, a screenshot of the install log or the
  detection overlay helps a lot (please make sure no patient data is visible)

## Development

The repository currently contains:
- `CellCounting/` — the native macOS (SwiftUI) app
- `CellCounting/python/` — the Python sidecar that runs Cellpose
- a cross-platform rebuild (Tauri + React) is being added under a separate
  directory; see the Roadmap in the README

Please don't commit:
- image data (patient or otherwise) — the `.gitignore` blocks common formats,
  but double-check
- model weights — they're downloaded at runtime, not vendored
- anything under AGPL — this project is MIT and needs to stay
  permissively licensed

## Pull requests

Keep them focused. If you're adding a feature, an issue to discuss it first
saves everyone time. By contributing you agree to license your contribution
under the MIT License.
