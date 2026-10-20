import WorkbenchImageSelector from "./WorkbenchImageSelector";
import { useEffect, useRef, useState } from "react";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import type { VolumePlane, VolumeWorkflowConfiguration } from "../../../../shared/workbench/volumeProtocol";
import type { MaskComparison } from "../../../../shared/workbench/comparisonProtocol";
import ScientificOutput from "./ScientificOutput";

type Props = { snapshot: ProjectSnapshot; imageId: string; busy: boolean; volumeMode: boolean;
  volume?: VolumeWorkflowConfiguration;
  read: <T>(operation: string, args: Record<string, unknown>) => Promise<T> };
const score = (value: number) => value.toLocaleString(undefined, { maximumFractionDigits: 4 });

export default function WorkbenchComparison({ snapshot, imageId, busy, volumeMode, volume, read }: Props) {
  const left = snapshot.images.find((image) => image.id === imageId);
  const [rightImageId, setRightImageId] = useState("");
  const [plane, setPlane] = useState<VolumePlane>("xy");
  const [index, setIndex] = useState("");
  const [result, setResult] = useState<MaskComparison>();
  const [display, setDisplay] = useState<"overlayDataUrl" | "dataUrl">("overlayDataUrl");
  const [page, setPage] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const epoch = useRef(0);
  const sliceCount = plane === "xy" ? left?.zCount ?? 1 : plane === "xz" ? left?.height ?? 1 : left?.width ?? 1;
  const validIndex = !index || (Number.isInteger(Number(index)) && Number(index) >= 1 && Number(index) <= sliceCount);
  const hasLeft = volumeMode ? Boolean(left?.volumeFrameCount) : left?.analysisRevision != null;

  useEffect(() => { setRightImageId(""); }, [imageId, volumeMode]);
  useEffect(() => { setIndex(""); }, [imageId, plane, volumeMode]);
  useEffect(() => {
    epoch.current++; setResult(undefined); setError(""); setLoading(false); setPage(0);
    return () => { epoch.current++; };
  }, [imageId, rightImageId, snapshot.project.revision, volumeMode, volume?.timeIndex, volume?.channel, plane, index]);

  const compare = async () => {
    const generation = ++epoch.current; setLoading(true); setError(""); setResult(undefined); setPage(0);
    try {
      const value = await read<MaskComparison>("mask.compare", { leftImageId: imageId, rightImageId,
        ...(volumeMode && volume ? { target: "volume", timeIndex: volume.timeIndex, channel: volume.channel,
          plane, ...(index ? { index: Number(index) - 1 } : {}) } : { target: "plane" }) });
      if (generation === epoch.current) setResult(value);
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };

  return <div className="workbench-automation"><details><summary>Compare saved masks</summary>
    <p>Compare two saved mask layers over the same source acquisition. Scores describe agreement between their
      objects; neither layer is assumed to be a reference annotation.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <fieldset disabled={busy || loading}>
      <p>First layer: {left?.name ?? "Choose an image"}</p>
      <WorkbenchImageSelector label="Second mask layer" selectedIds={rightImageId ? [rightImageId] : []}
        disabled={busy || loading || !left} onChange={ids => setRightImageId(ids[0] ?? "")}
        filters={{ sourceHash: left?.sourceHash, analysisTarget: volumeMode ? "volume" : "plane" }}
        eligible={candidate => candidate.id !== imageId && candidate.width === left?.width && candidate.height === left?.height}
        eligibilityNote="Choose another saved mask layer over the same source. Create an independent mask layer if no alternative exists." />
      {volumeMode ? <div className="workbench-editor-grid">
        <label>Display plane<select value={plane} onChange={(event) => setPlane(event.target.value as VolumePlane)}>
          <option value="xy">XY</option><option value="xz">XZ</option><option value="yz">YZ</option>
        </select></label>
        <label>Display slice (blank selects the middle)<input type="number" value={index} min={1} max={sliceCount} step={1}
          onChange={(event) => setIndex(event.target.value)} /></label>
      </div> : null}
      {volumeMode && volume ? <p>Time {volume.timeIndex + 1}, channel {volume.channel + 1}. Scores use the full volume.</p> : null}
      <button className="cc-btn" disabled={!hasLeft || !rightImageId || !validIndex || (volumeMode && !volume)}
        onClick={() => void compare()}>Compare current saved labels</button>
    </fieldset>
    {result ? <>
      <p>{result.left.name} (revision {result.left.analysisRevision}) and {result.right.name} (revision {result.right.analysisRevision})</p>
      <div className="workbench-table"><table><caption>Instance agreement at IoU ≥ 0.5</caption>
        <thead><tr><th>First layer</th><th>Second layer</th><th>Matched objects</th><th>Unmatched first</th><th>Unmatched second</th><th>Instance F1</th></tr></thead>
        <tbody><tr><td>{result.metrics.leftObjects}</td><td>{result.metrics.rightObjects}</td><td>{result.metrics.matchedObjects}</td>
          <td>{result.metrics.unmatchedLeft}</td><td>{result.metrics.unmatchedRight}</td><td>{score(result.metrics.instanceF1)}</td></tr></tbody>
      </table></div>
      <p>Foreground Dice: {score(result.metrics.foregroundDice)} · Foreground Jaccard: {score(result.metrics.foregroundJaccard)}
        {" · "}Instance Jaccard: {score(result.metrics.instanceJaccard)}</p>
      <div className="workbench-recipe-preview">
        <label>Display<select value={display} onChange={(event) => setDisplay(event.target.value as typeof display)}>
          <option value="overlayDataUrl">Disagreement overlay</option><option value="dataUrl">Source image</option>
        </select></label>
        <img src={result[display]} alt="Saved mask disagreement over the shared source" />
        <p>Cyan: first-layer foreground only. Magenta: second-layer foreground only. Green: foreground in both.
          {result.index == null ? "" : ` Display slice ${result.index + 1} of ${result.sliceCount}, ${result.plane?.toUpperCase()}.`}</p>
      </div>
      <details><summary>Object matches and unmatched labels</summary>
        <div className="workbench-table"><table><thead><tr><th>First label</th><th>Second label</th><th>IoU</th></tr></thead>
          <tbody>{result.pairs.slice(page * 100, (page + 1) * 100).map((pair) => <tr key={`${pair.leftLabelId}:${pair.rightLabelId}`}>
            <td>{pair.leftLabelId}</td><td>{pair.rightLabelId}</td><td>{score(pair.iou)}</td>
          </tr>)}</tbody></table></div>
        <div className="workbench-actions">
          <button className="cc-btn" disabled={page === 0} onClick={() => setPage((value) => value - 1)}>Previous 100</button>
          <span>Page {page + 1}</span>
          <button className="cc-btn" disabled={(page + 1) * 100 >= result.pairs.length} onClick={() => setPage((value) => value + 1)}>Next 100</button>
        </div>
        <p>Unmatched first-layer labels: {result.unmatchedLeftLabelIds.join(", ") || "None"}.</p>
        <p>Unmatched second-layer labels: {result.unmatchedRightLabelIds.join(", ") || "None"}.</p>
        {result.truncated ? <p>Label lists are limited to 1,000 entries each. Scores include every object.</p> : null}
      </details>
      <p>{result.notes.join(" ")}</p>
      <ScientificOutput output={{ selection: result.selection, firstLayerParameters: result.left.parameters,
        secondLayerParameters: result.right.parameters }} />
    </> : null}
  </details></div>;
}
