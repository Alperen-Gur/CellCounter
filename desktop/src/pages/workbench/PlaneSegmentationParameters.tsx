import type { AnalysisParameters } from "../../../../shared/workbench/protocol";

/** Shared classical controls for direct analysis and branching workflow nodes. */
export default function PlaneSegmentationParameters({ values, onChange }: { values: AnalysisParameters; onChange: (change: Partial<AnalysisParameters>) => void }) {
  return <><label>Threshold method<select value={values.method} onChange={event => onChange({ method: event.target.value as AnalysisParameters["method"] })}>
    <option value="otsu">Otsu</option><option value="triangle">Triangle</option><option value="li">Li minimum cross-entropy</option><option value="yen">Yen</option><option value="mean">Mean</option><option value="adaptive">Adaptive local Gaussian</option><option value="manual">Manual</option></select></label>
    {values.method === "manual" ? <label>Threshold (source intensity units)<input type="number" step="any" value={values.threshold ?? 0} onChange={event => onChange({ threshold: Number(event.target.value) })} /></label> : null}
    <label>Foreground polarity<select value={values.polarity} onChange={event => onChange({ polarity: event.target.value as AnalysisParameters["polarity"] })}><option value="bright">Brighter than background</option><option value="dark">Darker than background</option><option value="auto">Automatic background heuristic</option></select></label>
    {values.polarity === "auto" ? <small>Automatic polarity uses a median-background heuristic. Inspect the preview for repeated or ambiguous structures.</small> : null}
    {values.method === "adaptive" ? <><label>Local neighborhood (odd pixels)<input type="number" min={3} max={501} step={2} value={values.adaptiveBlockSize ?? 51} onChange={event => onChange({ adaptiveBlockSize: Number(event.target.value) })} /></label>
      <label>Local threshold offset<select value={values.adaptiveOffsetMode ?? "auto"} onChange={event => onChange({ adaptiveOffsetMode: event.target.value as "auto" | "manual" })}><option value="auto">Automatic residual estimate</option><option value="manual">Explicit offset</option></select></label>
      {values.adaptiveOffsetMode === "manual" ? <label>Offset (nonnegative source intensity units)<input type="number" min={0} step="any" value={values.adaptiveOffset ?? 0} onChange={event => onChange({ adaptiveOffset: Number(event.target.value) })} /></label> : null}
      <small>Local estimation requires a completely acquired rectangular region. Unsupported fill is excluded.</small>
    </> : null}
    <label>Minimum object area (pixels²)<input type="number" min={1} max={16000000} step={1} value={values.minAreaPx} onChange={event => onChange({ minAreaPx: Number(event.target.value) })} /></label>
    <label>Watershed seed spacing (pixels)<input type="number" min={1} max={4096} step={1} value={values.minDistancePx} onChange={event => onChange({ minDistancePx: Number(event.target.value) })} /></label>
    <label><input type="checkbox" checked={values.fillHoles ?? false} onChange={event => onChange({ fillHoles: event.target.checked })} /> Fill enclosed foreground holes before watershed</label></>;
}
