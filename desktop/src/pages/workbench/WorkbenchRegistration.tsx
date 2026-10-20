import WorkbenchImageSelector, { useWorkbenchImage } from "./WorkbenchImageSelector";
import { useEffect, useRef, useState } from "react";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import ScientificOutput from "./ScientificOutput";

type Selection = { channel: number; timeIndex: number; zProjection: "max" | "mean" | "middle" };
type Estimate = { inputFingerprint: string; shiftPx: { x: number; y: number }; quality: Record<string, unknown>;
  calibration: { status: string; notes: string[] }; convention: string };
type Preview = { dataUrl: string; fixedDataUrl: string; overlayDataUrl: string; [key: string]: unknown };
type Props = { snapshot: ProjectSnapshot; imageId: string; busy: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void> };
const defaults: Selection = { channel: 0, timeIndex: 0, zProjection: "max" };

export default function WorkbenchRegistration({ snapshot, imageId, busy, read, act }: Props) {
  const [fixedImageId, setFixedImageId] = useState("");
  const [movingImageId, setMovingImageId] = useState(imageId);
  const [fixedSelection, setFixedSelection] = useState<Selection>({ ...defaults });
  const [movingSelection, setMovingSelection] = useState<Selection>({ ...defaults });
  const [shift, setShift] = useState({ x: 0, y: 0 });
  const [upsampleFactor, setUpsampleFactor] = useState(10);
  const [maxShift, setMaxShift] = useState("");
  const [windowFunction, setWindowFunction] = useState("hann");
  const [interpolation, setInterpolation] = useState("linear");
  const [fillValue, setFillValue] = useState(0);
  const [name, setName] = useState("");
  const [estimate, setEstimate] = useState<Estimate>();
  const [preview, setPreview] = useState<Preview>();
  const [display, setDisplay] = useState<"overlayDataUrl" | "fixedDataUrl" | "dataUrl">("overlayDataUrl");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const epoch = useRef(0);
  const fixed = useWorkbenchImage(fixedImageId);
  const moving = useWorkbenchImage(movingImageId);
  const inputs = { fixedImageId, movingImageId, fixedSelection, movingSelection };
  const transform = { ...inputs, shiftPx: shift, interpolation, fillValue,
    ...(estimate ? { expectedInputFingerprint: estimate.inputFingerprint } : {}) };
  useEffect(() => {
    setMovingImageId(imageId); setMovingSelection({ ...defaults });
    setFixedImageId((id) => id || imageId);
  }, [imageId]);
  useEffect(() => {
    epoch.current++; setEstimate(undefined); setPreview(undefined); setError(""); setLoading(false);
    return () => { epoch.current++; };
  }, [fixedImageId, movingImageId, fixedSelection, movingSelection, snapshot.project.revision]);
  useEffect(() => {
    epoch.current++; setPreview(undefined); setLoading(false);
  }, [shift.x, shift.y, interpolation, fillValue]);
  const inspect = async (operation: "registration.estimate" | "registration.preview") => {
    const generation = ++epoch.current; setLoading(true); setError("");
    try {
      if (operation === "registration.estimate") {
        const result = await read<Estimate>(operation, { ...inputs, upsampleFactor, window: windowFunction,
          ...(maxShift.trim() ? { maxShiftPx: Number(maxShift) } : {}) });
        if (generation === epoch.current) { setEstimate(result); setShift(result.shiftPx); setPreview(undefined); }
      } else {
        const result = await read<Preview>(operation, transform);
        if (generation === epoch.current) setPreview(result);
      }
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  const canEstimate = fixed && moving && fixed.width === moving.width && fixed.height === moving.height
    && fixed.width * fixed.height <= 4_000_000;
  return <div className="workbench-automation"><details><summary>Image registration</summary>
    <p>Estimate or enter a 2D translation, preview alignment, then save the moving image in the reference grid.
      Saved outputs retain the source images, transform, interpolation and valid support. Existing masks are not transferred.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <fieldset disabled={busy || loading}>
      <div className="workbench-editor-grid">{(["fixed", "moving"] as const).map((role) => {
        const value = role === "fixed" ? fixedImageId : movingImageId;
        const selected = role === "fixed" ? fixed : moving;
        const selection = role === "fixed" ? fixedSelection : movingSelection;
        const setSelection = role === "fixed" ? setFixedSelection : setMovingSelection;
        return <div key={role}>
          <WorkbenchImageSelector label={role === "fixed" ? "Reference image and output grid" : "Moving image"}
            selectedIds={value ? [value] : []} disabled={busy || loading} onChange={ids => {
              (role === "fixed" ? setFixedImageId : setMovingImageId)(ids[0] ?? ""); setSelection({ ...defaults });
            }} />
          <label>Channel<select value={selection.channel} onChange={(event) => setSelection((old) => ({ ...old, channel: Number(event.target.value) }))}>
            {Array.from({ length: selected?.channels ?? 1 }, (_, index) => <option key={index} value={index}>Channel {index + 1}</option>)}
          </select></label>
          <label>Time point<input type="number" min={1} max={selected?.timeCount ?? 1} step={1} value={selection.timeIndex + 1}
            onChange={(event) => setSelection((old) => ({ ...old, timeIndex: Number(event.target.value) - 1 }))} /></label>
          <label>Z projection<select value={selection.zProjection} onChange={(event) => setSelection((old) => ({
            ...old, zProjection: event.target.value as Selection["zProjection"],
          }))}><option value="max">Maximum</option><option value="mean">Mean</option><option value="middle">Middle plane</option></select></label>
        </div>;
      })}</div>
      <div className="workbench-editor-grid">
        <div><h3>Estimate translation</h3>
          <label>Subpixel refinement<input type="number" min={1} max={100} step={1} value={upsampleFactor} onChange={(event) => setUpsampleFactor(Number(event.target.value))} /></label>
          <label>Edge window<select value={windowFunction} onChange={(event) => setWindowFunction(event.target.value)}>
            <option value="hann">Hann</option><option value="none">None</option>
          </select></label>
          <label>Maximum shift (px, optional)<input type="number" min={.001} step="any" value={maxShift} onChange={(event) => setMaxShift(event.target.value)} /></label>
          <button className="cc-btn" disabled={!canEstimate} onClick={() => void inspect("registration.estimate")}>Estimate alignment</button>
          {!canEstimate ? <p>Estimation needs equal image dimensions and at most four million pixels. Enter a known translation to apply it to a larger image.</p> : null}
        </div>
        <div><h3>Apply translation</h3>
          <label>Horizontal shift (px, positive moves right)<input type="number" step="any" value={shift.x} onChange={(event) => setShift((old) => ({ ...old, x: Number(event.target.value) }))} /></label>
          <label>Vertical shift (px, positive moves down)<input type="number" step="any" value={shift.y} onChange={(event) => setShift((old) => ({ ...old, y: Number(event.target.value) }))} /></label>
          <label>Interpolation<select value={interpolation} onChange={(event) => setInterpolation(event.target.value)}>
            <option value="linear">Linear</option><option value="nearest">Nearest pixel</option>
          </select></label>
          <label>Fill outside source<input type="number" step="any" value={fillValue} onChange={(event) => setFillValue(Number(event.target.value))} /></label>
          <label>Registered image name<input value={name} maxLength={200} placeholder="Use moving image name" onChange={(event) => setName(event.target.value)} /></label>
          <div className="workbench-actions">
            <button className="cc-btn" disabled={!fixed || !moving} onClick={() => void inspect("registration.preview")}>Preview alignment</button>
            <button className="cc-btn" disabled={!fixed || !moving} onClick={() => void act("registration.apply", {
              ...transform, ...(name.trim() ? { name: name.trim() } : {}),
            })}>Save registered image</button>
          </div>
        </div>
      </div>
    </fieldset>
    {estimate ? <><h3>Estimator result</h3><ScientificOutput output={{ ...estimate.quality, estimatedShiftPx: estimate.shiftPx,
      calibration: estimate.calibration, notes: [estimate.convention, ...estimate.calibration.notes] }} /></> : null}
    {preview ? <div className="workbench-registration-preview">
      <label>Alignment view<select value={display} onChange={(event) => setDisplay(event.target.value as typeof display)}>
        <option value="overlayDataUrl">Overlay</option><option value="fixedDataUrl">Reference</option><option value="dataUrl">Registered moving image</option>
      </select></label>
      <img src={preview[display]} alt="Unsaved translation-registration preview" />
      <ScientificOutput output={Object.fromEntries(Object.entries(preview).filter(([key]) => !key.endsWith("DataUrl") && key !== "dataUrl"))} />
    </div> : null}
  </details></div>;
}
