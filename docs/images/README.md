# Screenshots for the README

Drop the files below into this folder, then uncomment the matching block in the
root `README.md` (search for `SCREENSHOTS`).

Capture on a Retina display, light appearance, with a real analysed batch open —
an empty app is worse than no screenshot. Crop to the window; no desktop
background, no menu bar.

| Filename | What to capture | Where it goes |
|---|---|---|
| `hero.png` | The Results screen with an image analysed: overlay on, cells outlined, the right sidebar showing counts and the size distribution. This is the single most important image in the repo — it is what a stranger judges the project by. | Directly under the badges |
| `assays.png` | The Results sidebar with an assay panel open and populated — marker-positive %, or the puncta panel with per-cell counts. Shows this is more than a counter. | "Measurements and assays" |
| `correction.png` | The editor mid-correction: the toolbar visible, a cell selected or being drawn. Shows the model output is editable. | "Correction, comparison, export" |
| `models.png` | The Models tab listing the installable detectors. | "Segmentation" |

Optional but high value:

| Filename | What to capture |
|---|---|
| `demo.gif` | 15–25 s: open folder → run detection → correct one cell → export. Keep it under ~5 MB. |

Once `hero.png` exists, the block in the root README becomes:

```html
<div align="center">
  <img src="docs/images/hero.png" alt="CellCounter results view" width="900">
</div>
```

Notes:

- Use PNG for stills. GitHub renders them at up to ~900 px wide in the README.
- If a screenshot shows patient-derived material, confirm it can be published
  before committing it — image data in a public repo is not retractable.
