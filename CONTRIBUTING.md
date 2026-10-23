# Contributing to CellCounter

Bug reports, documentation improvements and focused pull requests are welcome.
CellCounter is a scientific tool: changes should make behavior clear and retain
source, measurement and correction provenance.

## Report a problem

Open a [GitHub issue](https://github.com/Alperen-Gur/CellCounter/issues) with:

- Your operating system and CellCounter version.
- The steps you followed, expected behavior and observed result.
- The operation, file format or model involved, and any relevant error message.
- A minimal example using synthetic or openly redistributable data, when possible.

Review diagnostic reports, logs and screenshots before sharing them. Remove
personal information, credentials, private paths and sensitive research or
patient data. Do not upload an entire project when a small example is sufficient.

## Repository structure

| Directory | Contents |
| --- | --- |
| `CellCounting/` | Native macOS SwiftUI application and its library services |
| `desktop/` | Windows React/Tauri application and native backend |
| `web/` | Browser PWA and worker-based processing |
| `shared/python/` | Scientific Workbench runtime, CLI, Python SDK and MCP server |
| `shared/workbench/` | Typed operation contracts |
| `shared/microscopy/` | Portable microscopy workspace engine |
| `docs/` | Installation, features, architecture and usage guides |

Start with the [architecture guide](docs/ARCHITECTURE.md), then follow the
[macOS](docs/INSTALL.md), [Windows](desktop/README.md#development),
[browser](web/README.md#run-locally) or [Python SDK](shared/python/README.md)
instructions for the component you are changing.

## Prepare a pull request

Keep the change focused and explain the problem, resulting behavior and relevant
validation. Update the affected public documentation when behavior changes.
Include regression coverage when it meaningfully exercises a bug or scientific
contract; select checks appropriate to the component and change.

Use small synthetic fixtures for tests. Do not commit microscopy datasets, model
weights, generated environments, build output, credentials or private working
material. Preserve licenses and attribution for dependencies and assets. Optional
models may have terms that differ from CellCounter's own license; consult
[third-party notices](THIRD_PARTY_LICENSES.md) before adding or redistributing them.

Changes to Workbench operations should retain the same semantics across the GUI,
CLI, SDK and MCP clients. Document relevant source/calibration limits, revision
behavior and permissions rather than treating a new interface entry as evidence
of scientific validation.

By contributing, you agree to license your contribution under the
[MIT License](LICENSE).
