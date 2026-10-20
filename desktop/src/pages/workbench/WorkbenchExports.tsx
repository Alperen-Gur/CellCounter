import { useEffect, useRef, useState } from "react";
import type { AnalysisParameters, WorkbenchImage } from "../../../../shared/workbench/protocol";
import type { VolumeWorkflowConfiguration } from "../../../../shared/workbench/volumeProtocol";
import type { ImageExportFormat } from "../../../../shared/workbench/exportProtocol";

type Props = {
  image?: WorkbenchImage;
  parameters: AnalysisParameters;
  busy: boolean;
  volumeMode: boolean;
  volume?: VolumeWorkflowConfiguration;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  exportImage: (format: ImageExportFormat, args: Record<string, unknown>) => Promise<void>;
};

export default function WorkbenchExports({ image, parameters, busy, volumeMode, volume, read, exportImage }: Props) {
  const [formats, setFormats] = useState<ImageExportFormat[]>([]);
  const [formatId, setFormatId] = useState("labels-ome-tiff");
  const [maxSize, setMaxSize] = useState(2048);
  const [error, setError] = useState("");
  const latest = useRef(read); latest.current = read;
  const target = volumeMode ? "volume" : "plane";
  const format = formats.find((item) => item.id === formatId);
  const hasAnalysis = volumeMode ? Boolean(image?.volumeFrameCount) : image?.analysisRevision != null;
  const source = format?.requiresAnalysis && image?.parameters ? image.parameters : parameters;
  const selection = volumeMode && volume
    ? { target, timeIndex: volume.timeIndex, channel: volume.channel }
    : { target, sourceParameters: { channel: source.channel, zProjection: source.zProjection } };

  useEffect(() => {
    let active = true;
    void latest.current<{ formats: ImageExportFormat[] }>("image.export.catalogue").then((result) => {
      if (active) setFormats(result.formats);
    }).catch((cause) => { if (active) setError(String(cause)); });
    return () => { active = false; };
  }, []);
  useEffect(() => {
    if (formats.length && !formats.some((item) => item.id === formatId && item.targets.includes(target)))
      setFormatId(formats.find((item) => item.targets.includes(target))?.id ?? "");
  }, [formats, formatId, target]);

  return <section aria-label="Export selected image">
    <h3>Export selected image</h3>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <fieldset disabled={busy || !image}>
      <label>File contents<select value={formatId} onChange={(event) => setFormatId(event.target.value)}>
        {!formats.length ? <option value="">Loading export formats…</option> : null}
        {formats.filter((item) => item.targets.includes(target)).map((item) =>
          <option key={item.id} value={item.id}>{item.name}</option>)}
      </select></label>
      {format ? <p>{format.description}</p> : null}
      {image ? <p>{image.name} · {volumeMode
        ? `full volume at time ${(volume?.timeIndex ?? 0) + 1}, channel ${(volume?.channel ?? 0) + 1}`
        : `channel ${source.channel + 1}, ${source.zProjection === "middle" ? "middle Z plane" : `${source.zProjection} Z projection`}`}
        {format?.requiresAnalysis ? " · saved analysis" : ""}</p> : null}
      {image?.validSupport?.present ? <p>
        {(image.validSupport.fraction * 100).toLocaleString(undefined, { maximumFractionDigits: 2 })}% of this image
        contains supported samples. The support-mask export identifies the acquired region; filled samples are
        excluded from object measurements.
      </p> : null}
      {formatId === "overlay-png" ? <label>Maximum display dimension (pixels)
        <input type="number" min={64} max={2048} step={1} value={maxSize}
          onChange={(event) => setMaxSize(Number(event.target.value))} />
      </label> : null}
      {format?.requiresAnalysis && !hasAnalysis ? <p>Save an analysis for this image before exporting its objects.</p> : null}
      <button className="cc-btn" disabled={!format || !image || !format.targets.includes(target) ||
        (format.requiresAnalysis && !hasAnalysis) || (volumeMode && !volume) ||
        (formatId === "overlay-png" && (!Number.isInteger(maxSize) || maxSize < 64 || maxSize > 2048))}
        onClick={() => {
          if (format && image) void exportImage(format, { imageId: image.id, format: format.id, ...selection,
            ...(format.id === "overlay-png" ? { maxSize } : {}) });
        }}>Save image export…</button>
    </fieldset>
    <p>Export uses saved masks and measurements. Choose a new file name; existing files are preserved.
      Use Export package to keep the complete analysis and its history.</p>
  </section>;
}
