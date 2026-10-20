import { useEffect, useRef, useState } from "react";
import type { ModelCatalogue } from "../../../../shared/workbench/modelProtocol";

type Read = <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
let cached: ModelCatalogue | undefined;
let pending: Promise<ModelCatalogue> | undefined;
function load(read: Read): Promise<ModelCatalogue> {
  if (cached) return Promise.resolve(cached);
  if (!pending) pending = read<ModelCatalogue>("model.catalog").then((catalogue) => {
    cached = catalogue; return catalogue;
  }).finally(() => { pending = undefined; });
  return pending;
}

/** One immutable runtime catalogue shared by registration and workflow editors. */
export default function useModelCatalogue(read: Read) {
  const latest = useRef(read); latest.current = read;
  const [catalogue, setCatalogue] = useState(cached);
  const [error, setError] = useState("");
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let active = true;
    setError("");
    void load(latest.current).then((value) => { if (active) setCatalogue(value); })
      .catch((cause) => { if (active) setError(String(cause)); });
    return () => { active = false; };
  }, [attempt]);
  return { catalogue, error, retry: () => setAttempt((value) => value + 1) };
}
