import type { DetectionDTO } from "../../kernel/types";
import type { SavedRun } from "../../kernel/workflow/workflowDocuments";

const TASK_LABELS = { countCells: "Cell count", nuclei: "Nuclei", markerPositive: "Marker-positive cells", woundClosure: "Wound closure" };

export function RunProvenance({ detection, run, reviewPxPerUm, confidence, loading = false, error }: {
  detection: DetectionDTO | null; run: SavedRun | null; reviewPxPerUm: number; confidence: number; loading?: boolean; error?: string;
}) {
  return <section className="rv-provenance" aria-label="Analysis and review settings">
    <div><strong>Saved analysis</strong><span>{detection?.detectorId ?? "No saved detection"}</span>
      {loading ? <span>Loading saved analysis settings…</span> : run ? <><span>{new Date(run.ranAt).toLocaleString()} · {TASK_LABELS[run.task]}</span>
        <span>{run.params.pxPerUm} px/µm · {run.calibrationSource} · analysis confidence {run.params.confidenceThreshold}</span>
        <details><summary>Saved run settings</summary><dl>
          <dt>Expected diameter</dt><dd>{run.params.expectedDiameterUm ? `${run.params.expectedDiameterUm} µm` : "Auto"}</dd>
          <dt>Size thresholds</dt><dd>{run.params.smallThresholdUm}, {run.params.largeThresholdUm} µm</dd>
          <dt>Channels</dt><dd>{run.params.channels.join(", ")} · segmentation {run.params.segmentChannel ?? "automatic"}</dd>
          <dt>Z projection</dt><dd>{run.params.zProjection ?? "Not recorded"}</dd>
          <dt>Background subtraction</dt><dd>{run.params.backgroundSubtract ? `On (${run.params.rollingBallRadius} px)` : "Off"}</dd>
          <dt>Split touching cells</dt><dd>{run.params.watershedSplit ? `On (${run.params.watershedMinDistanceUm} µm)` : "Off"}</dd>
        </dl></details></> : <span>{error ?? "Run settings and analysis calibration are unknown for this detection."}</span>}
    </div>
    <div><strong>Current review</strong><span>{reviewPxPerUm} px/µm · visible confidence ≥ {confidence}</span><span>Mask edits and display filters may differ from the saved analysis.</span></div>
  </section>;
}
