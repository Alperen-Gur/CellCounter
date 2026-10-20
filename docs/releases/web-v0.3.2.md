# CellCounter Web 0.3.2 preview

This maintenance release updates the shared microscopy workspace engine and its production packaging.

- Shared sampled planes and stitched outputs retain an explicit support mask, so uncovered regions are distinguished from observed zero intensity.
- Workspace replay retains generated-plane positions and parent-transform information for consumers of the shared engine.
- Capability inventory checks now cover the existing browser editing, task routing and export surfaces. Build tooling and release checks are updated.

The browser remains a local static PWA. It does not include the desktop Python workbench, installed-app CLI/MCP server, proprietary readers, model training or validated learned-model weights. Existing browser format, memory and storage limits still apply. Serve the release archive from a web root over HTTPS or localhost; this release does not deploy a hosted service.

Production compilation, browser-domain automated tests, capability checks and archive-content checks were performed without launching a browser or doing visual verification. These checks do not establish biological accuracy. See the [browser guide](https://github.com/Alperen-Gur/CellCounter/blob/web-v0.3.2/docs/WEB.md).
