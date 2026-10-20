import { useEffect, useRef, useState } from "react";
import type { WorkbenchImage } from "../../../../shared/workbench/protocol";
import type { AnnotationImportArguments, AnnotationImportPreview, AnnotationRecord } from "../../../../shared/workbench/annotationProtocol";

type Props = {
  image?: WorkbenchImage; revision: number; busy: boolean; dirty: boolean;
  read: <T>(operation: string, args: Record<string, unknown>) => Promise<T>;
  chooseFile: (selected: (path: string) => void) => Promise<void>;
  commit: (args: AnnotationImportArguments, accepted: (record: AnnotationRecord) => void) => Promise<void>;
  onImported: (record: AnnotationRecord) => void;
};

export default function WorkbenchAnnotationImport({ image, revision, busy, dirty, read, chooseFile, commit, onImported }: Props) {
  const [path, setPath] = useState("");
  const [preview, setPreview] = useState<{ result: AnnotationImportPreview; revision: number; path: string }>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const epoch = useRef(0);
  const current = preview?.revision === revision && preview.path === path && preview.result.imageId === image?.id;
  const result = current ? preview?.result : undefined;
  const locked = busy || loading || dirty || !image;
  useEffect(() => {
    epoch.current++; setPreview(undefined); setLoading(false); setError("");
    return () => { epoch.current++; };
  }, [path, image?.id, revision, dirty]);

  const choose = () => {
    const generation = epoch.current;
    return chooseFile((chosen) => {
      if (generation === epoch.current) { setPreview(undefined); setPath(chosen); }
    });
  };
  const inspect = async () => {
    if (!image || !path || dirty) return;
    const generation = ++epoch.current; setLoading(true); setPreview(undefined); setError("");
    try {
      const value = await read<AnnotationImportPreview>("annotation.import.preview", { imageId: image.id, path });
      if (generation === epoch.current) setPreview({ result: value, revision, path });
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  const apply = () => {
    if (!image || !result || dirty || !result.compatibility.sourceMatches) return;
    return commit({ imageId: image.id, path, previewFingerprint: result.previewFingerprint }, (record) => {
      epoch.current++; setPreview(undefined); setError(""); onImported(record);
    });
  };
  return <details>
    <summary>Import annotation JSON</summary>
    <p>Import a CellCounter geometry export onto an image with the same source pixels and grid.
      The imported geometry receives a new annotation identity.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {dirty ? <p>Save or discard the current image or annotation edits before importing another annotation.</p> : null}
    <fieldset disabled={locked}>
      <button type="button" className="cc-btn" onClick={() => void choose()}>Choose annotation JSON…</button>
      {path ? <p className="workbench-project-path">{path}</p> : null}
      {image ? <p>Target image: {image.name}</p> : null}
      <div className="workbench-actions">
        <button type="button" className="cc-btn" disabled={!path} onClick={() => void inspect()}>Preview annotation import</button>
        <button type="button" className="cc-btn" disabled={!result?.compatibility.sourceMatches || !result?.previewFingerprint}
          onClick={() => void apply()}>Import as new annotation</button>
      </div>
    </fieldset>
    {result ? <section aria-label="Annotation import preview">
      <h4>{result.annotation.name}</h4>
      <p>{result.annotation.geometry.type} · {result.annotation.geometry.points.length.toLocaleString()} vertices ·{" "}
        {result.annotation.target === "plane"
          ? `channel ${(result.annotation.selection.sourceParameters?.channel ?? 0) + 1}, ${result.annotation.selection.sourceParameters?.zProjection ?? "max"} projection`
          : `${result.annotation.selection.plane?.toUpperCase() ?? "XY"} slice ${(result.annotation.selection.index ?? 0) + 1}, time point ${(result.annotation.selection.timeIndex ?? 0) + 1}, channel ${(result.annotation.selection.channel ?? 0) + 1}`}</p>
      <p>{result.compatibility.sourceMatches ? "Source pixels and grid match." : "The source does not match this image."}{" "}
        {result.compatibility.calibrationMatches ? "Calibration matches." :
          "Calibration differs. Imported geometry keeps its pixel coordinates; measurements use this target image’s current calibration."}</p>
      {result.annotation.notes ? <p>{result.annotation.notes}</p> : null}
      {result.notes.length ? <p>{result.notes.join(" ")}</p> : null}
      <p className="workbench-project-path">{result.source.name} · {result.source.bytes.toLocaleString()} bytes · SHA-256: {result.source.sha256}</p>
    </section> : null}
  </details>;
}
