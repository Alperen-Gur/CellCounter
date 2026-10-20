import { createContext, useCallback, useContext, useEffect, useId, useRef, useState, type ReactNode } from "react";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import { catalogueEntries, catalogueEntryId, catalogueLabel, catalogueNames, type CatalogueEntry, type CatalogueKey, type CatalogueMany,
  type CataloguePage, type CatalogueRef } from "../../../../shared/workbench/catalogueProtocol";

type Read = <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
type Service = { identity: string; snapshot?: ProjectSnapshot; read: Read;
  keep: (owner: string, refs: CatalogueRef[]) => void;
  resolve: (ref: CatalogueRef) => Promise<CatalogueEntry>;
  adopt: (ref: CatalogueRef, entry: CatalogueEntry) => void };
const CatalogueContext = createContext<Service | null>(null);
const refKey = (ref: CatalogueRef) => `${ref.catalogue}:${ref.entryId}:${ref.version ?? "latest"}`;
export function useCatalogueEntries<T>(catalogue: CatalogueKey): T[] {
  const service = useContext(CatalogueContext);
  return (service?.snapshot ? catalogueEntries(service.snapshot, catalogue) : []) as unknown as T[];
}

export function WorkbenchCatalogueProvider({ snapshot, read, onPins, onAdopt, children }: {
  snapshot?: ProjectSnapshot; read: Read; onPins: (refs: CatalogueRef[]) => void;
  onAdopt: (ref: CatalogueRef, entry: CatalogueEntry, identity: string) => void; children: ReactNode;
}) {
  const identity = snapshot ? `${snapshot.project.id}:${snapshot.project.revision}` : "";
  const owners = useRef(new Map<string, CatalogueRef[]>());
  const project = useRef(snapshot?.project.id);
  if (project.current !== snapshot?.project.id) { owners.current.clear(); project.current = snapshot?.project.id; }
  const latest = useRef({ snapshot, identity, read, onPins, onAdopt }); latest.current = { snapshot, identity, read, onPins, onAdopt };
  const pending = useRef(new Map<string, Promise<CatalogueEntry>>());
  const keep = useCallback((owner: string, refs: CatalogueRef[]) => {
    const next = new Map(owners.current); if (refs.length) next.set(owner, refs); else next.delete(owner);
    const unique = new Map([...next.values()].flat().filter(ref => ref.entryId).map(ref => [refKey(ref), ref]));
    if (unique.size > 64) throw new Error("At most 64 saved records can stay selected across project refreshes. Release unused catalogue selections, then select this record again.");
    owners.current = next; latest.current.onPins([...unique.values()]);
  }, []);
  const adopt = useCallback((ref: CatalogueRef, entry: CatalogueEntry) => latest.current.onAdopt(ref, entry, latest.current.identity), []);
  const resolve = useCallback((ref: CatalogueRef): Promise<CatalogueEntry> => {
    const state = latest.current;
    const known = state.snapshot && catalogueEntries(state.snapshot, ref.catalogue).find(entry =>
      catalogueEntryId(ref.catalogue, entry) === ref.entryId && (ref.version == null || entry.version === ref.version));
    if (known) return Promise.resolve(known);
    const key = `${state.identity}:${refKey(ref)}`;
    const prior = pending.current.get(key); if (prior) return prior;
    const promise = state.read<{ entry: CatalogueEntry; sourceRevision: number }>("project.catalogue.get", ref).then(value => {
      if (state.identity !== latest.current.identity || value.sourceRevision !== state.snapshot?.project.revision)
        throw new Error("The project changed while this saved record was read. Refresh the catalogue page; local drafts are retained.");
      state.onAdopt(ref, value.entry, state.identity); return value.entry;
    }).finally(() => pending.current.delete(key));
    pending.current.set(key, promise); return promise;
  }, []);
  return <CatalogueContext.Provider value={{ identity, snapshot, read, keep, resolve, adopt }}>{children}</CatalogueContext.Provider>;
}

