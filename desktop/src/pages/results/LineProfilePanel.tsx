import { useEffect, useMemo, useState } from "react";
import { invoke } from "@tauri-apps/api/core";

import type { ImageDTO } from "../../kernel/types";

interface LineProfilePoint {
  distancePx: number;
  distanceUm: number;
  value: number;
}

export function LineProfilePanel({
  image,
  imageSrc,
  pxPerUm,
}: {
  image: ImageDTO;
  imageSrc: string | null;
  pxPerUm: number;
}) {
  const [start, setStart] = useState<[number, number]>([0, image.heightPx / 2]);
  const [end, setEnd] = useState<[number, number]>([
    Math.max(0, image.widthPx - 1),
    image.heightPx / 2,
  ]);
  const [placing, setPlacing] = useState<"start" | "end">("start");
  const [channel, setChannel] = useState("luma");
  const [points, setPoints] = useState<LineProfilePoint[]>([]);
  const [error, setError] = useState("");
  const [running, setRunning] = useState(false);

  useEffect(() => {
    setStart([0, image.heightPx / 2]);
    setEnd([Math.max(0, image.widthPx - 1), image.heightPx / 2]);
    setPoints([]);
    setError("");
  }, [image.id, image.widthPx, image.heightPx]);

  const plot = useMemo(() => {
    if (points.length < 2) return "";
    const stride = Math.max(1, Math.ceil(points.length / 600));
    const sampled = points.filter((_, index) => index % stride === 0 || index === points.length - 1);
    const maximum = Math.max(...sampled.map((point) => point.value), 1e-9);
    const totalDistance = points[points.length - 1].distanceUm;
    if (!Number.isFinite(totalDistance) || totalDistance <= 0) return "";
    return sampled
      .map((point, index) => {
        const x = (point.distanceUm / totalDistance) * 240;
        const y = 74 - (point.value / maximum) * 68;
        return `${index === 0 ? "M" : "L"}${x.toFixed(2)},${y.toFixed(2)}`;
      })
      .join(" ");
  }, [points]);

  const sample = async () => {
    if (Math.hypot(end[0] - start[0], end[1] - start[1]) < 1e-6) {
      setError("Choose two different endpoints before sampling the line.");
      setPoints([]);
      return;
    }
    setRunning(true);
    setError("");
    try {
      const result = await invoke<LineProfilePoint[]>("line_profile", {
        imageId: image.id,
        startX: start[0],
        startY: start[1],
        endX: end[0],
        endY: end[1],
        pxPerUm,
        channel,
        samples: null,
      });
      setPoints(result);
    } catch (reason) {
      setError(String(reason));
      setPoints([]);
    } finally {
      setRunning(false);
    }
  };

  const setPoint = (event: React.MouseEvent<HTMLImageElement>) => {
    const rect = event.currentTarget.getBoundingClientRect();
    const point: [number, number] = [
      ((event.clientX - rect.left) / rect.width) * image.widthPx,
      ((event.clientY - rect.top) / rect.height) * image.heightPx,
    ];
    if (placing === "start") {
      setStart(point);
      setPlacing("end");
    } else {
      setEnd(point);
      setPlacing("start");
    }
  };

  return (
    <section className="rv-assay" aria-label="Line profile">
      <div className="rv-assay__title">Line profile</div>
      <p className="rv-assay__hint">
        Click the preview to place the {placing} point, then sample calibrated intensity.
      </p>
      {imageSrc ? (
        <div className="rv-profile-preview">
          <img src={imageSrc} alt="Select line profile endpoints" onClick={setPoint} draggable={false} />
          <span
            className="rv-profile-dot rv-profile-dot--start"
            style={{ left: `${(start[0] / image.widthPx) * 100}%`, top: `${(start[1] / image.heightPx) * 100}%` }}
          />
          <span
            className="rv-profile-dot rv-profile-dot--end"
            style={{ left: `${(end[0] / image.widthPx) * 100}%`, top: `${(end[1] / image.heightPx) * 100}%` }}
          />
        </div>
      ) : null}
      <div className="rv-assay__controls">
        <select value={channel} onChange={(event) => setChannel(event.target.value)} aria-label="Profile channel">
          <option value="luma">Luminance</option>
          <option value="red">Red</option>
          <option value="green">Green</option>
          <option value="blue">Blue</option>
        </select>
        <button type="button" onClick={() => void sample()} disabled={running}>
          {running ? "Sampling…" : "Sample line"}
        </button>
      </div>
      {plot ? (
        <div className="rv-profile-plot">
          <svg viewBox="0 0 240 80" role="img" aria-label="Intensity along sampled line">
            <path d={plot} fill="none" stroke="currentColor" strokeWidth="1.5" vectorEffect="non-scaling-stroke" />
          </svg>
          <span>0</span>
          <span>{points[points.length - 1].distanceUm.toFixed(1)} µm</span>
        </div>
      ) : null}
      {error ? <div className="rv-assay__error" role="alert">{error}</div> : null}
    </section>
  );
}
