import { useEffect, useRef, useState } from "react";
import type { AnalysisParameters, WorkbenchImage } from "../../../../shared/workbench/protocol";
import type { PreprocessingDraftStep } from "../../../../shared/workbench/preprocessingProtocol";
import { recipeFromDraft, recipeIsValid } from "../../../../shared/workbench/preprocessingProtocol";
import type { VolumeWorkflowConfiguration } from "../../../../shared/workbench/volumeProtocol";
import PreprocessingRecipeEditor from "./PreprocessingRecipeEditor";
import usePreprocessingCatalogue from "./usePreprocessingCatalogue";
import ScientificOutput from "./ScientificOutput";

type Preview = { dataUrl: string; previewIndex: number; summary: unknown };
type Props = { image?: WorkbenchImage; revision: number; parameters: AnalysisParameters; busy: boolean;
  volumeMode: boolean; volume?: VolumeWorkflowConfiguration;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void> };

export default function WorkbenchPreprocessing({ image, revision, parameters, busy, volumeMode, volume, read, act }: Props) {
  const { catalogue, error: catalogueError, retry: retryCatalogue } = usePreprocessingCatalogue(read);
  const [steps, setSteps] = useState<PreprocessingDraftStep[]>([]);
  const [name, setName] = useState("");
  const [preview, setPreview] = useState<Preview>();
  const [lineage, setLineage] = useState<unknown>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const epoch = useRef(0);
  const dimension = volumeMode ? 3 : 2;
  useEffect(() => {
    epoch.current++; setPreview(undefined); setLineage(undefined); setLoading(false); setError("");
    setName(image ? `${image.name.slice(0, 160)} · processed` : "");
    return () => { epoch.current++; };
  }, [image?.id, revision, volumeMode, volume?.timeIndex, volume?.channel, parameters.channel, parameters.zProjection]);
  const change = (next: PreprocessingDraftStep[]) => { epoch.current++; setSteps(next); setPreview(undefined); setLoading(false); setError(""); };
  const args = {
    imageId: image?.id, recipe: recipeFromDraft(steps),
    ...(volumeMode && volume ? { target: "volume", timeIndex: volume.timeIndex, channel: volume.channel }
      : { target: "plane", sourceParameters: parameters }),
  };
  const valid = image && (!volumeMode || volume) && recipeIsValid(steps, catalogue, dimension);
  const inspect = async (operation: string, values: Record<string, unknown>) => {
    const generation = ++epoch.current; setLoading(true); setError("");
    try {
      const result = await read<Preview>(operation, values);
      if (epoch.current === generation) {
        if (operation === "preprocessing.preview") setPreview(result);
        else setLineage(result);
      }
    } catch (cause) { if (epoch.current === generation) setError(String(cause)); }
    finally { if (epoch.current === generation) setLoading(false); }
  };
  return <div className="workbench-automation"><details><summary>Preprocessing recipes</summary>
    <p>Process the selected channel and {volumeMode ? "time-point volume" : "projection"} into a new image.
      Recipes retain the original image, calibration and complete filter settings.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {catalogueError ? <p className="workbench-error" role="alert">{catalogueError}{" "}
      <button type="button" className="cc-btn" disabled={busy} onClick={retryCatalogue}>Retry filter catalogue</button></p> : null}
    <fieldset disabled={busy || loading || !image}>
      <PreprocessingRecipeEditor catalogue={catalogue} steps={steps} dimension={dimension} onChange={change} />
      <label>Derived image name<input value={name} maxLength={200} onChange={(event) => setName(event.target.value)} /></label>
      <div className="workbench-actions">
        <button className="cc-btn" disabled={!valid} onClick={() => void inspect("preprocessing.preview", args)}>Preview recipe</button>
        <button className="cc-btn" disabled={!valid || !name.trim()} onClick={() => void act("preprocessing.run", { ...args, name: name.trim() })}>Create processed image</button>
        <button className="cc-btn" onClick={() => void inspect("preprocessing.inspect", { imageId: image?.id })}>Inspect source lineage</button>
      </div>
    </fieldset>
    {preview ? <div className="workbench-recipe-preview">
      <img src={preview.dataUrl} alt={`Unsaved preprocessing preview${volumeMode ? `, XY plane ${preview.previewIndex + 1}` : ""}`} />
      <ScientificOutput output={preview.summary} />
    </div> : null}
    {lineage ? <ScientificOutput output={lineage} /> : null}
    <p>Processed intensity values are labeled separately in measurements and exports.</p>
  </details></div>;
}
