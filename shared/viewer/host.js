import { createVolumeViewer } from "./volume-viewer.js";

let generation = null;
function send(type, value) {
  const message = { type, generation, ...value };
  const bridge = window.webkit?.messageHandlers?.cellcounterVolume;
  if (bridge) bridge.postMessage(message);
  window.dispatchEvent(new CustomEvent("cellcounter-volume", { detail: message }));
}
const viewer = createVolumeViewer(document.getElementById("viewer"), {
  onCrosshair: (voxel) => send("crosshair", { voxel }),
  onPlanePointer: (event) => send("planePointer", event),
  onStatus: (status) => send("status", status),
});
window.cellcounterVolume = {
  setVolume: (descriptor) => viewer.setVolume(descriptor),
  setCrosshair: (xyz) => viewer.setCrosshair(xyz),
  setGeneration: (value) => { generation = typeof value === "string" || typeof value === "number" ? value : null; },
  dispose: () => viewer.dispose(),
};
window.addEventListener("pagehide", () => viewer.dispose(), { once: true });
send("ready", {});