/** Keep explicit selections available; changing a page never replaces an editor draft. */
export function useCataloguePins(refs: CatalogueRef[]): string {
  const service = useContext(CatalogueContext); const owner = useId();
  const [error, setError] = useState(""); const key = JSON.stringify(refs.filter(ref => ref.entryId));
  useEffect(() => {
    let current = true;
    if (!service) return;
    const selected = JSON.parse(key) as CatalogueRef[];
    try { service.keep(owner, selected); setError(""); }
    catch (cause) { setError(String(cause)); return; }
    void Promise.all(selected.map(ref => service.resolve(ref))).catch(cause => { if (current) setError(String(cause)); });
    return () => { current = false; service.keep(owner, []); };
  }, [service?.identity, owner, key]);
  return error;
}

/** A declared cohort resolves exact identities, not whichever records fit a recent page. */
export function useCatalogueMany<T>(catalogue: CatalogueKey, entryIds: string[]) {
  const service = useContext(CatalogueContext), key = JSON.stringify([...new Set(entryIds)].sort());
  const [result, setResult] = useState<{ identity: string; key: string; value: CatalogueMany<T> }>();
  const [error, setError] = useState("");
  useEffect(() => {
    let current = true; setError("");
    if (!service || key === "[]") { setResult(undefined); return; }
    const ids = JSON.parse(key) as string[];
    if (ids.length > 200) { setError("Choose at most 200 records for this exact cohort lookup."); return; }
    void service.read<CatalogueMany<T>>("project.catalogue.getMany", { catalogue, entryIds: ids }).then(value => {
      if (!current) return;
      if (value.sourceRevision !== service.snapshot?.project.revision) throw new Error("The project changed while the selected cohort was read. Refresh saved project state; local drafts are retained.");
      setResult({ identity: service.identity, key, value });
    }).catch(cause => { if (current) { setError(String(cause)); setResult(undefined); } });
    return () => { current = false; };
  }, [service?.identity, catalogue, key]);
  const value = result?.identity === service?.identity && result?.key === key ? result.value : undefined;
  return { entries: value?.entries ?? [], missingIds: value?.missingIds ?? [], ready: key === "[]" || !!value, error };
}

