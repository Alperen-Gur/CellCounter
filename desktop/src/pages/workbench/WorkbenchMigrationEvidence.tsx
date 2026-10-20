import { useEffect, useRef, useState } from "react";
import type { LibraryMigration, MigrationEvidencePage, MigrationGeometry } from "../../../../shared/workbench/migrationProtocol";

type Props = { migration: LibraryMigration; projectRevision: number; busy: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T> };
type Mode = "geometry" | "records" | "files";
type Page = { rows: unknown[]; total: number; offset: number; nextOffset: number | null; archiveHash: string; notes?: string[]; recordId?: string | null };
const PAGE_SIZE = 25;
const DISPLAY_LIMIT = 64 * 1024;
const recordTitle = (value: unknown, index: number) => {
  if (!value || typeof value !== "object" || Array.isArray(value)) return `Record ${index + 1}`;
  const row = value as Record<string, unknown>;
  const identity = [row.name, row.file_name, row.id, row.cellId, row.path].find((item) => typeof item === "string" && item.length);
  const status = typeof row.status === "string" ? ` · ${row.status}` : "";
  return `${identity ?? `Record ${index + 1}`}${status}`;
};

/** Exact archived fields are inspected separately from canonical measurements. */
export default function WorkbenchMigrationEvidence({ migration, projectRevision, busy, read }: Props) {
  const [mode, setMode] = useState<Mode>("geometry");
  const [imageId, setImageId] = useState("");
  const [entity, setEntity] = useState("");
  const [page, setPage] = useState<Page>();
  const [selected, setSelected] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const epoch = useRef(0);
  const actualImageId = migration.imageMappings.some((item) => item.legacyImageId === imageId) ? imageId : migration.imageMappings[0]?.legacyImageId ?? "";
  const actualEntity = migration.entities.some((item) => item.name === entity) ? entity : migration.entities[0]?.name ?? "";
  useEffect(() => {
    epoch.current++; setPage(undefined); setLoading(false); setError(""); setSelected(0);
  }, [mode, actualImageId, actualEntity, projectRevision]);
  useEffect(() => () => { epoch.current++; }, []);
  const load = async (offset = 0) => {
    if (busy || loading || (mode === "geometry" && !actualImageId) || (mode === "records" && !actualEntity)) return;
    const generation = ++epoch.current; setLoading(true); setError("");
    try {
      let result: Page;
      if (mode === "geometry") {
        const value = await read<MigrationGeometry>("migration.geometry.get", { imageId: actualImageId, offset, limit: PAGE_SIZE });
        result = { ...value, rows: value.cells };
      } else {
        const value = await read<MigrationEvidencePage>(mode === "records" ? "migration.records.get" : "migration.evidence.list",
          { ...(mode === "records" ? { entity: actualEntity } : {}), offset, limit: PAGE_SIZE });
        result = { ...value, rows: value.records ?? value.files ?? [] };
      }
      if (generation === epoch.current) { setPage(result); setSelected(0); }
    } catch (cause) { if (generation === epoch.current) { setPage(undefined); setError(String(cause)); } }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  const displayed = page?.rows.length ? JSON.stringify(page.rows[Math.min(selected, page.rows.length - 1)], null, 2) : "";
  return <details>
    <summary>Retained records and historical geometry</summary>
    <p>Inspect original fields without converting contours, reference points, semantic classes or old review decisions into canonical masks or approvals.</p>
    <fieldset disabled={busy || loading}>
      <label>Evidence type<select value={mode} onChange={(event) => setMode(event.target.value as Mode)}>
        <option value="geometry">Historical cell geometry</option><option value="records">Archived entity records</option><option value="files">Evidence files and availability</option>
      </select></label>
      {mode === "geometry" ? <label>Legacy image<select value={actualImageId} onChange={(event) => setImageId(event.target.value)}>
        {!migration.imageMappings.length ? <option value="">Import an image checkpoint first</option> : null}
        {migration.imageMappings.map((item) => <option key={item.legacyImageId} value={item.legacyImageId}>
          {migration.imagePlans.find((plan) => plan.legacyImageId === item.legacyImageId)?.name ?? item.legacyImageId} · {item.status}
        </option>)}
      </select></label> : null}
      {mode === "records" ? <label>Entity<select value={actualEntity} onChange={(event) => setEntity(event.target.value)}>
        {migration.entities.map((item) => <option key={item.name} value={item.name}>{item.name} · {item.recordCount} records</option>)}
      </select></label> : null}
      <button type="button" className="cc-btn" disabled={(mode === "geometry" && !actualImageId) || (mode === "records" && !actualEntity)} onClick={() => void load()}>Read retained evidence</button>
    </fieldset>
    {loading ? <p role="status">Reading a bounded evidence page…</p> : null}
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {page ? <>
      <p>{page.total ? `${page.offset + 1}–${page.offset + page.rows.length} of ${page.total} records` : "No records in this selection."}
        {mode === "geometry" ? " · Historical geometry, no exact mask" : ""}</p>
      {page.recordId ? <p>Original detection record: {page.recordId}</p> : null}
      {page.notes?.map((note, index) => <p key={index}>{note}</p>)}
      {page.rows.length ? <label>Record<select value={Math.min(selected, page.rows.length - 1)} onChange={(event) => setSelected(Number(event.target.value))}>
        {page.rows.map((item, index) => <option key={index} value={index}>{recordTitle(item, page.offset + index)}</option>)}
      </select></label> : null}
      {displayed ? <pre className="workbench-json" tabIndex={0} aria-label="Original retained record fields">{displayed.slice(0, DISPLAY_LIMIT)}</pre> : null}
      {displayed.length > DISPLAY_LIMIT ? <p>This record exceeds the 64 KiB display limit. The complete original record remains in the archive and the canonical migration.records.get response.</p> : null}
      <div className="workbench-actions">
        <button type="button" className="cc-btn" disabled={busy || loading || page.offset === 0} onClick={() => void load(Math.max(0, page.offset - PAGE_SIZE))}>Previous records</button>
        <button type="button" className="cc-btn" disabled={busy || loading || page.nextOffset === null} onClick={() => page.nextOffset !== null && void load(page.nextOffset)}>Next records</button>
      </div>
      <p className="workbench-project-path">Original archive SHA-256: {page.archiveHash}</p>
    </> : null}
  </details>;
}
