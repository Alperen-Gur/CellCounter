import { useEffect, useRef, useState } from "react";
import type { GraphCatalogue } from "../../../../shared/workbench/graphProtocol";

type Read = <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
let cached: GraphCatalogue | undefined;
let pending: Promise<GraphCatalogue> | undefined;
function load(read: Read) {
  if (cached) return Promise.resolve(cached);
  if (!pending) pending = read<GraphCatalogue>("workflow.graph.catalogue").then((result) => {
    cached = result; return result;
  }).finally(() => { pending = undefined; });
  return pending;
}
export default function useGraphCatalogue(read: Read, enabled: boolean) {
  const [catalogue, setCatalogue] = useState(cached);
  const [error, setError] = useState("");
  const [attempt, setAttempt] = useState(0);
  const latest = useRef(read); latest.current = read;
  useEffect(() => {
    if (!enabled || catalogue) return;
    let current = true; setError("");
    void load(latest.current).then((result) => { if (current) setCatalogue(result); })
      .catch((cause) => { if (current) setError(String(cause)); });
    return () => { current = false; };
  }, [enabled, !!catalogue, attempt]);
  return { catalogue, error, retry: () => setAttempt((value) => value + 1) };
}
