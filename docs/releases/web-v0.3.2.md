# CellCounter Web 0.3.2 preview

This maintenance release updates the shared microscopy workspace engine and its production packaging.

## Changes

- Sampled planes and stitched outputs keep a support mask, so uncovered regions are distinguished from observed zero intensity.
- Workspace replay keeps generated-plane positions and parent-transform information.
- Build tooling is updated.

## Install

Serve the release archive from a web root over HTTPS or localhost. The browser edition is a local static PWA; the Python Workbench, CLI and MCP server are part of the desktop apps. See the [browser guide](https://github.com/Alperen-Gur/CellCounter/blob/web-v0.3.2/docs/WEB.md).
