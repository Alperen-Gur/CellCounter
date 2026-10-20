import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import type { WorkbenchImage } from "../../../../shared/workbench/protocol";
import type { ImagePage, ImagePageFilters } from "../../../../shared/workbench/pagingProtocol";

type Read = <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
type Library = { identity: string; revision: number; seed: WorkbenchImage[]; read: Read;
  image: (id: string) => Promise<WorkbenchImage> };
const LibraryContext = createContext<Library | null>(null);

/** One bounded catalogue service; individual pickers retain IDs, not whole-library snapshots. */
export function WorkbenchImageProvider({ projectId, revision, images, read, children }: {
  projectId: string; revision: number; images: WorkbenchImage[]; read: Read; children: ReactNode;
}) {
  const identity = `${projectId}:${revision}`;
  const cache = useRef<{ identity: string; values: Map<string, WorkbenchImage>; pending: Map<string, Promise<WorkbenchImage>> }>({ identity, values: new Map(), pending: new Map() });
  if (cache.current.identity !== identity) cache.current = { identity, values: new Map(), pending: new Map() };
  for (const image of images) cache.current.values.set(image.id, image);
  const latest = useRef(read); latest.current = read;
  const image = useCallback((id: string): Promise<WorkbenchImage> => {
    const state = cache.current;
    const known = state.values.get(id); if (known) return Promise.resolve(known);
    const pending = state.pending.get(id); if (pending) return pending;
    const request = latest.current<{ image: WorkbenchImage }>("image.get", { imageId: id }).then(result => {
      if (cache.current !== state) throw new Error("The project changed while this image was read. Refresh its selection.");
      state.values.set(id, result.image);
      while (state.values.size > 128) state.values.delete(state.values.keys().next().value!);
      return result.image;
    }).finally(() => { state.pending.delete(id); });
    state.pending.set(id, request); return request;
  }, [identity]);
  return <LibraryContext.Provider value={{ identity, revision, seed: images, read, image }}>{children}</LibraryContext.Provider>;
}

export function useWorkbenchImage(id: string): WorkbenchImage | undefined {
  const library = useContext(LibraryContext);
  const [resolved, setResolved] = useState<{ identity: string; image: WorkbenchImage }>();
  const known = library?.seed.find(item => item.id === id);
  useEffect(() => {
    let active = true;
    if (library && id && !known) void library.image(id).then(image => {
      if (active) setResolved({ identity: library.identity, image });
    }).catch(() => { if (active) setResolved(undefined); });
    return () => { active = false; };
  }, [library?.identity, id, !!known]);
  return known ?? (resolved && library && resolved.identity === library.identity && resolved.image.id === id ? resolved.image : undefined);
}

