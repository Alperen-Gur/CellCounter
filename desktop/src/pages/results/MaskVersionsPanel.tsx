import { useEffect, useMemo, useRef, useState } from "react";
import type { CellDTO, DetectionDTO, ImageDTO } from "../../kernel/types";
import { loadWorkflowDocument, saveWorkflowDocument, deleteWorkflowDocument, type SavedRun } from "../../kernel/workflow/workflowDocuments";
import { getPort } from "../../kernel/persistence";
import { Viewport } from "../../kernel/viewport/Viewport";
import { MaskOverlay } from "../../kernel/overlay/MaskOverlay";
import { useAppStore } from "../../kernel/store/store";
import { appendMaskVersion, readMaskVersions, replaceMasksWithProvenance, type MaskVersion, type MaskVersionDocument } from "./maskVersions";
import { compareMasks } from "./reviewMath";
import { assertReviewImageWritable } from "./reviewWriteGuard";

export function MaskVersionsPanel({ image, imageSrc, detection, cells, run, reviewPxPerUm, thresholds, disabled, flush, onRestored, onBusyChange }: {
  image: ImageDTO; imageSrc: string; detection: DetectionDTO | null; cells: CellDTO[];
  run: SavedRun | null; reviewPxPerUm: number; thresholds: number[]; disabled: boolean;
  flush: () => Promise<void>; onRestored: () => Promise<void>; onBusyChange: (busy: boolean) => void;
}) {
  const [document, setDocument] = useState<MaskVersionDocument>({ version: 1, imageId: image.id, versions: [] });
  const [selectedID, setSelectedID] = useState("");
  const [label, setLabel] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadFailed, setLoadFailed] = useState(false);
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [differencesOnly, setDifferencesOnly] = useState(true);
  const selected = document.versions.find(version => version.id === selectedID);
  const difference = useMemo(() => selected ? compareMasks(selected.cells, cells) : null, [selected, cells]);
  const savedChanged = useMemo(() => new Set([...(difference?.removed ?? []), ...(difference?.savedChanged ?? [])]), [difference]);
  const currentChanged = useMemo(() => new Set([...(difference?.added ?? []), ...(difference?.currentChanged ?? [])]), [difference]);
  const savedCells = useMemo(() => selected?.cells.filter(cell => !differencesOnly || savedChanged.has(cell.id)) ?? [], [selected, differencesOnly, savedChanged]);
  const currentCells = useMemo(() => cells.filter(cell => !differencesOnly || currentChanged.has(cell.id)), [cells, differencesOnly, currentChanged]);
  const fit = () => { setZoom(1); setPan({ x: 0, y: 0 }); };

  useEffect(() => {
    let cancelled = false;
    void loadWorkflowDocument<MaskVersionDocument>(`variant-${image.id}`).then(value => {
      if (cancelled) return;
      const next = readMaskVersions(value, image.id);
      setDocument(next); setSelectedID(next.versions[0]?.id ?? "");
    }).catch(err => { if (!cancelled) { setError(String(err)); setLoadFailed(true); } }).finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [image.id]);

  const snapshot = (name: string): MaskVersion => ({ id: crypto.randomUUID(), label: name, savedAt: new Date().toISOString(),
    detectorId: detection?.detectorId ?? "manual", cells: structuredClone(cells), imageStats: detection?.imageStats,
    run: run ? structuredClone(run) : null, reviewPxPerUm });
  const perform = async (action: () => Promise<void>) => {
    if (disabled || busyRef.current || loading || loadFailed) return;
    busyRef.current = true; setBusy(true); onBusyChange(true); setError(null);
    try { assertReviewImageWritable(image.id); await flush(); await action(); }
    catch (err) { setError(err instanceof Error ? err.message : String(err)); }
    finally { busyRef.current = false; setBusy(false); onBusyChange(false); }
  };
  const save = () => void perform(async () => {
    const version = snapshot(label.trim() || `Version ${document.versions.length + 1}`);
    const next = appendMaskVersion(document, version);
    await saveWorkflowDocument(`variant-${image.id}`, next);
    setDocument(next); setSelectedID(version.id); setLabel("");
  });
  const remove = () => void perform(async () => {
    if (!selected) return;
    const next = { ...document, versions: document.versions.filter(version => version.id !== selected.id) };
    await saveWorkflowDocument(`variant-${image.id}`, next);
    setDocument(next); setSelectedID(next.versions[0]?.id ?? "");
  });
  const restore = () => void perform(async () => {
    if (!selected) return;
    // Preserve the current masks first, making restore itself reversible.
    const next = appendMaskVersion(document, snapshot("Before restoring " + selected.label));
    await saveWorkflowDocument(`variant-${image.id}`, next);
    setDocument(next);
    await replaceMasksWithProvenance(selected, {
      assertWritable: () => assertReviewImageWritable(image.id),
      deleteRun: () => deleteWorkflowDocument(`run-${image.id}`),
      saveDetection: (detector, masks, stats) => getPort().saveDetection(image.id, detector, masks, stats),
      saveRun: value => saveWorkflowDocument(`run-${image.id}`, value),
      newToken: () => crypto.randomUUID(),
      refresh: onRestored,
    });
    void useAppStore.getState().refreshLibraryStats().catch(() => {});
  });

  return <section className="rv-versions" aria-label="Saved mask versions">
    <div className="rv-review-row"><strong>Saved mask versions</strong><span>{document.versions.length} / 8 saved</span>
      <input aria-label="New version name" placeholder="Version name" value={label} maxLength={80} onChange={e => setLabel(e.target.value)} />
      <button disabled={disabled || busy || loading || loadFailed} onClick={save}>Save current masks</button>
      <select aria-label="Saved version" value={selectedID} onChange={e => { setSelectedID(e.target.value); fit(); }}><option value="">Choose a version</option>{document.versions.map(version => <option key={version.id} value={version.id}>{version.label}</option>)}</select>
      <button disabled={disabled || busy || !selected} onClick={restore}>Restore version</button>
      <button disabled={disabled || busy || !selected} onClick={remove}>Remove version</button>
    </div>
    {error && <p className="rv-review-error" role="alert">{error}</p>}
    {loading && <p role="status">Loading saved versions…</p>}
    {busy && <p role="status">Saving…</p>}
    <p className="rv-review-help">Restore saves the current masks as another version first. Saved versions stay on this computer.</p>
    {selected && difference && <>
      <div className="rv-review-row"><span>{difference.unchanged} unchanged · {difference.changed} modified · {difference.removed.size} saved only · {difference.added.size} current only</span>
        <label><input type="checkbox" checked={differencesOnly} onChange={e => setDifferencesOnly(e.target.checked)} /> Differences only</label><button onClick={fit}>Fit both views</button></div>
      <p className="rv-review-help">{selected.label}: {selected.detectorId} · {selected.run ? `analysis ${selected.run.params.pxPerUm} px/µm` : "analysis settings unknown"} · saved review scale {selected.reviewPxPerUm} px/µm. Matching uses source geometry; resized or moved masks with new IDs appear as saved/current only.</p>
      <div className="rv-compare-panes">{[
        { name: selected.label, masks: savedCells, selection: savedChanged },
        { name: "Current masks", masks: currentCells, selection: currentChanged },
      ].map((pane, index) => <div className="rv-compare-pane" key={index}><strong>{pane.name}</strong><div>
        <Viewport imageSrc={imageSrc} sourceWidth={image.widthPx} sourceHeight={image.heightPx} zoom={zoom} pan={pan} onZoomChange={setZoom} onPanChange={setPan} onFit={fit}>
          <MaskOverlay cells={pane.masks} annotations={[]} thresholds={thresholds} overlayMode="outline" confidenceCutoff={0} showMaskFills showOutlines maskOpacity={.3} selectedCellIds={pane.selection} />
        </Viewport></div></div>)}</div>
    </>}
  </section>;
}
