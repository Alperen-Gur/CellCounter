import { useEffect, useRef, useState } from "react";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import type { LibraryMigration, MigrationActions, MigrationPlan } from "../../../../shared/workbench/migrationProtocol";
import { activeJobWorker } from "../../../../shared/workbench/workerProtocol";
import WorkbenchMigrationEvidence from "./WorkbenchMigrationEvidence";

type Props = { snapshot?: ProjectSnapshot; busy: boolean; writeBlocked: boolean; running: boolean; actions: MigrationActions;
  readProjectless: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  readProject: <T>(operation: string, args?: Record<string, unknown>) => Promise<T> };
const count = (value: number | undefined) => value === undefined ? "—" : value.toLocaleString();
const bytes = (value: number) => `${(value / 1024 / 1024).toLocaleString(undefined, { maximumFractionDigits: 1 })} MiB`;

export default function WorkbenchMigration({ snapshot, busy, writeBlocked, running, actions, readProjectless, readProject }: Props) {
  const [open, setOpen] = useState(false);
  const [sourceDirectory, setSourceDirectory] = useState("");
  const [archivePath, setArchivePath] = useState("");
  const [scope, setScope] = useState<"archive" | "selected">("archive");
  const [selectedIds, setSelectedIds] = useState("");
  const [name, setName] = useState("Imported library");
  const [plan, setPlan] = useState<{ path: string; scopeKey: string; value: MigrationPlan }>();
  const [loaded, setLoaded] = useState<{ projectId: string; revision: number; migration: LibraryMigration | null }>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [page, setPage] = useState(0);
  const epoch = useRef(0);
  const latest = useRef({ readProject, readProjectless }); latest.current = { readProject, readProjectless };
  const activeWorker = snapshot?.jobWorkers?.some(activeJobWorker) === true;
  const locked = busy || loading || activeWorker;
  const scopeKey = `${scope}:${selectedIds}`;
  const preview = plan?.path === archivePath && plan.scopeKey === scopeKey ? plan.value : undefined;
  const migration = snapshot?.migration !== undefined ? snapshot.migration
    : loaded?.projectId === snapshot?.project.id && loaded?.revision === snapshot?.project.revision ? loaded?.migration : undefined;
  const currentPage = Math.min(page, Math.max(0, Math.ceil((preview?.images.length ?? 0) / 50) - 1));
  useEffect(() => {
    if (!open || !snapshot || snapshot.migration !== undefined || busy || activeWorker) return;
    let current = true;
    void latest.current.readProject<{ migration: LibraryMigration | null }>("migration.library.get").then((result) => {
      if (current) setLoaded({ projectId: snapshot.project.id, revision: snapshot.project.revision, migration: result.migration });
    }).catch((cause) => { if (current) setError(String(cause)); });
    return () => { current = false; };
  }, [open, snapshot?.project.id, snapshot?.project.revision, snapshot?.migration, busy, activeWorker]);
  const selectArchive = (path: string) => { epoch.current++; setArchivePath(path); setPlan(undefined); setPage(0); setError(""); };
  const inspect = async () => {
    if (!archivePath || locked) return;
    const generation = ++epoch.current; setLoading(true); setError(""); setPlan(undefined);
    try {
      const imageIds = scope === "selected" ? selectedIds.split(/[\s,]+/).filter(Boolean) : undefined;
      if (imageIds && (!imageIds.length || imageIds.length > 1000 || new Set(imageIds).size !== imageIds.length))
        throw new Error("Enter 1–1,000 distinct legacy image IDs, separated by lines or commas.");
      const result = await readProjectless<{ plan: MigrationPlan }>("migration.library.preview", { path: archivePath, ...(imageIds ? { imageIds } : {}) });
      if (generation === epoch.current) { setPlan({ path: archivePath, scopeKey, value: result.plan }); setPage(0); }
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  return <details className="workbench-package" onToggle={(event) => setOpen(event.currentTarget.open)}>
    <summary>Import an existing library</summary>
    <p>Capture the existing library, inspect the import plan, then create a separate shared project. Original library files, records and history stay in place.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <fieldset disabled={locked || writeBlocked}>
      <legend>Library capture</legend>
      <div className="workbench-actions">
        <button type="button" className="cc-btn" onClick={() => void actions.useExistingLibrary(setSourceDirectory)}>Use this app’s existing library</button>
        <button type="button" className="cc-btn" onClick={() => void actions.chooseLibrary(setSourceDirectory)}>Choose Windows library folder…</button>
      </div>
      {sourceDirectory ? <p className="workbench-project-path">{sourceDirectory}</p> : <p>Choose the folder containing the existing store.sqlite and its image folders.</p>}
      <button type="button" className="cc-btn" disabled={!sourceDirectory} onClick={() => void actions.capture(sourceDirectory, (result) => selectArchive(result.archivePath))}>Save library archive…</button>
      <p>The capture retains all database tables and raw record evidence. Available original, normalized analysis and display files remain separately identified.</p>
    </fieldset>
    <fieldset disabled={locked}>
      <legend>Preview and import</legend>
      <button type="button" className="cc-btn" disabled={writeBlocked} onClick={() => void actions.chooseArchive(selectArchive)}>Choose captured library archive…</button>
      {archivePath ? <p className="workbench-project-path">{archivePath}</p> : null}
      <label>Source-image import scope<select value={scope} onChange={(event) => setScope(event.target.value as "archive" | "selected")}>
        <option value="archive">Use the archive’s selected images, or all images</option><option value="selected">Choose legacy image IDs</option>
      </select></label>
      {scope === "selected" ? <label>Legacy image IDs<textarea rows={3} value={selectedIds} maxLength={257000}
        onChange={(event) => setSelectedIds(event.target.value)} placeholder="One legacy image ID per line" /></label> : null}
      <p>At most 1,000 source images can be imported into one project. Every archived record and available evidence file is retained even when you select fewer images.</p>
      <button type="button" className="cc-btn" disabled={!archivePath} onClick={() => void inspect()}>Preview library import</button>
    </fieldset>
    {loading ? <p role="status">Reading the archive and checking its retained source files…</p> : null}
    {preview ? <section aria-label="Library migration plan">
      <p>{preview.platform === "windows" ? "Windows" : "macOS"} library · {count(preview.counts.selectedImages)} selected images · {bytes(preview.totalBytes)} evidence.</p>
      <dl className="workbench-metric-grid">
        <div><dt>Usable source images</dt><dd>{count(preview.counts.importableImages)}</dd></div>
        <div><dt>Archived records only</dt><dd>{count(preview.counts.archivedOnlyImages)}</dd></div>
        <div><dt>Missing source images</dt><dd>{count(preview.counts.missingImages)}</dd></div>
        <div><dt>Evidence files</dt><dd>{count(preview.counts.files)}</dd></div>
        <div><dt>Missing files</dt><dd>{count(preview.counts.missingFiles)}</dd></div>
      </dl>
      <p>Historical contours, centers and diameters remain archived geometry. They do not become exact cell masks; quantitative mask analysis must use a real imported mask or new segmentation.</p>
      <div className="workbench-table"><table><caption>Source and geometry disposition</caption>
        <thead><tr><th>Image</th><th>Status</th><th>Source role</th><th>Geometry</th><th>Reason</th></tr></thead>
        <tbody>{preview.images.slice(currentPage * 50, (currentPage + 1) * 50).map((image) => <tr key={image.legacyImageId}>
          <th scope="row">{image.name}</th><td>{image.status}</td><td>{image.sourceRole}</td>
          <td>Archived contours and centers · no exact mask</td><td>{image.reason ?? "—"}</td>
        </tr>)}</tbody>
      </table></div>
      {preview.images.length > 50 ? <div className="workbench-actions">
        <button type="button" className="cc-btn" disabled={!currentPage} onClick={() => setPage(currentPage - 1)}>Previous images</button>
        <span>Page {currentPage + 1} of {Math.ceil(preview.images.length / 50)}</span>
        <button type="button" className="cc-btn" disabled={(currentPage + 1) * 50 >= preview.images.length} onClick={() => setPage(currentPage + 1)}>Next images</button>
      </div> : null}
      {preview.notes.length ? <ul>{preview.notes.map((note, index) => <li key={index}>{note}</li>)}</ul> : null}
      <fieldset disabled={locked || writeBlocked}>
        <label>New project name<input maxLength={200} value={name} onChange={(event) => setName(event.target.value)} /></label>
        <button type="button" className="cc-btn" disabled={!name.trim()} onClick={() => void actions.create(archivePath, preview, name.trim())}>Create new project from this plan…</button>
        <p>This prepares a resumable import. Evidence files and images are copied by the bounded checkpoints below; creation alone does not mean import is complete.</p>
      </fieldset>
    </section> : null}
    {migration ? <section aria-label="Current project library migration">
      <h3>Current project import · {migration.status}</h3>
      <p>{migration.progress.completed} / {migration.progress.total} checkpoints.</p>
      <progress aria-label="Library import progress" value={migration.progress.completed} max={migration.progress.total || 1} />
      {migration.nextUnit ? <p>Next {migration.nextUnit.type}: {migration.nextUnit.name}</p> : null}
      {migration.error ? <p className="workbench-error">{migration.error.message}</p> : null}
      <div className="workbench-actions">
        {["pending", "running"].includes(migration.status) ? <>
          <button type="button" className="cc-btn" disabled={locked || writeBlocked} onClick={() => void actions.control("migration.library.advance")}>Import next checkpoint</button>
          <button type="button" className="cc-btn" disabled={locked || writeBlocked} onClick={() => void actions.runRemaining()}>Import remaining in this window</button>
          <button type="button" className="cc-btn" disabled={locked || writeBlocked} onClick={() => void actions.control("migration.library.pause")}>Pause import</button>
        </> : null}
        {["paused", "failed"].includes(migration.status) ? <button type="button" className="cc-btn" disabled={locked || writeBlocked}
          onClick={() => void actions.control("migration.library.resume")}>Resume import</button> : null}
        {!["completed", "cancelled"].includes(migration.status) ? <button type="button" className="cc-btn" disabled={locked || writeBlocked}
          onClick={() => void actions.control("migration.library.cancel")}>Cancel remaining import</button> : null}
      </div>
      {migration.status === "failed" ? <p>Restore any missing or changed source bytes before resuming. The original frozen source identities remain required.</p> : null}
      {migration.status === "completed" ? <p>All import checkpoints finished. Evidence {migration.evidenceComplete ? "is complete" : "has recorded missing files"}; source-image import {migration.scientificImportComplete ? "is complete" : "has archived-only or missing images"}. Archived legacy measurements remain historical evidence.</p> : null}
      {migration.status === "cancelled" ? <p>Completed copies and retained evidence remain in this project. Original library data is unchanged.</p> : null}
      {migration.imagePlans?.some((image) => image.status !== "importable") ? <details><summary>Images requiring attention</summary>
        <ul>{migration.imagePlans.filter((image) => image.status !== "importable").map((image) => <li key={image.legacyImageId}>
          {image.name} · {image.status}{image.reason ? ` · ${image.reason}` : ""}</li>)}</ul>
      </details> : null}
      {snapshot ? <WorkbenchMigrationEvidence key={`${snapshot.project.id}:${migration.id}`} migration={migration}
        projectRevision={snapshot.project.revision} busy={busy || activeWorker} read={readProject} /> : null}
      {migration.notes?.length ? <p>{migration.notes.join(" ")}</p> : null}
    </section> : null}
    {running ? <button type="button" className="cc-btn" onClick={actions.stopAfterCheckpoint}>Stop import after current checkpoint</button> : null}
    {writeBlocked ? <p>Save or discard pending scientific edits before opening migration dialogs or changing projects.</p> : null}
    {activeWorker ? <p>Stop background execution after its current checkpoint before importing a library.</p> : null}
    <p>Layer-workspace JSON, semantic paint classes and executable model bindings are not converted by this library import. Retained records remain available for their dedicated migration paths.</p>
  </details>;
}
