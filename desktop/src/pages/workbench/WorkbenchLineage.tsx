import { useEffect, useRef, useState } from "react";
import type { LineageExportArguments, LineageExportFormat, LineageExportFormatId, LineageGraph, LineageNode } from "../../../../shared/workbench/lineageProtocol";
import ScientificOutput from "./ScientificOutput";
import WorkbenchTemporal from "./WorkbenchTemporal";

type Props = { imageId: string; channel: number; timeIndex: number; timeCount: number; revision: number; busy: boolean;
  read: <T>(operation: string, args: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void>;
  runRead: (action: () => Promise<void>) => Promise<void>;
  exportLineage: (format: LineageExportFormat, args: LineageExportArguments) => Promise<void> };
type Candidate = { parent: { timeIndex: number; labelId: number }; daughters: { timeIndex: number; labelId: number }[];
  [key: string]: unknown };
type Suggestions = { candidates: Candidate[]; [key: string]: unknown };
const fmt = (value: number | null) => value == null ? "—" : value.toLocaleString(undefined, { maximumFractionDigits: 3 });

export default function WorkbenchLineage({ imageId, channel, timeIndex, timeCount, revision, busy, read, act, runRead, exportLineage }: Props) {
  const [expanded, setExpanded] = useState(false);
  const [graph, setGraph] = useState<LineageGraph>();
  const [loadedRevision, setLoadedRevision] = useState<number>();
  const [exportFormats, setExportFormats] = useState<LineageExportFormat[]>([]);
  const [exportFormat, setExportFormat] = useState<LineageExportFormatId>("graph-json");
  const [reading, setReading] = useState(false);
  const [error, setError] = useState("");
  const [reason, setReason] = useState("");
  const [parentTime, setParentTime] = useState(timeIndex);
  const [daughterTime, setDaughterTime] = useState(Math.min(timeCount - 1, timeIndex + 1));
  const [parentLabel, setParentLabel] = useState(1);
  const [daughters, setDaughters] = useState<[number, number]>([1, 2]);
  const [replace, setReplace] = useState(false);
  const [divisionId, setDivisionId] = useState("");
  const [clickTarget, setClickTarget] = useState<"parent" | "daughter1" | "daughter2">("parent");
  const [maxDistance, setMaxDistance] = useState(20);
  const [units, setUnits] = useState<"voxel" | "um">("voxel");
  const [minRatio, setMinRatio] = useState(.5);
  const [maxRatio, setMaxRatio] = useState(2);
  const [suggestions, setSuggestions] = useState<Suggestions>();
  const [page, setPage] = useState(0);
  const epoch = useRef(0);
  const latest = useRef(read); latest.current = read;
  const selection = { imageId, channel };
  const editable = graph?.status === "current" && loadedRevision === revision && !busy && !reading;
  const selectedExport = exportFormats.find((format) => format.id === exportFormat);
  const displayedTracks = graph?.tracks.slice(page * 100, (page + 1) * 100) ?? [];
  const rowByTrack = new Map(displayedTracks.map((track, index) => [track.id, index]));
  const perTrackLimit = Math.max(2, Math.floor(5000 / Math.max(1, displayedTracks.length)));
  const shownNodes = (observations: LineageNode[]) => observations.length <= perTrackLimit ? observations
    : Array.from({ length: perTrackLimit }, (_, index) => observations[Math.round(index / (perTrackLimit - 1) * (observations.length - 1))]);
  const timeLabels = [...new Set(Array.from({ length: Math.min(9, timeCount) }, (_, index) =>
    Math.round(index / Math.max(1, Math.min(9, timeCount) - 1) * (timeCount - 1))))];
  const width = 1000;
  const height = Math.max(120, (displayedTracks.length + 1) * 36);
  const position = (node: LineageNode, row: number) => ({
    x: 85 + node.timeIndex / Math.max(1, timeCount - 1) * (width - 110), y: 35 + row * 36,
  });
  useEffect(() => {
    const generation = ++epoch.current;
    setSuggestions(undefined); setError(""); setReading(false); setLoadedRevision(undefined);
    if (!expanded || busy) return;
    setReading(true);
    void latest.current<LineageGraph>("lineage.get", { imageId, channel }).then((result) => {
      if (epoch.current === generation) {
        setGraph(result); setLoadedRevision(revision);
        setPage((value) => Math.min(value, Math.max(0, Math.ceil(result.tracks.length / 100) - 1)));
      }
    }).catch((cause) => { if (epoch.current === generation) { setError(String(cause)); setGraph(undefined); } })
      .finally(() => { if (epoch.current === generation) setReading(false); });
    return () => { epoch.current++; };
  }, [expanded, imageId, channel, revision, busy]);
  useEffect(() => {
    let active = true;
    if (!expanded || exportFormats.length || busy) return;
    void latest.current<{ formats: LineageExportFormat[] }>("lineage.export.catalogue", {})
      .then((result) => { if (active) setExportFormats(result.formats); })
      .catch((cause) => { if (active) setError(String(cause)); });
    return () => { active = false; };
  }, [expanded, exportFormats.length, busy]);
  const useNode = (node: LineageNode) => {
    if (!editable) return;
    if (clickTarget === "parent") { setParentTime(node.timeIndex); setParentLabel(node.labelId); }
    else { setDaughterTime(node.timeIndex); setDaughters((old) => clickTarget === "daughter1" ? [node.labelId, old[1]] : [old[0], node.labelId]); }
  };
  const suggest = async () => {
    const generation = ++epoch.current; setReading(true); setError(""); setSuggestions(undefined);
    try {
      const result = await read<Suggestions>("lineage.suggest", { ...selection, parentTimeIndex: parentTime,
        daughterTimeIndex: daughterTime, maxDistance, units, minCombinedVolumeRatio: minRatio, maxCombinedVolumeRatio: maxRatio, limit: 30 });
      if (epoch.current === generation) setSuggestions(result);
    } catch (cause) { if (epoch.current === generation) setError(String(cause)); }
    finally { if (epoch.current === generation) setReading(false); }
  };
  const setDivision = () => act("lineage.division.set", { ...selection, parentTimeIndex: parentTime, parentLabelId: parentLabel,
    daughterTimeIndex: daughterTime, daughterLabelIds: daughters, replaceExisting: replace, reason: reason.trim(),
    ...(divisionId ? { divisionId } : {}) });
  return <div className="workbench-automation workbench-lineage"><details onToggle={(event) => setExpanded(event.currentTarget.open)}>
    <summary>Lineages and divisions</summary>
    <p>Preview temporal inference or start from current one-to-one tracks, then record parent/daughter relationships.
      Changes retain graph history and can be undone. Source-mask, calibration or base-track changes mark the graph stale.</p>
    <WorkbenchTemporal imageId={imageId} channel={channel} timeIndex={timeIndex} timeCount={timeCount}
      revision={revision} busy={busy} read={read} act={act} runRead={runRead} />
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {graph?.status === "stale" ? <p className="workbench-error">This graph refers to earlier inputs. Its history remains available; initialize from current tracks before further corrections.</p> : null}
    <div className="workbench-actions">
      <button className="cc-btn" disabled={busy || reading || timeCount < 2} onClick={() => void act("lineage.initialize", {
        ...selection, ...(reason.trim() ? { reason: reason.trim() } : {}),
      })}>{graph?.status === "none" || !graph ? "Initialize from current tracks" : "Initialize a new graph from current tracks"}</button>
      <button className="cc-btn" disabled={!editable || !graph?.undoAvailable || !reason.trim()} onClick={() => void act("lineage.undo", {
        ...selection, reason: reason.trim(),
      })}>Undo graph correction</button>
    </div>
    <label>Reason for correction<input value={reason} maxLength={2000} onChange={(event) => setReason(event.target.value)} /></label>
    {graph && graph.status !== "none" ? <>
      <ScientificOutput output={graph.summary} />
      <fieldset disabled={!editable}>
        <legend>Export lineage results</legend>
        <label>Format<select value={exportFormat} onChange={(event) => setExportFormat(event.target.value as LineageExportFormatId)}>
          {exportFormats.map((format) => <option key={format.id} value={format.id}>{format.name}</option>)}
        </select></label>
        {selectedExport ? <p>{selectedExport.description}</p> : null}
        <button className="cc-btn" disabled={!selectedExport} onClick={() => {
          if (selectedExport) void exportLineage(selectedExport, { ...selection, format: selectedExport.id });
        }}>Export saved graph…</button>
        <p>Exports use the current saved graph and retain its revision and source labels. Missing calibration stays unknown.</p>
      </fieldset>
      <div className="workbench-editor-grid">
        <fieldset disabled={!editable}>
          <h3>Parent and daughters</h3>
          <label>Next graph click fills<select value={clickTarget} onChange={(event) => setClickTarget(event.target.value as typeof clickTarget)}>
            <option value="parent">Parent</option><option value="daughter1">First daughter / continuation target</option><option value="daughter2">Second daughter</option>
          </select></label>
          <label>Parent time point<input type="number" min={1} max={timeCount} step={1} value={parentTime + 1} onChange={(event) => setParentTime(Number(event.target.value) - 1)} /></label>
          <label>Parent object label<input type="number" min={1} step={1} value={parentLabel} onChange={(event) => setParentLabel(Number(event.target.value))} /></label>
          <label>Daughter time point<input type="number" min={1} max={timeCount} step={1} value={daughterTime + 1} onChange={(event) => setDaughterTime(Number(event.target.value) - 1)} /></label>
          {daughters.map((label, index) => <label key={index}>Daughter {index + 1} label<input type="number" min={1} step={1} value={label}
            onChange={(event) => setDaughters((old) => index === 0 ? [Number(event.target.value), old[1]] : [old[0], Number(event.target.value)])} /></label>)}
          <label>Division to update<select value={divisionId} onChange={(event) => {
            setDivisionId(event.target.value);
            const division = graph.divisions.find((item) => item.id === event.target.value);
            if (division) {
              setParentTime(division.parent.timeIndex); setParentLabel(division.parent.labelId);
              setDaughterTime(division.daughters[0].timeIndex); setDaughters([division.daughters[0].labelId, division.daughters[1].labelId]);
            }
          }}><option value="">Create a new division</option>{graph.divisions.map((division) =>
            <option key={division.id} value={division.id}>Time {division.parent.timeIndex + 1} · parent {division.parent.labelId} → {division.daughters.map((node) => node.labelId).join(", ")}</option>)}</select></label>
          <label className="workbench-inline"><input type="checkbox" checked={replace} onChange={(event) => setReplace(event.target.checked)} />Replace conflicting existing links</label>
          <div className="workbench-actions">
            <button className="cc-btn" disabled={!reason.trim() || daughterTime <= parentTime || daughters[0] === daughters[1]}
              onClick={() => void setDivision()}>{divisionId ? "Save division correction" : "Record division"}</button>
            <button className="cc-btn" disabled={!divisionId || !reason.trim()} onClick={() => void act("lineage.division.remove", {
              ...selection, divisionId, reason: reason.trim(),
            })}>Remove selected division</button>
          </div>
          <p>Continuation actions use the parent and first daughter fields.</p>
          <div className="workbench-actions">
            {(["link", "unlink"] as const).map((operation) => <button key={operation} className="cc-btn" disabled={!reason.trim() || daughterTime <= parentTime}
              onClick={() => void act(`lineage.${operation}`, { ...selection, sourceTimeIndex: parentTime, sourceLabelId: parentLabel,
                targetTimeIndex: daughterTime, targetLabelId: daughters[0], reason: reason.trim() })}>{operation === "link" ? "Link continuation" : "Unlink continuation"}</button>)}
          </div>
        </fieldset>
        <fieldset disabled={!editable}>
          <h3>Find division candidates</h3>
          <p>Search the parent and daughter time points above. Candidates describe geometry and need an explicit decision.</p>
          <label>Maximum parent/daughter distance<input type="number" min={.001} value={maxDistance} onChange={(event) => setMaxDistance(Number(event.target.value))} /></label>
          <label>Distance units<select value={units} onChange={(event) => setUnits(event.target.value as typeof units)}>
            <option value="voxel">Voxels</option><option value="um">Micrometres</option>
          </select></label>
          <label>Minimum combined daughter/parent volume<input type="number" min={0} step="any" value={minRatio} onChange={(event) => setMinRatio(Number(event.target.value))} /></label>
          <label>Maximum combined daughter/parent volume<input type="number" min={0} step="any" value={maxRatio} onChange={(event) => setMaxRatio(Number(event.target.value))} /></label>
          <button className="cc-btn" disabled={daughterTime <= parentTime} onClick={() => void suggest()}>Find candidates</button>
        </fieldset>
      </div>
      {suggestions ? <>
        <ScientificOutput output={{ ...suggestions, candidates: undefined }} />
        <ul>{suggestions.candidates.map((candidate, index) => <li key={index}>
          Parent {candidate.parent.labelId} → {candidate.daughters.map((daughter) => daughter.labelId).join(", ")}
          <button className="cc-btn" disabled={!editable} onClick={() => {
            setDivisionId(""); setParentTime(candidate.parent.timeIndex); setParentLabel(candidate.parent.labelId);
            setDaughterTime(candidate.daughters[0].timeIndex); setDaughters([candidate.daughters[0].labelId, candidate.daughters[1].labelId]);
          }}>Use in division form</button><ScientificOutput output={candidate} />
        </li>)}</ul>
      </> : null}
      <div className="workbench-lineage-chart">
        <svg viewBox={`0 0 ${width} ${height}`} width={width} height={height} role="img" aria-label="Lineage graph; time runs from left to right.">
          {timeLabels.map((time) => {
            const x = 85 + time / Math.max(1, timeCount - 1) * (width - 110);
            return <g key={time}><line x1={x} x2={x} y1={10} y2={height - 25} stroke="currentColor" opacity={.12} />
              <text x={x} y={height - 5} textAnchor="middle">T{time + 1}</text></g>;
          })}
          {displayedTracks.map((track, index) => {
            const parent = graph.tracks.find((item) => item.id === track.parentTrackId);
            const parentRow = parent ? rowByTrack.get(parent.id) : undefined;
            const start = track.observations[0];
            const previous = parent?.observations.at(-1);
            const p = previous && parentRow !== undefined ? position(previous, parentRow) : undefined;
            const q = start ? position(start, index) : undefined;
            return <g key={track.id}>
              <text x={4} y={39 + index * 36}>{page * 100 + index + 1}</text>
              {p && q ? <path d={`M${p.x},${p.y}L${q.x},${q.y}`} stroke="#e8b96b" fill="none" /> : null}
              <polyline points={shownNodes(track.observations).map((node) => { const xy = position(node, index); return `${xy.x},${xy.y}`; }).join(" ")}
                stroke="#61b7d6" fill="none" strokeWidth={2} />
              {shownNodes(track.observations).map((node) => {
                const xy = position(node, index);
                return <circle key={node.id} cx={xy.x} cy={xy.y} r={5} fill="#61b7d6" tabIndex={editable ? 0 : -1}
                  role="button" aria-label={`Time ${node.timeIndex + 1}, object ${node.labelId}`}
                  onClick={() => useNode(node)} onKeyDown={(event) => {
                    if (event.key === "Enter" || event.key === " ") { event.preventDefault(); useNode(node); }
                  }}><title>Time {node.timeIndex + 1} · label {node.labelId}</title></circle>;
              })}
            </g>;
          })}
        </svg>
      </div>
      {displayedTracks.some((track) => track.observations.length > perTrackLimit) ? <p>Long tracks are sampled for this display. Full observations remain in the graph and export.</p> : null}
      <div className="workbench-table"><table><caption>Tracks · {graph.tracks.length} total</caption>
        <thead><tr><th>Row</th><th>Track</th><th>Parent track</th><th>Observations</th><th>Path (µm)</th><th>Mean speed (µm/s)</th><th>Mean volume (µm³)</th></tr></thead>
        <tbody>{displayedTracks.map((track, index) => <tr key={track.id}>
          <td>{page * 100 + index + 1}</td><td>{track.id}</td><td>{track.parentTrackId ?? "—"}</td>
          <td>{track.summary.observationCount}</td><td>{fmt(track.summary.pathLengthUm)}</td>
          <td>{fmt(track.summary.meanSpeedUmPerSecond)}</td><td>{fmt(track.summary.meanVolumeUm3)}</td>
        </tr>)}</tbody>
      </table></div>
      <div className="workbench-actions">
        <button className="cc-btn" disabled={!page} onClick={() => setPage((value) => value - 1)}>Previous 100 tracks</button>
        <span>Page {page + 1}</span>
        <button className="cc-btn" disabled={(page + 1) * 100 >= graph.tracks.length} onClick={() => setPage((value) => value + 1)}>Next 100 tracks</button>
      </div>
      <details><summary>Graph correction history</summary><ol>{graph.history.slice(-30).reverse().map((event) =>
        <li key={event.id}>{event.operation} · revision {event.revision} · {event.reason}</li>)}</ol></details>
    </> : null}
  </details></div>;
}
