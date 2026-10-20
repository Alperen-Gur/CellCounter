import { useEffect, useRef, useState } from "react";
import type { AnalysisParameters, WorkbenchImage } from "../../../../shared/workbench/protocol";
import type { VolumeWorkflowConfiguration } from "../../../../shared/workbench/volumeProtocol";
import type { LabelImportPreview } from "../../../../shared/workbench/labelImportProtocol";
import ScientificOutput from "./ScientificOutput";

type Props = {
  image?: WorkbenchImage; revision: number; parameters: AnalysisParameters;
  busy: boolean; volumeMode: boolean; volume?: VolumeWorkflowConfiguration;
  read: <T>(operation: string, args: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void>;
  chooseFile: (selected: (path: string) => void) => Promise<void>;
};

export default function WorkbenchLabelImport({ image, revision, parameters, busy, volumeMode, volume, read, act, chooseFile }: Props) {
  const [path, setPath] = useState("");
  const [preview, setPreview] = useState<LabelImportPreview>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const epoch = useRef(0);
  const selection = volumeMode && volume
    ? { target: "volume", timeIndex: volume.timeIndex, channel: volume.channel }
    : { target: "plane", sourceParameters: { channel: parameters.channel, zProjection: parameters.zProjection } };
  const args = { imageId: image?.id, path, ...selection };

  useEffect(() => {
    epoch.current++; setPreview(undefined); setLoading(false); setError("");
    return () => { epoch.current++; };
  }, [path, image?.id, revision, volumeMode, volume?.timeIndex, volume?.channel, parameters.channel, parameters.zProjection]);
  const inspect = async () => {
    const generation = ++epoch.current; setLoading(true); setError(""); setPreview(undefined);
    try {
      const result = await read<LabelImportPreview>("mask.import.preview", { ...args, cellLimit: 200 });
      if (generation === epoch.current) setPreview(result);
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  const choose = () => {
    const generation = epoch.current;
    return chooseFile((chosen) => {
      if (generation === epoch.current) { setPath(chosen); setPreview(undefined); }
    });
  };
  return <div className="workbench-automation"><details><summary>Import object labels</summary>
    <p>Bring an exact instance mask from another analysis tool into the selected image.
      Use integer TIFF or NumPy NPY labels: zero is background and each positive number identifies an object.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <fieldset disabled={busy || loading || !image}>
      <button className="cc-btn" onClick={() => void choose()}>Choose label file…</button>
      {path ? <p className="workbench-project-path">{path}</p> : null}
      {image ? <p>{image.name} · {volumeMode
        ? `full volume at time ${(volume?.timeIndex ?? 0) + 1}, channel ${(volume?.channel ?? 0) + 1}`
        : `channel ${parameters.channel + 1}, ${parameters.zProjection} Z selection`}</p> : null}
      <div className="workbench-actions">
        <button className="cc-btn" disabled={!path || (volumeMode && !volume)} onClick={() => void inspect()}>
          Preview imported labels
        </button>
        <button className="cc-btn" disabled={!preview} onClick={() => {
          if (preview) void act("mask.import.run", { ...args, previewFingerprint: preview.previewFingerprint });
        }}>Apply imported labels</button>
      </div>
    </fieldset>
    {preview ? <div className="workbench-recipe-preview">
      {preview.overlayDataUrl || preview.dataUrl ? <img src={preview.overlayDataUrl ?? preview.dataUrl}
        alt={`Unsaved imported instance labels${volumeMode ? ", middle XY plane of the full volume" : ""}`} /> : null}
      <p>{preview.summary.labelCount.toLocaleString()} objects · {preview.summary.foregroundSampleCount.toLocaleString()} labeled samples.
        {preview.summary.labelCount === 0 ? " Applying this empty mask removes all current objects from this selection." : ""}</p>
      <ScientificOutput output={{ source: preview.source, selection: preview.selection, ...preview.summary }} />
    </div> : null}
    <p>Dimensions must match exactly. Applying replaces the selected saved mask and recomputes its measurements;
      prior masks remain available through Undo. Create a new mask layer first to keep both versions side by side.</p>
  </details></div>;
}
