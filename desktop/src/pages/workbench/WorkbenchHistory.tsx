import { useEffect, useRef, useState } from "react";
import type { HistoryPage } from "../../../../shared/workbench/pagingProtocol";

export default function WorkbenchHistory({ revision, read }: { revision: number;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T> }) {
  const [opened, setOpened] = useState(false), [page, setPage] = useState<HistoryPage>();
  const [index, setIndex] = useState(0), [cursors, setCursors] = useState<(string | undefined)[]>([undefined]);
  const [error, setError] = useState(""), [loading, setLoading] = useState(false);
  const epoch = useRef(0), reader = useRef(read); reader.current = read;
  const load = async (pageIndex = 0, cursor?: string) => {
    const generation = ++epoch.current; setLoading(true); setError("");
    try {
      const value = await reader.current<HistoryPage>("project.history", { limit: 100, ...(cursor ? { cursor } : {}) });
      if (generation !== epoch.current) return;
      setPage(value); setIndex(pageIndex); setCursors(previous => [...previous.slice(0, pageIndex + 1), ...(value.nextCursor ? [value.nextCursor] : [])]);
    } catch (cause) { if (generation === epoch.current) { setError(String(cause)); setPage(undefined); } }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  useEffect(() => { epoch.current++; setPage(undefined); setCursors([undefined]); if (opened) void load(); return () => { epoch.current++; }; }, [opened, revision]);
  return <details open={opened} onToggle={event => setOpened(event.currentTarget.open)}><summary>Operation history</summary>
    {error ? <p role="alert">{error}</p> : null}
    {page ? <><p>{page.total} retained operations · page {index + 1} · revision {page.sourceRevision}</p><ol>{page.history.map((item, row) => <li key={`${item.revision}-${row}`}>{item.operation} · revision {item.revision}{item.actor?.name ? ` · ${item.actor.name}` : ""}</li>)}</ol></> : null}
    <div className="workbench-actions"><button className="cc-btn" disabled={loading} onClick={() => void load()}>Refresh history</button><button className="cc-btn" disabled={loading || index === 0} onClick={() => void load(index - 1, cursors[index - 1])}>Previous operations</button><button className="cc-btn" disabled={loading || !page?.nextCursor} onClick={() => void load(index + 1, page!.nextCursor!)}>Next operations</button></div>
  </details>;
}
