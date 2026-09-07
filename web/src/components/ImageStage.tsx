import { useCallback, useEffect, useRef, useState } from "react";
import { ImagePlus, Maximize2, Minus, Plus } from "lucide-react";
import type { EditTool, WorkspaceCell, WorkspaceImage } from "../app/types";

interface StageTransform { scale: number; x: number; y: number; }

interface ImageStageProps {
  image?: WorkspaceImage;
  tool: EditTool;
  selectedCellId?: string;
  alternativeCells?: readonly WorkspaceCell[];
  onCellPointer: (x: number, y: number) => void;
  onImport: () => void;
  onRoi: (start: { x: number; y: number }, end: { x: number; y: number }, kind: "include" | "exclude") => void;
}

function fitTransform(width: number, height: number, sourceWidth: number, sourceHeight: number): StageTransform {
  const padding = 36;
  const scale = Math.max(0.01, Math.min((width - padding * 2) / sourceWidth, (height - padding * 2) / sourceHeight));
  return { scale, x: (width - sourceWidth * scale) / 2, y: (height - sourceHeight * scale) / 2 };
}

function drawCell(ctx: CanvasRenderingContext2D, cell: WorkspaceCell, transform: StageTransform, selected: boolean, alternate = false) {
  const x = transform.x + cell.cx * transform.scale;
  const y = transform.y + cell.cy * transform.scale;
  const radius = Math.max(3, cell.diameterPx * transform.scale / 2);
  ctx.beginPath();
  if (cell.contourPx && cell.contourPx.length > 2) {
    cell.contourPx.forEach(([px, py], index) => {
      const vx = transform.x + px * transform.scale;
      const vy = transform.y + py * transform.scale;
      if (index === 0) ctx.moveTo(vx, vy); else ctx.lineTo(vx, vy);
    });
    ctx.closePath();
  } else ctx.arc(x, y, radius, 0, Math.PI * 2);
  ctx.strokeStyle = alternate ? "#fb9b49" : selected ? "#f5c868" : cell.isManual ? "#ffffff" : "#68ead3";
  ctx.lineWidth = selected ? 2.5 : 1.4;
  ctx.shadowColor = "#000";
  ctx.shadowBlur = selected ? 2 : 0;
  ctx.stroke();
  ctx.shadowBlur = 0;
}

