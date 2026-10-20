import { useEffect, useRef, useState } from "react";
import { createVolumeViewer, type VolumeViewer } from "../../../../shared/viewer/volume-viewer.js";
import type { Vec3, VolumeDisplay, VolumePlane } from "../../../../shared/workbench/volumeProtocol";
import "../../../../shared/viewer/volume-viewer.css";

export default function VolumeRenderer({ descriptor, crosshair, onCrosshair, onPlanePick }: {
  descriptor?: VolumeDisplay; crosshair: Vec3; onCrosshair: (value: Vec3) => void;
  onPlanePick: (plane: VolumePlane, value: Vec3) => void;
}) {
  const container = useRef<HTMLDivElement>(null);
  const viewer = useRef<VolumeViewer | undefined>(undefined);
  const handlers = useRef({ onCrosshair, onPlanePick });
  handlers.current = { onCrosshair, onPlanePick };
  const [error, setError] = useState("");
  useEffect(() => {
    if (!container.current) return;
    const instance = createVolumeViewer(container.current, {
      onCrosshair: (value) => handlers.current.onCrosshair(value),
      onPlanePointer: (event) => handlers.current.onPlanePick(event.plane, event.voxel),
    });
    viewer.current = instance;
    return () => { instance.dispose(); viewer.current = undefined; };
  }, []);
  useEffect(() => {
    if (!descriptor) { setError(""); return; }
    try { viewer.current?.setVolume(descriptor); setError(""); }
    catch (cause) { setError(String(cause)); }
  }, [descriptor]);
  useEffect(() => { if (descriptor) viewer.current?.setCrosshair(crosshair); }, [crosshair, descriptor]);
  return <>{error ? <p role="alert" className="workbench-error">{error}</p> : null}
    {!descriptor ? <p role="status">Loading the selected volume display…</p> : null}
    <div ref={container} hidden={!descriptor || !!error} />
  </>;
}