type Props = {
  label: string; selectedIds: string[]; onChange: (ids: string[]) => void; multiple?: boolean;
  disabled?: boolean; initialOpen?: boolean; maxSelected?: number; filters?: ImagePageFilters;
  eligible?: (image: WorkbenchImage) => boolean; eligibilityNote?: string; onOpen?: (imageId: string) => void;
};
export default function WorkbenchImageSelector({ label, selectedIds, onChange, multiple = false,
  disabled = false, initialOpen = false, maxSelected = 1000, filters = {}, eligible, eligibilityNote, onOpen }: Props) {
  const library = useContext(LibraryContext);
  const [opened, setOpened] = useState(initialOpen);
  const [query, setQuery] = useState("");
  const [submitted, setSubmitted] = useState("");
  const [archiveScope, setArchiveScope] = useState<"active" | "all" | "archived">(filters.archiveScope ?? "active");
  const [result, setResult] = useState<{ identity: string; key: string; page: ImagePage; index: number }>();
  const [cursors, setCursors] = useState<(string | undefined)[]>([undefined]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const names = useRef(new Map<string, string>());
  const epoch = useRef(0);
  const current = useRef({ library, filters, eligible, selectedIds, onChange });
  current.current = { library, filters, eligible, selectedIds, onChange };
  const key = JSON.stringify({ ...filters, query: submitted, archiveScope });
  const selectedImage = useWorkbenchImage(!multiple ? selectedIds[0] ?? "" : "");
  const readPage = async (index: number, cursor?: string) => {
    const active = current.current.library; if (!active) return;
    const generation = ++epoch.current; setLoading(true); setError("");
    try {
      const value = await active.read<ImagePage>("image.list", { ...current.current.filters, query: submitted, archiveScope, limit: 50, ...(cursor ? { cursor } : {}) });
      if (generation !== epoch.current || current.current.library?.identity !== active.identity) return;
      if (value.sourceRevision !== active.revision) throw new Error("The project changed while this image page was read. Refresh saved project state before selecting images.");
      for (const image of value.images) names.current.set(image.id, image.name);
      while (names.current.size > maxSelected + 50) names.current.delete(names.current.keys().next().value!);
      setResult({ identity: active.identity, key, page: value, index });
      setCursors(old => [...old.slice(0, index + 1), ...(value.nextCursor ? [value.nextCursor] : [])]);
    } catch (cause) { if (generation === epoch.current) { setError(String(cause)); setResult(undefined); setCursors([undefined]); } }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  useEffect(() => {
    epoch.current++; setResult(undefined); setCursors([undefined]);
    if (opened && library?.identity) void readPage(0);
    return () => { epoch.current++; };
  }, [opened, library?.identity, key]);
  const page = result && library && result.identity === library.identity && result.key === key ? result : undefined;
  const choose = (id: string, checked: boolean) => {
    if (!multiple) { onChange(checked ? [id] : []); return; }
    if (checked && !selectedIds.includes(id) && selectedIds.length >= maxSelected) { setError(`Select at most ${maxSelected} images for this operation.`); return; }
    onChange(checked ? [...new Set([...selectedIds, id])] : selectedIds.filter(value => value !== id));
  };
  const selectMatching = async () => {
    const active = current.current.library; if (!active) return;
    const generation = ++epoch.current; setLoading(true); setError("");
    try {
      const ids = new Set(current.current.selectedIds); let cursor: string | undefined;
      let scanned = 0;
      do {
        const value = await active.read<ImagePage>("image.list", { ...current.current.filters, query: submitted, archiveScope, limit: 500, ...(cursor ? { cursor } : {}) });
        if (generation !== epoch.current || current.current.library?.identity !== active.identity) return;
        if (value.sourceRevision !== active.revision) throw new Error("The project changed while this image scope was read. Refresh saved project state; the previous explicit selection is retained.");
        scanned += value.images.length;
        for (const image of value.images) if (!current.current.eligible || current.current.eligible(image)) { ids.add(image.id); names.current.set(image.id, image.name); }
        while (names.current.size > maxSelected + 50) names.current.delete(names.current.keys().next().value!);
        if (ids.size > maxSelected || scanned > 5000) throw new Error(`This scope exceeds the bounded selection. Narrow the search or collection; at most ${maxSelected} selected images and 5,000 searched rows are allowed.`);
        cursor = value.nextCursor ?? undefined;
      } while (cursor);
      current.current.onChange([...ids]);
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  return <details className="workbench-image-selector" open={opened} onToggle={event => setOpened(event.currentTarget.open)}>
    <summary>{label} · {multiple ? `${selectedIds.length} selected` : selectedImage?.name ?? (selectedIds[0] ? names.current.get(selectedIds[0]) ?? selectedIds[0] : "Choose image")}</summary>
    <fieldset disabled={disabled || loading}><legend className="sr-only">{label}</legend>
      <label>Search images<input value={query} onChange={event => setQuery(event.target.value)} onKeyDown={event => { if (event.key === "Enter") { event.preventDefault(); setSubmitted(query.trim()); } }} /></label>
      <label>Visibility<select value={archiveScope} onChange={event => setArchiveScope(event.target.value as typeof archiveScope)}><option value="active">Active images</option><option value="all">All retained images</option><option value="archived">Archived images</option></select></label>
      <button type="button" className="cc-btn" onClick={() => { if (submitted !== query.trim()) setSubmitted(query.trim()); else void readPage(0); }}>Search images</button>
      {eligibilityNote ? <p>{eligibilityNote}</p> : null}
      {error ? <p role="alert" className="workbench-error">{error}</p> : null}
      {page ? <><p>{page.page.total} matching images · page {page.index + 1}. Selection is retained across pages.</p><ul>{page.page.images.map(image => {
        const allowed = !eligible || eligible(image); const checked = selectedIds.includes(image.id);
        return <li key={image.id}><label><input type={multiple ? "checkbox" : "radio"} name={multiple ? undefined : label} checked={checked} disabled={!allowed} onChange={event => choose(image.id, event.target.checked)} />
          <span><strong>{image.name}</strong><small>{image.width} × {image.height} · {image.channels} channels · {image.status}{image.archived ? " · archived" : ""}{!allowed ? " · incompatible with this operation" : ""}</small></span></label>{onOpen ? <button type="button" className="cc-btn" onClick={() => onOpen(image.id)}>Open image</button> : null}</li>;
      })}</ul><div className="workbench-actions"><button type="button" className="cc-btn" disabled={!page.index} onClick={() => void readPage(page.index - 1, cursors[page.index - 1])}>Previous images</button><button type="button" className="cc-btn" disabled={!page.page.nextCursor} onClick={() => void readPage(page.index + 1, page.page.nextCursor!)}>Next images</button>
        {multiple ? <button type="button" className="cc-btn" onClick={() => void selectMatching()}>Select matching images (up to {maxSelected})</button> : null}</div></> : null}
      {selectedIds.length ? <><p>{multiple ? `${selectedIds.length} explicit image IDs selected.` : `Selected: ${selectedImage?.name ?? selectedIds[0]}`}</p><button type="button" className="cc-btn" onClick={() => onChange([])}>Clear selection</button></> : null}
    </fieldset>
    {loading ? <p role="status">Reading bounded image metadata…</p> : null}
  </details>;
}
