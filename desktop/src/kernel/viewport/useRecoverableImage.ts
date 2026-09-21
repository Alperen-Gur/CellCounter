import { useCallback, useLayoutEffect, useRef, useState } from "react";
import { recoverImageSource } from "./imageRecovery";

type Attempt = { original: string; src?: string; error?: string; pending?: boolean };

export function useRecoverableImage(original: string | null | undefined) {
  const [attempt, setAttempt] = useState<Attempt | null>(null);
  const generation = useRef(0);
  useLayoutEffect(() => {
    generation.current += 1;
    setAttempt(null);
    return () => { generation.current += 1; };
  }, [original]);
  const current = attempt?.original === original ? attempt : null;
  const onError = useCallback(() => {
    if (!original || current?.pending || current?.error) return;
    if (current?.src) {
      setAttempt({ original, error: "Image preview unavailable. Check that the imported image still exists and that CellCounter can read its data folder." });
      return;
    }
    setAttempt({ original, pending: true });
    const ticket = generation.current;
    void recoverImageSource(original).then(
      src => { if (ticket === generation.current) setAttempt({ original, src }); },
      error => { if (ticket === generation.current) setAttempt({ original, error: String(error) }); },
    );
  }, [original, current]);
  return { src: current?.src ?? original ?? undefined, error: current?.error, onError };
}
