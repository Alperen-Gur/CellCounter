# CellCounter Windows desktop

This directory contains the Windows-native CellCounter 1.0.8 application: the
React interface hosted by Tauri 2 with a Rust persistence/export layer and
local Python model sidecars. The stable Swift application under
`CellCounting/` remains the macOS product.

The Windows release produces a WiX `.msi` and an NSIS setup `.exe`. End-user
installation, model setup, data locations, privacy, backup, and troubleshooting
are documented in [the Windows guide](../docs/WINDOWS.md).

## Development prerequisites

- Node.js 22.18.x with npm
- Rust 1.88 or newer
- The current Tauri 2 Windows prerequisites, including Microsoft C++ Build
  Tools and WebView2

The packaged app bundles a checksum-verified `uv` helper. Developers building
locally must place the target-specific executable at
`src-tauri/binaries/uv-x86_64-pc-windows-msvc.exe`, following Tauri's external
binary naming rule.

## Develop and verify

```powershell
npm ci
npm run verify:windows
npm run tauri -- dev
```

The portable checks verify the 1.0.8 identity, exact three-model catalog,
explicit parity inventory, bundle resources, native targets, Windows workflow,
and operator documentation.

## Build native installers

Run on 64-bit Windows after staging the `uv` sidecar:

```powershell
npm ci
npm run build
cargo test --manifest-path src-tauri/Cargo.toml --locked
npm run build:windows
node scripts/verify-windows-artifacts.mjs --write-checksums
```

The resulting artifacts are under `src-tauri/target/release/bundle/`:

- `msi/*.msi`
- `nsis/*-setup.exe`
- `SHA256SUMS.txt`

The dedicated Windows GitHub Actions workflow performs the same validation and
uploads unsigned installer artifacts without creating or modifying a GitHub
Release.

## Layout

- `src/` — React/TypeScript interface and portable kernels
- `src-tauri/` — Rust backend, capabilities, and native bundle configuration
- `python/` — locally executed Cellpose/StarDist sidecars
- `scripts/` — portable release and packaging assertions

## License

MIT; see the repository-level `LICENSE`.
