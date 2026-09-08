# CellCounter Web 0.2.1 preview

The introduction is now a continuous landing page. One full-viewport particle
illustration changes with native scrolling, alongside four concise sections
about inspecting images, separating cells, understanding measurements and
starting work. It is not contained in a panel.

- Muted blue-gray points on a cool-white surface follow the scientific design
  guide, with readable typography and generous spacing.
- The illustration morphs from a membrane-like cell to separate objects,
  boundaries and an ordered spatial field. These forms are decorative,
  explicitly labeled illustrations; they are not biological measurements.
- Direct section links, rotation controls, Pause and Open workspace remain
  accessible. Reduced motion uses static stages, and ordinary scrolling stays
  native without a wheel trap or forced pause.
- Mobile composition reserves clear space for text and controls. The renderer
  limits particle count, caps pixel ratio and physical canvas area, pauses in
  background tabs, and releases its resources on workspace entry.

The previous release’s classical segmentation, saved preview/processing/review
workflow, local-only storage, blue workbench and licensed Lucide icons remain.
Learned browser models and the documented native-platform gaps are still
unavailable; this design update does not imply full feature parity.

See the [landing-page design guide](../design/landing-page-guide.md) and
[browser guide](../WEB.md). Download the static PWA archive and checksum from
this release and serve the files over HTTPS (or localhost). This is a release
archive, not a new hosted analysis service.
