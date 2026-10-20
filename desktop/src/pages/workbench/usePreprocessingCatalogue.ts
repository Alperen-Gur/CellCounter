import { useEffect, useRef, useState } from "react";
import type { PreprocessingCatalogue } from "../../../../shared/workbench/preprocessingProtocol";

type Read = <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
// This descriptor is projectless and immutable for the bundled runtime. Share
// its in-flight request as well as its value across both recipe editor hosts.
let cached: PreprocessingCatalogue | undefined;
let pending: Promise<PreprocessingCatalogue> | undefined;
function load(read: Read): Promise<PreprocessingCatalogue> {
  if (cached) return Promise.resolve(cached);
  if (!pending) pending = read<PreprocessingCatalogue>("preprocessing.catalogue").then((value) => {
    cached = value; return value;
  }).finally(() => { pending = undefined; });
  return pending;
}

export default function usePreprocessingCatalogue(read: Read) {
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