export function ImageStage({ image, alternativeCells, tool, selectedCellId, onCellPointer, onImport, onRoi }: ImageStageProps) {
  const hostRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const imageRef = useRef<HTMLImageElement | null>(null);
  const transformRef = useRef<StageTransform>({ scale: 1, x: 0, y: 0 });
  const manualViewRef = useRef(false);
  const panRef = useRef<{ clientX: number; clientY: number; x: number; y: number } | undefined>(undefined);
  const roiStartRef = useRef<{ x: number; y: number } | undefined>(undefined);
  const frameRef = useRef<number | undefined>(undefined);
  const [ready, setReady] = useState(false);

  const paint = useCallback(() => {
    const host = hostRef.current;
    const canvas = canvasRef.current;
    if (!host || !canvas) return;
    const rect = host.getBoundingClientRect();
    const dpr = Math.min(devicePixelRatio, 2);
    const pixelWidth = Math.max(1, Math.floor(rect.width * dpr));
    const pixelHeight = Math.max(1, Math.floor(rect.height * dpr));
    if (canvas.width !== pixelWidth) canvas.width = pixelWidth;
    if (canvas.height !== pixelHeight) canvas.height = pixelHeight;
    canvas.style.width = `${rect.width}px`;
    canvas.style.height = `${rect.height}px`;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (!image || !imageRef.current || !ready) return;
    const transform = manualViewRef.current ? transformRef.current : fitTransform(rect.width, rect.height, image.width, image.height);
    transformRef.current = transform;
    ctx.drawImage(imageRef.current, transform.x, transform.y, image.width * transform.scale, image.height * transform.scale);
    image.cells.forEach((cell) => {
      const radius = Math.max(3, cell.diameterPx * transform.scale / 2);
      const x = transform.x + cell.cx * transform.scale;
      const y = transform.y + cell.cy * transform.scale;
      if (x + radius < 0 || y + radius < 0 || x - radius > rect.width || y - radius > rect.height) return;
      drawCell(ctx, cell, transform, cell.id === selectedCellId);
    });
    for (const cell of alternativeCells ?? []) drawCell(ctx, cell, transform, false, true);
    for (const roi of image.rois) {
      ctx.save();
      ctx.setLineDash([7, 5]);
      ctx.strokeStyle = roi.kind === "include" ? "#79e6d2" : "#ff9b8f";
      ctx.lineWidth = 1.5;
      ctx.strokeRect(transform.x + roi.x * transform.scale, transform.y + roi.y * transform.scale, roi.width * transform.scale, roi.height * transform.scale);
      ctx.restore();
    }
    for (const mark of image.groundTruth) {
      const x = transform.x + mark.x * transform.scale;
      const y = transform.y + mark.y * transform.scale;
      const radius = Math.max(4, mark.diameterPx * transform.scale / 2);
      ctx.beginPath(); ctx.arc(x, y, radius, 0, Math.PI * 2);
      ctx.strokeStyle = "#f5c868"; ctx.lineWidth = 1.7; ctx.stroke();
      ctx.beginPath(); ctx.moveTo(x - 4, y); ctx.lineTo(x + 4, y); ctx.moveTo(x, y - 4); ctx.lineTo(x, y + 4); ctx.stroke();
    }
  }, [image?.objectUrl, image?.width, image?.height, image?.cells, image?.rois, image?.groundTruth, ready, selectedCellId, alternativeCells]);

  const schedulePaint = useCallback(() => {
    if (frameRef.current !== undefined) cancelAnimationFrame(frameRef.current);
    frameRef.current = requestAnimationFrame(() => { frameRef.current = undefined; paint(); });
  }, [paint]);

  useEffect(() => {
    setReady(false);
    manualViewRef.current = false;
    if (!image) { imageRef.current = null; return; }
    const element = new Image();
    element.onload = () => { imageRef.current = element; setReady(true); };
    element.src = image.objectUrl;
    return () => { element.onload = null; };
  }, [image?.id, image?.objectUrl]);

  useEffect(() => {
    schedulePaint();
    const observer = new ResizeObserver(schedulePaint);
    if (hostRef.current) observer.observe(hostRef.current);
    return () => { observer.disconnect(); if (frameRef.current !== undefined) cancelAnimationFrame(frameRef.current); };
  }, [schedulePaint]);

  const sourcePoint = (event: React.PointerEvent<HTMLCanvasElement>) => {
    const rect = event.currentTarget.getBoundingClientRect();
    const transform = transformRef.current;
    return { x: (event.clientX - rect.left - transform.x) / transform.scale, y: (event.clientY - rect.top - transform.y) / transform.scale };
  };

  const pointerDown = (event: React.PointerEvent<HTMLCanvasElement>) => {
    if (!image) return;
    if (event.button === 1 || (tool === "inspect" && event.shiftKey)) {
      event.currentTarget.setPointerCapture(event.pointerId);
      panRef.current = { clientX: event.clientX, clientY: event.clientY, x: transformRef.current.x, y: transformRef.current.y };
      return;
    }
    const { x, y } = sourcePoint(event);
    if (tool === "roi-include" || tool === "roi-exclude") {
      event.currentTarget.setPointerCapture(event.pointerId);
      roiStartRef.current = { x, y };
      return;
    }
    if (x >= 0 && y >= 0 && x <= image.width && y <= image.height) onCellPointer(x, y);
  };

  const pointerMove = (event: React.PointerEvent<HTMLCanvasElement>) => {
    if (!panRef.current) return;
    manualViewRef.current = true;
    transformRef.current = { ...transformRef.current, x: panRef.current.x + event.clientX - panRef.current.clientX, y: panRef.current.y + event.clientY - panRef.current.clientY };
    schedulePaint();
  };

  const pointerUp = (event: React.PointerEvent<HTMLCanvasElement>) => {
    if (panRef.current) { panRef.current = undefined; return; }
    if (!roiStartRef.current || !image) return;
    const end = sourcePoint(event);
    const start = roiStartRef.current;
    roiStartRef.current = undefined;
    const bounded = { x: Math.max(0, Math.min(image.width, end.x)), y: Math.max(0, Math.min(image.height, end.y)) };
    if (Math.hypot(bounded.x - start.x, bounded.y - start.y) >= 3) onRoi(start, bounded, tool === "roi-include" ? "include" : "exclude");
  };

  const zoomAtCenter = (factor: number) => {
    const host = hostRef.current;
    if (!host || !image) return;
    const rect = host.getBoundingClientRect();
    const old = transformRef.current;
    const fit = fitTransform(rect.width, rect.height, image.width, image.height);
    const scale = Math.max(fit.scale, Math.min(fit.scale * 16, old.scale * factor));
    transformRef.current = { scale, x: rect.width / 2 - (rect.width / 2 - old.x) * scale / old.scale, y: rect.height / 2 - (rect.height / 2 - old.y) * scale / old.scale };
    manualViewRef.current = true;
    schedulePaint();
  };

  const fit = () => { manualViewRef.current = false; schedulePaint(); };

  const wheel = (event: React.WheelEvent<HTMLCanvasElement>) => {
    if (!image) return;
    event.preventDefault();
    const rect = event.currentTarget.getBoundingClientRect();
    const old = transformRef.current;
    const fitted = fitTransform(rect.width, rect.height, image.width, image.height);
    const scale = Math.max(fitted.scale, Math.min(fitted.scale * 16, old.scale * Math.exp(-event.deltaY * 0.0015)));
    const x = event.clientX - rect.left;
    const y = event.clientY - rect.top;
    transformRef.current = { scale, x: x - (x - old.x) * scale / old.scale, y: y - (y - old.y) * scale / old.scale };
    manualViewRef.current = true;
    schedulePaint();
  };

  return (
    <section ref={hostRef} className={`image-stage tool-${tool}`}>
      {image ? (
        <canvas ref={canvasRef} onPointerDown={pointerDown} onPointerMove={pointerMove} onPointerUp={pointerUp} onWheel={wheel} onDoubleClick={fit} aria-label={`${image.fileName} with ${image.cells.length} segmented objects`} />
      ) : (
        <button className="empty-study" onClick={onImport}>
          <span className="empty-icon"><ImagePlus size={22} /></span>
          <strong>Import microscopy images</strong>
          <span>Drop files here or choose images.</span>
          <em>PNG · JPEG · WebP · BMP · TIFF · OME-TIFF</em>
        </button>
      )}
      {image && <div className="stage-zoom" aria-label="Image zoom controls"><button onClick={() => zoomAtCenter(1 / 1.25)} aria-label="Zoom out"><Minus size={14} /></button><button onClick={fit} aria-label="Fit image"><Maximize2 size={13} /></button><button onClick={() => zoomAtCenter(1.25)} aria-label="Zoom in"><Plus size={14} /></button></div>}
    </section>
  );
}
