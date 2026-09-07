import { useEffect, useState } from "react";
import type { DetectionDTO } from "../../kernel/types";
import { loadWorkflowDocument, type SavedRun } from "../../kernel/workflow/workflowDocuments";
import { knownSavedRun } from "./maskVersions";

export function useSavedRun(imageId: string | undefined, detection: DetectionDTO | null) {
  const [result, setResult] = useState<{ imageId?: string; detection: DetectionDTO | null; run: SavedRun | null; error?: string; loading: boolean }>({ detection: null, run: null, loading: false });
  useEffect(() => {
    let cancelled = false;
    if (!imageId || !detection) {
      setResult({ imageId, detection, run: null, loading: false });
      return;
    }
    setResult({ imageId, detection, run: null, loading: true });
    void loadWorkflowDocument<SavedRun>(`run-${imageId}`).then(value => {
      if (!cancelled) setResult({ imageId, detection, run: knownSavedRun(value, detection), loading: false });
    }).catch(error => {
      if (!cancelled) setResult({ imageId, detection, run: null, loading: false, error: `Saved analysis settings could not be loaded: ${String(error)}` });
    });
    return () => { cancelled = true; };
  }, [imageId, detection]);
  const current = result.imageId === imageId && result.detection === detection;
  return { run: current ? result.run : null, error: current ? result.error : undefined, loading: !current || result.loading };
}
