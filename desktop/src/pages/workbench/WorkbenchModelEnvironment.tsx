import { useEffect, useMemo, useRef, useState } from "react";
import type { ModelEnvironmentInspection, WorkbenchModel } from "../../../../shared/workbench/modelProtocol";

type Props = {
  model: WorkbenchModel; revision: number; active: boolean; busy: boolean; writeBlocked: boolean; bindingDirty: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  capture: (modelId: string) => Promise<void>;
};
const PAGE_SIZE = 50;

export default function WorkbenchModelEnvironment({ model, revision, active, busy, writeBlocked, bindingDirty, read, capture }: Props) {
  const [detailsOpen, setDetailsOpen] = useState(false);
  const [selection, setSelection] = useState<{ modelId: string; environmentId: string }>();
  const [loaded, setLoaded] = useState<{ revision: number; selection: string; result: ModelEnvironmentInspection }>();
  const [attempt, setAttempt] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(0);
  const latest = useRef(read); latest.current = read;
  const environmentId = selection?.modelId === model.id ? selection.environmentId : "";
  const current = loaded?.revision === revision && loaded.result.modelId === model.id && loaded.selection === environmentId ? loaded.result : undefined;
  const selected = current?.environment;
  const activeRecord = current?.environments.find((item) => item.id === current.activeEnvironmentId);
  const status = model.environmentStatus ?? "unrecorded";
  const statusLabel = status === "captured" ? "Recorded" : status === "binding-changed" ? "Interpreter binding changed" : "Not recorded";
  const packages = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase();
    return (selected?.inventory.packages ?? []).filter((item) => !needle || `${item.name} ${item.version}`.toLocaleLowerCase().includes(needle));
  }, [selected?.inventory.packages, query]);
  const pageCount = Math.max(1, Math.ceil(packages.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount - 1);
  const visiblePackages = packages.slice(currentPage * PAGE_SIZE, (currentPage + 1) * PAGE_SIZE);

  useEffect(() => { setQuery(""); setPage(0); setError(""); }, [model.id]);
  useEffect(() => {
    if (!active || busy) return;
    let pending = true; setLoading(true); setError("");
    void latest.current<ModelEnvironmentInspection>("model.environment.get", { modelId: model.id,
      ...(environmentId ? { environmentId } : {}) }).then((result) => {
      if (pending) setLoaded({ revision, selection: environmentId, result });
    }).catch((cause) => { if (pending) setError(cause instanceof Error ? cause.message : String(cause)); })
      .finally(() => { if (pending) setLoading(false); });
    return () => { pending = false; };
  }, [active, busy, revision, model.id, environmentId, attempt]);

  return <section aria-label="Saved model environment" className="workbench-model-environment">
    <h4>Saved environment</h4>
    <p role="status">{statusLabel}{model.environmentCount ? ` · ${model.environmentCount} retained records` : ""}.</p>
    {activeRecord ? <p>{activeRecord.summary.implementation} {activeRecord.summary.pythonVersion} · {activeRecord.summary.system} {activeRecord.summary.machine}
      {" · "}{activeRecord.summary.packageCount.toLocaleString()} recorded packages · captured {activeRecord.capturedAt}.</p> : null}
    {status === "binding-changed" ? <p>The saved Python binding changed. Previous records remain in history; capture a new record to bind this interpreter.</p>
      : status === "unrecorded" ? <p>No package inventory is bound to this model yet.</p> : <p>The record describes the last explicit capture, not a live check. Model execution compares its observed environment with the active record.</p>}
    <p>Capture runs the enabled model’s saved, trusted Python interpreter and retains Python, platform and package metadata.
      It does not retain package binaries, GPU drivers or a reproducible installation lockfile.</p>
    <button type="button" className="cc-btn" disabled={busy || loading || writeBlocked || bindingDirty || !model.enabled}
      onClick={() => void capture(model.id)}>Capture environment</button>
    {bindingDirty ? <p>Save the Python binding before capturing its environment.</p> : !model.enabled ? <p>Enable the trusted model before invoking its interpreter.</p> : null}
    {writeBlocked ? <p>Save or discard scientific edits and stop active workers before recording an environment.</p> : null}
    {loading ? <p role="status">Reading saved environment records…</p> : null}
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <details onToggle={(event) => setDetailsOpen(event.currentTarget.open)}>
      <summary>Environment history and packages</summary>
      <button type="button" className="cc-btn" disabled={busy || loading} onClick={() => setAttempt((value) => value + 1)}>Inspect saved records</button>
      {current?.environments.length ? <>
        <label>Saved record<select value={environmentId} disabled={busy || loading} onChange={(event) => {
          setSelection({ modelId: model.id, environmentId: event.target.value }); setPage(0);
        }}><option value="">{current.activeEnvironmentId ? "Active record" : "Latest retained record (not active)"}</option>
          {current.environments.map((record) => <option key={record.id} value={record.id}>{record.capturedAt}
            {` · ${record.summary.packageCount} packages${record.id === current.activeEnvironmentId ? " · active" : " · history"}`}</option>)}
        </select></label>
        {selected ? <>
          <p>{selected.id === current.activeEnvironmentId ? "Active record for the saved interpreter." : "Historical record; selecting it does not activate it."}</p>
          <p>{selected.inventory.python.implementation} {selected.inventory.python.version} · {selected.inventory.platform.system} {selected.inventory.platform.machine}
            {" · "}{selected.inventory.platform.byteOrder} byte order.</p>
          <p>Captured {selected.capturedAt} at project revision {selected.capturedRevision} by {selected.actor.name}.</p>
          <details><summary>Interpreter and inventory identity</summary>
            <p className="workbench-project-path">Python: {selected.pythonPath}</p>
            <p className="workbench-project-path">Interpreter SHA-256: {selected.pythonHash}</p>
            <p className="workbench-project-path">Inventory SHA-256: {selected.inventory.hash}</p>
          </details>
          {detailsOpen ? <>
            <label>Search recorded packages<input type="search" maxLength={200} value={query} placeholder="Package name or version"
              onChange={(event) => { setQuery(event.target.value); setPage(0); }} /></label>
            <p role="status">{packages.length.toLocaleString()} matching packages of {selected.inventory.packages.length.toLocaleString()} recorded.
              {packages.length ? ` Showing ${currentPage * PAGE_SIZE + 1}–${Math.min((currentPage + 1) * PAGE_SIZE, packages.length)}.` : ""}</p>
            <div className="workbench-table"><table>
              <caption>Recorded package metadata</caption><thead><tr><th scope="col">Package</th><th scope="col">Version</th></tr></thead>
              <tbody>{visiblePackages.map((item) => <tr key={item.name}><td>{item.name}</td><td>{item.version}</td></tr>)}</tbody>
            </table></div>
            <div className="workbench-actions">
              <button type="button" className="cc-btn" disabled={currentPage === 0} onClick={() => setPage(currentPage - 1)}>Previous packages</button>
              <span>Page {currentPage + 1} of {pageCount}</span>
              <button type="button" className="cc-btn" disabled={currentPage + 1 >= pageCount} onClick={() => setPage(currentPage + 1)}>Next packages</button>
            </div>
          </> : null}
        </> : null}
      </> : current ? <p>No environment records have been captured for this model.</p> : null}
    </details>
  </section>;
}