export default function WorkbenchCatalogueBrowser({ catalogues, title = "Browse retained records", disabled = false,
  onChoose }: { catalogues: CatalogueKey[]; title?: string; disabled?: boolean;
    onChoose?: (catalogue: CatalogueKey, entry: CatalogueEntry) => void }) {
  const service = useContext(CatalogueContext); const owner = useId();
  const [opened, setOpened] = useState(false), [catalogue, setCatalogue] = useState(catalogues[0]);
  const [selected, setSelected] = useState<CatalogueRef[]>([]);
  const [result, setResult] = useState<{ identity: string; catalogue: CatalogueKey; index: number; value: CataloguePage }>();
  const [cursors, setCursors] = useState<(string | undefined)[]>([undefined]);
  const [loading, setLoading] = useState(false), [error, setError] = useState(""), [exactId, setExactId] = useState("");
  const generation = useRef(0), current = useRef(service); current.current = service;
  const pinsError = useCataloguePins(selected);
  const load = async (index = 0, cursor?: string) => {
    const start = current.current; if (!start) return;
    const token = ++generation.current; setLoading(true); setError("");
    try {
      const value = await start.read<CataloguePage>("project.catalogue", { catalogue, limit: 25, ...(cursor ? { cursor } : {}) });
      if (token !== generation.current || current.current?.identity !== start.identity) return;
      if (value.sourceRevision !== start.snapshot?.project.revision) throw new Error("The project changed while this catalogue page was read. Refresh saved project state before selecting a record.");
      setResult({ identity: start.identity, catalogue, index, value });
      setCursors(old => [...old.slice(0, index + 1), ...(value.nextCursor ? [value.nextCursor] : [])]);
    } catch (cause) { if (token === generation.current) { setError(String(cause)); setResult(undefined); setCursors([undefined]); } }
    finally { if (token === generation.current) setLoading(false); }
  };
  useEffect(() => { generation.current++; setResult(undefined); setCursors([undefined]); if (opened) void load(); return () => { generation.current++; }; }, [opened, service?.identity, catalogue]);
  useEffect(() => { setSelected([]); }, [service?.snapshot?.project.id]);
  const choose = async (entryId: string, entry?: CatalogueEntry) => {
    const start = current.current; if (!start) return;
    const ref = { catalogue, entryId }, next = [...selected.filter(item => refKey(item) !== refKey(ref)), ref];
    setError("");
    try {
      // Reserve the bounded pin before adoption. Keep the prior selection if the
      // project-wide pin budget would be exceeded.
      start.keep(owner, next);
      const value = entry ?? await start.resolve(ref);
      if (current.current?.identity !== start.identity) return;
      start.adopt(ref, value); setSelected(next); onChoose?.(catalogue, value);
    } catch (cause) { setError(String(cause)); }
    finally { start.keep(owner, []); }
  };
  const page = result?.identity === service?.identity && result?.catalogue === catalogue ? result : undefined;
  const info = service?.snapshot?.cataloguePages?.[catalogue];
  return <details className="workbench-catalogue-browser" open={opened} onToggle={event => setOpened(event.currentTarget.open)}>
    <summary>{title}{catalogues.length === 1 && info ? ` · ${info.total} retained` : ""}</summary>
    <p>Recent records are a bounded view. Add an older record to the existing controls without replacing their drafts. Selection stays available across project refreshes.</p>
    <fieldset disabled={disabled || loading}><legend className="sr-only">{title}</legend>
      {catalogues.length > 1 ? <label>Record type<select value={catalogue} onChange={event => setCatalogue(event.target.value as CatalogueKey)}>{catalogues.map(key => <option key={key} value={key}>{catalogueNames[key]}</option>)}</select></label> : null}
      {error || pinsError ? <p className="workbench-error" role="alert">{error || pinsError}</p> : null}
      {page ? <><p>{page.value.total} retained · page {page.index + 1} · {page.value.returned} rows. These rows do not define an analysis or specimen scope.</p>
        <ul>{page.value.entries.map(entry => { const id = catalogueEntryId(catalogue, entry); return <li key={id}><span>{catalogueLabel(catalogue, entry)}<small className="workbench-project-path">{id}</small></span><button className="cc-btn" onClick={() => void choose(id, entry)}>Use in controls</button></li>; })}</ul>
        <div className="workbench-actions"><button className="cc-btn" disabled={!page.index} onClick={() => void load(page.index - 1, cursors[page.index - 1])}>Previous records</button><button className="cc-btn" disabled={!page.value.nextCursor} onClick={() => void load(page.index + 1, page.value.nextCursor!)}>Next records</button><button className="cc-btn" onClick={() => void load()}>Refresh record page</button></div></> : null}
      <details><summary>Find an exact retained record</summary><label>Record ID<input value={exactId} onChange={event => setExactId(event.target.value)} /></label><button className="cc-btn" disabled={!exactId.trim()} onClick={() => void choose(exactId.trim())}>Use exact record</button></details>
      {selected.length ? <details><summary>Records kept available ({selected.length})</summary><ul>{selected.map(ref => <li key={refKey(ref)}>{catalogueNames[ref.catalogue]} · {ref.entryId}<button className="cc-btn" onClick={() => setSelected(old => old.filter(item => refKey(item) !== refKey(ref)))}>Release from browser</button></li>)}</ul><p>Releasing a browser record does not delete it or clear an editor that still selects it.</p></details> : null}
    </fieldset>{loading ? <p role="status">Reading retained record page…</p> : null}
  </details>;
}
