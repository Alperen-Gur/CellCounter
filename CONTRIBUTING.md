# Contributing to CellCounter

Bug reports, documentation improvements and focused pull requests are welcome.

## Report a problem

Open a [GitHub issue](https://github.com/Alperen-Gur/CellCounter/issues) with:

- Your operating system and CellCounter version.
- Steps to reproduce the problem, what you expected and what happened.
- The file format, model or operation involved, plus any error message.
- A small example using synthetic or shareable data, if possible.

Remove credentials and private data from logs or screenshots before sharing.

## Repository structure

| Directory | Contents |
| --- | --- |
| `CellCounting/` | Native macOS app |
| `desktop/` | Windows React/Tauri app |
| `web/` | Browser PWA and workers |
| `shared/python/` | Workbench runtime, CLI, Python SDK and MCP server |
| `shared/workbench/` | Typed operation contracts |
| `shared/microscopy/` | Shared microscopy workspace engine |
| `docs/` | Installation, features, architecture and usage guides |

Start with the [architecture guide](docs/ARCHITECTURE.md), then follow the
[macOS](docs/INSTALL.md), [Windows](desktop/README.md#development),
[browser](web/README.md#run-locally) or [Python SDK](shared/python/README.md)
setup for the component you're changing.

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
