import {
  clamp, decodeVolume, displayToOriginal, originalToDisplay,
  planePoint, PLANE_AXES, rotationMatrix, voxelIndex,
} from "./math.js";

const VERTEX = `#version 300 es
precision highp float;
void main() {
  vec2 p = gl_VertexID == 0 ? vec2(-1., -1.) : (gl_VertexID == 1 ? vec2(3., -1.) : vec2(-1., 3.));
  gl_Position = vec4(p, 0., 1.);
}`;
const FRAGMENT = `#version 300 es
precision highp float;
precision highp int;
precision highp sampler3D;
precision highp usampler3D;
uniform sampler3D uVolume;
uniform usampler3D uLabels;
uniform vec2 uResolution;
uniform vec3 uHalfExtent;
uniform vec3 uDimensions;
uniform vec3 uCrosshair;
uniform mat3 uRotation;
uniform float uZoom;
uniform float uOpacity;
uniform vec2 uWindow;
uniform bool uShowLabels;
uniform bool uComposite;
out vec4 color;
vec3 labelColor(uint label) {
  uint h = label * 1664525u + 1013904223u;
  return .3 + .7 * vec3(float(h & 255u), float((h >> 8u) & 255u), float((h >> 16u) & 255u)) / 255.;
}
void main() {
  vec2 screen = gl_FragCoord.xy / uResolution * 2. - 1.;
  screen.x *= uResolution.x / uResolution.y;
  vec3 origin = uRotation * vec3(screen * .7 / uZoom, 2.);
  vec3 direction = normalize(uRotation * vec3(0., 0., -1.));
  vec3 reciprocal = 1. / (direction + vec3(1e-8));
  vec3 first = (-uHalfExtent - origin) * reciprocal;
  vec3 last = (uHalfExtent - origin) * reciprocal;
  vec3 nearFace = min(first, last), farFace = max(first, last);
  float enter = max(max(nearFace.x, nearFace.y), nearFace.z);
  float leave = min(min(farFace.x, farFace.y), farFace.z);
  vec3 background = vec3(.055, .067, .085);
  if (enter >= leave || leave < 0.) { color = vec4(background, 1.); return; }
  float stepLength = (leave - max(enter, 0.)) / 256.;
  float distanceAlong = max(enter, 0.) + stepLength * .5;
  vec4 accumulated = vec4(0.);
  for (int i = 0; i < 256; i++) {
    if (distanceAlong > leave || accumulated.a > .985) break;
    vec3 world = origin + direction * distanceAlong;
    vec3 tex = world / (uHalfExtent * 2.) + .5;
    tex.y = 1. - tex.y;
    vec4 source = texture(uVolume, tex);
    // Composite alpha is acquired support, independent of display brightness.
    // Never fill an unsupported voxel with a label or crosshair contribution.
    if (uComposite && source.a <= 0.) {
      distanceAlong += stepLength;
      continue;
    }
    float value = clamp((source.r - uWindow.x) / max(uWindow.y - uWindow.x, 1. / 255.), 0., 1.);
    vec3 sampleColor = uComposite ? source.rgb : vec3(value);
    float density = uComposite ? max(max(source.r, source.g), source.b) * source.a : value;
    if (uShowLabels) {
      uint label = texture(uLabels, tex).r;
      if (label > 0u) {
        sampleColor = mix(sampleColor, labelColor(label), .65);
        density = max(density, .4);
      }
    }
    // A small selected-voxel marker links the raymarch to orthogonal views.
    if (length((tex - uCrosshair) * uDimensions) < 1.2) {
      sampleColor = vec3(1., .74, .20);
      density = max(density, .8);
    }
    float alpha = 1. - exp(-density * uOpacity * stepLength * 12.);
    accumulated.rgb += (1. - accumulated.a) * alpha * sampleColor;
    accumulated.a += (1. - accumulated.a) * alpha;
    distanceAlong += stepLength;
  }
  color = vec4(accumulated.rgb + (1. - accumulated.a) * background, 1.);
}`;

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}
function labelColor(label) {
  const hash = (Math.imul(label, 1664525) + 1013904223) >>> 0;
  return [hash & 255, (hash >>> 8) & 255, (hash >>> 16) & 255].map((value) => 76.5 + .7 * value);
}
function format(value) {
  return Number(value.toPrecision(5)).toLocaleString(undefined, { maximumFractionDigits: 5 });
}

/** GPU display and linked sampled planes; callbacks never mutate scientific data. */
export function createVolumeViewer(container, callbacks = {}) {
  if (!(container instanceof HTMLElement)) throw new Error("A viewer container element is required.");
  const host = element("section", "cc-volume-viewer");
  host.setAttribute("aria-label", "Volume and orthogonal views");
  const status = element("p", "cc-volume-status", "Load a volume to inspect it.");
  status.setAttribute("role", "status");
  const grid = element("div", "cc-volume-grid");
  const volumePane = element("section", "cc-volume-pane cc-volume-3d");
  const volumeHeading = element("h3", "", "3D volume");
  const canvas = element("canvas", "cc-volume-gpu");
  canvas.tabIndex = 0;
  canvas.setAttribute("role", "img");
  canvas.setAttribute("aria-label", "Volume rendering. Drag to rotate, arrow keys to rotate, plus and minus to zoom, Home to reset.");
  const gpuStage = element("div", "cc-volume-stage cc-volume-gpu-stage");
  const fallback = element("p", "cc-volume-fallback");
  fallback.hidden = true;
  gpuStage.append(canvas, fallback);
  volumePane.append(volumeHeading, gpuStage,
    element("p", "cc-volume-help", "Drag to rotate. Arrow keys rotate; + and − zoom; Home resets."));
  grid.append(volumePane);
  const controls = element("div", "cc-volume-controls");
  const controlsHeading = element("h3", "", "Display controls");
  const coordinates = element("output", "cc-volume-coordinates", "X — · Y — · Z —");
  coordinates.setAttribute("aria-label", "Crosshair source voxel indices");
  const disclaimer = element("p", "cc-volume-help",
    "These views are display previews. Measurements and corrections use the original volume.");
  host.append(status, grid, controlsHeading, controls, coordinates, disclaimer);
  container.append(host);

  let disposed = false, volume = null, crosshair = [0, 0, 0], volumeGeneration = 0;
  let yaw = -.5, pitch = .35, zoom = 1, opacity = 1, low = 0, high = 255, showLabels = true;
  let frame = 0, gl = null, program = null, texture = null, labelTexture = null, vertexArray = null;
  let uniforms = {}, lost = false, glMessage = "";
  const removers = [];
  const on = (node, event, handler, options) => {
    node.addEventListener(event, handler, options);
    removers.push(() => node.removeEventListener(event, handler, options));
  };
  const emit = (name, value) => {
    if (!disposed && typeof callbacks[name] === "function") callbacks[name](value);
  };

  function slider(text, min, max, step, value, change) {
    const label = element("label", "cc-volume-control");
    const title = element("span", "", text);
    const output = element("output", "", String(value));
    const input = element("input");
    input.type = "range"; input.min = String(min); input.max = String(max);
    input.step = String(step); input.value = String(value);
    input.setAttribute("aria-label", text);
    label.append(title, input, output); controls.append(label);
    on(input, "input", () => { change(Number(input.value)); updateControls(); schedule(); });
    return { label, input, output };
  }
  const lowControl = slider("Window low", 0, 254, 1, low, (value) => { low = Math.min(value, high - 1); });
  const highControl = slider("Window high", 1, 255, 1, high, (value) => { high = Math.max(value, low + 1); });
  const opacityControl = slider("Volume opacity", .05, 3, .05, opacity, (value) => { opacity = value; });
  const zoomControl = slider("Zoom", .5, 3, .05, zoom, (value) => { zoom = value; });
  const yawControl = slider("Rotation", -180, 180, 1, yaw * 180 / Math.PI, (value) => { yaw = value * Math.PI / 180; });
  const pitchControl = slider("Tilt", -85, 85, 1, pitch * 180 / Math.PI, (value) => { pitch = value * Math.PI / 180; });
  const labelsControl = element("label", "cc-volume-labels");
  const labelsInput = element("input"); labelsInput.type = "checkbox"; labelsInput.checked = true;
  const labelsText = document.createTextNode("Show saved labels");
  labelsControl.append(labelsInput, labelsText); controls.append(labelsControl);
  on(labelsInput, "change", () => { showLabels = labelsInput.checked; schedule(); });
  const reset = element("button", "cc-volume-reset", "Reset view"); reset.type = "button";
  controls.append(reset);
  on(reset, "click", () => { resetView(); });

  const panes = {};
  for (const [plane, axes] of Object.entries(PLANE_AXES)) {
    const pane = element("section", "cc-volume-pane");
    const heading = element("h3", "", `${plane.toUpperCase()} plane`);
    const stage = element("div", "cc-volume-stage cc-volume-slice-stage");
    const surface = element("div", "cc-volume-slice-surface");
    const sliceCanvas = element("canvas", "cc-volume-slice");
    sliceCanvas.tabIndex = 0;
    sliceCanvas.setAttribute("role", "img");
    sliceCanvas.setAttribute("aria-label", `${plane.toUpperCase()} sampled slice. Click to position the crosshair. Arrow keys move within this plane; Page Up and Page Down change its slice.`);
    const verticalLine = element("div", "cc-volume-crosshair cc-volume-crosshair-v");
    const horizontalLine = element("div", "cc-volume-crosshair cc-volume-crosshair-h");
    surface.append(sliceCanvas, verticalLine, horizontalLine); stage.append(surface);
    const sliceLabel = element("label", "cc-volume-slice-control");
    const sliceTitle = element("span", "", `${"XYZ"[axes.normal]} slice`);
    const sliceRange = element("input"); sliceRange.type = "range";
    sliceRange.min = "0"; sliceRange.max = "0"; sliceRange.step = "1"; sliceRange.value = "0";
    sliceRange.setAttribute("aria-label", `${plane.toUpperCase()} slice along ${"XYZ"[axes.normal]}`);
    const sliceOutput = element("output", "", "—");
    sliceLabel.append(sliceTitle, sliceRange, sliceOutput);
    pane.append(heading, stage, sliceLabel); grid.append(pane);
    panes[plane] = { ...axes, pane, stage, surface, canvas: sliceCanvas, context: sliceCanvas.getContext("2d"),
      verticalLine, horizontalLine, sliceRange, sliceOutput };
    on(sliceRange, "input", () => {
      if (!volume) return;
      const position = [...crosshair]; position[axes.normal] = Number(sliceRange.value);
      moveCrosshair(position, true);
    });
    on(sliceCanvas, "click", (event) => {
      if (!volume) return;
      const rect = sliceCanvas.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      const point = planePoint(volume, plane,
        (event.clientX - rect.left) / rect.width * volume.dimensions[axes.horizontal] - .5,
        (event.clientY - rect.top) / rect.height * volume.dimensions[axes.vertical] - .5, crosshair);
      emit("onPlanePointer", { plane, ...point, role: "click", sampled: true, editable: false });
      moveCrosshair(point.voxel, true);
    });
    on(sliceCanvas, "keydown", (event) => {
      if (!volume) return;
      const position = [...crosshair], stride = event.shiftKey ? 10 : 1;
      const changes = { ArrowLeft: [axes.horizontal, -stride], ArrowRight: [axes.horizontal, stride],
        ArrowUp: [axes.vertical, -stride], ArrowDown: [axes.vertical, stride],
        PageUp: [axes.normal, -stride], PageDown: [axes.normal, stride] };
      const change = changes[event.key];
      if (!change) return;
      event.preventDefault(); position[change[0]] += change[1]; moveCrosshair(position, true);
    });
  }

  function updateControls() {
    for (const [control, value, shown] of [
      [lowControl, low, volume ? format(volume.displayRange[0] + low / 255 * (volume.displayRange[1] - volume.displayRange[0])) : "—"],
      [highControl, high, volume ? format(volume.displayRange[0] + high / 255 * (volume.displayRange[1] - volume.displayRange[0])) : "—"],
      [opacityControl, opacity, `${opacity.toFixed(2)}×`], [zoomControl, zoom, `${zoom.toFixed(2)}×`],
      [yawControl, yaw * 180 / Math.PI, `${Math.round(yaw * 180 / Math.PI)}°`],
      [pitchControl, pitch * 180 / Math.PI, `${Math.round(pitch * 180 / Math.PI)}°`],
    ]) {
      control.input.value = String(value); control.output.textContent = shown;
      control.input.setAttribute("aria-valuetext", shown); control.input.disabled = !volume;
    }
    // Composite channels were already windowed by the shared operation. A
    // second grayscale window would obscure the recorded channel settings.
    lowControl.label.hidden = !!volume?.composite;
    highControl.label.hidden = !!volume?.composite;
    if (volume?.composite) {
      lowControl.input.disabled = true;
      highControl.input.disabled = true;
    }
    labelsInput.disabled = !volume?.labels;
    labelsInput.checked = showLabels;
    labelsText.textContent = volume?.composite
      ? (volume.labelChannel != null
        ? `${volume.labels ? "Show saved labels" : "No saved labels"} · channel ${volume.labelChannel}`
        : "Saved labels not included")
      : "Show saved labels";
    reset.disabled = !volume;
  }
  function resetView() {
    yaw = -.5; pitch = .35; zoom = 1; opacity = 1; low = 0; high = 255;
    updateControls(); schedule();
  }
  function announce(mode, message) {
    status.textContent = message;
    emit("onStatus", { mode, message, ...(volume ? { dimensions: [...volume.dimensions], calibrated: volume.calibrated } : {}) });
  }
  function showStatus() {
    if (!volume) { announce("empty", "Load a volume to inspect it."); return; }
    const dimensions = volume.dimensions.join(" × ");
    const same = volume.dimensions.every((size, axis) => size === volume.originalDimensions[axis]);
    const sampling = same ? `${dimensions} voxels` : `${dimensions} display voxels from ${volume.originalDimensions.join(" × ")}`;
    const spacing = volume.calibrated ? "Physical aspect ratio preserved." : "Spacing unavailable; aspect ratio is shown in voxels.";
    const mode = gl && program && texture && !lost ? "gpu" : "slices";
    fallback.hidden = mode === "gpu"; canvas.hidden = mode !== "gpu";
    fallback.textContent = `${glMessage || "WebGL 2 is unavailable."} Orthogonal slices remain available.`;
    const channels = volume.composite && Array.isArray(volume.channels)
      ? volume.channels.filter((item) => item.enabled && item.opacity > 0).length : 0;
    volumeHeading.textContent = volume.composite ? "3D channel composite" : "3D volume";
    disclaimer.textContent = volume.composite
      ? "Channel colors and contrast use the rendered volume settings. Transparent samples are outside acquired support. Measurements and corrections use the original volume."
      : "These views are display previews. Measurements and corrections use the original volume.";
    announce(mode, `${mode === "gpu" ? "GPU volume" : "Slice view"}${volume.composite ? ` · ${channels} visible channels` : ""} · ${sampling}. ${spacing}${mode === "slices" ? ` ${glMessage}` : ""}`);
  }
  function destroyGPU() {
    if (gl && !lost) {
      if (texture) gl.deleteTexture(texture);
      if (labelTexture) gl.deleteTexture(labelTexture);
      if (program) gl.deleteProgram(program);
      if (vertexArray) gl.deleteVertexArray(vertexArray);
    }
    texture = null; labelTexture = null; program = null; vertexArray = null; uniforms = {};
  }
  function shader(kind, source) {
    const handle = gl.createShader(kind);
    if (!handle) throw new Error("GPU shader allocation failed.");
    gl.shaderSource(handle, source); gl.compileShader(handle);
    if (!gl.getShaderParameter(handle, gl.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(handle); gl.deleteShader(handle);
      throw new Error(`Volume shader compilation failed: ${String(log).slice(0, 300)}`);
    }
    return handle;
  }
  function initializeGPU() {
    try {
      gl = canvas.getContext("webgl2", { alpha: false, antialias: false, depth: false,
        stencil: false, preserveDrawingBuffer: false, powerPreference: "high-performance" });
      if (!gl) throw new Error("WebGL 2 is unavailable.");
      if (gl.getParameter(gl.MAX_3D_TEXTURE_SIZE) < 128) throw new Error("The GPU cannot allocate a 128³ volume.");
      const vertex = shader(gl.VERTEX_SHADER, VERTEX);
      let fragment;
      try { fragment = shader(gl.FRAGMENT_SHADER, FRAGMENT); } catch (error) { gl.deleteShader(vertex); throw error; }
      program = gl.createProgram();
      if (!program) { gl.deleteShader(vertex); gl.deleteShader(fragment); throw new Error("GPU program allocation failed."); }
      gl.attachShader(program, vertex); gl.attachShader(program, fragment); gl.linkProgram(program);
      gl.deleteShader(vertex); gl.deleteShader(fragment);
      if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error("The GPU could not link the volume renderer.");
      vertexArray = gl.createVertexArray();
      for (const name of ["uVolume", "uLabels", "uResolution", "uHalfExtent", "uDimensions", "uCrosshair",
        "uRotation", "uZoom", "uOpacity", "uWindow", "uShowLabels", "uComposite"]) uniforms[name] = gl.getUniformLocation(program, name);
      gl.disable(gl.DEPTH_TEST); gl.disable(gl.BLEND);
      glMessage = "";
      if (volume) upload();
    } catch (error) {
      glMessage = error instanceof Error ? error.message : "The GPU renderer could not start.";
      destroyGPU();
    }
  }
  function allocateTexture(unit, format, sourceFormat, type, data, dimensions, filter) {
    const handle = gl.createTexture();
    if (!handle) throw new Error("GPU texture allocation failed.");
    gl.activeTexture(gl.TEXTURE0 + unit); gl.bindTexture(gl.TEXTURE_3D, handle);
    gl.texParameteri(gl.TEXTURE_3D, gl.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_3D, gl.TEXTURE_MAG_FILTER, filter);
    for (const axis of [gl.TEXTURE_WRAP_S, gl.TEXTURE_WRAP_T, gl.TEXTURE_WRAP_R])
      gl.texParameteri(gl.TEXTURE_3D, axis, gl.CLAMP_TO_EDGE);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texImage3D(gl.TEXTURE_3D, 0, format, ...dimensions, 0, sourceFormat, type, data);
    if (gl.getError() !== gl.NO_ERROR) { gl.deleteTexture(handle); throw new Error("GPU volume allocation failed."); }
    return handle;
  }
  function upload() {
    if (!gl || !program || lost || !volume) return;
    if (texture) gl.deleteTexture(texture);
    if (labelTexture) gl.deleteTexture(labelTexture);
    texture = null; labelTexture = null;
    try {
      // Nearest sampling preserves exact support holes in a composite. Its
      // RGBA grid already comes from the runtime's source-center sampling.
      texture = allocateTexture(0, volume.composite ? gl.RGBA8 : gl.R8,
        volume.composite ? gl.RGBA : gl.RED, gl.UNSIGNED_BYTE, volume.data, volume.dimensions,
        volume.composite ? gl.NEAREST : gl.LINEAR);
      labelTexture = allocateTexture(1, gl.R32UI, gl.RED_INTEGER, gl.UNSIGNED_INT,
        volume.labels ?? new Uint32Array(1), volume.labels ? volume.dimensions : [1, 1, 1], gl.NEAREST);
    } catch (error) {
      glMessage = error instanceof Error ? error.message : "GPU volume allocation failed.";
      destroyGPU();
    }
  }
  function renderGPU() {
    if (!volume || !gl || !program || !texture || lost || canvas.hidden) return;
    const rect = gpuStage.getBoundingClientRect();
    if (!rect.width || !rect.height) return;
    // Cap display resolution independently from the bounded volume allocation.
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    const width = Math.max(1, Math.min(1280, Math.round(rect.width * ratio)));
    const height = Math.max(1, Math.min(960, Math.round(rect.height * ratio)));
    if (canvas.width !== width || canvas.height !== height) { canvas.width = width; canvas.height = height; }
    gl.viewport(0, 0, width, height); gl.useProgram(program); gl.bindVertexArray(vertexArray);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_3D, texture);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_3D, labelTexture);
    gl.uniform1i(uniforms.uVolume, 0); gl.uniform1i(uniforms.uLabels, 1);
    gl.uniform2f(uniforms.uResolution, width, height);
    gl.uniform3fv(uniforms.uHalfExtent, volume.halfExtent);
    gl.uniform3fv(uniforms.uDimensions, volume.dimensions);
    const display = originalToDisplay(volume, crosshair);
    gl.uniform3fv(uniforms.uCrosshair, display.map((value, axis) => (value + .5) / volume.dimensions[axis]));
    gl.uniformMatrix3fv(uniforms.uRotation, false, rotationMatrix(yaw, pitch));
    gl.uniform1f(uniforms.uZoom, zoom); gl.uniform1f(uniforms.uOpacity, opacity);
    gl.uniform2f(uniforms.uWindow, low / 255, high / 255);
    gl.uniform1i(uniforms.uShowLabels, showLabels && !!volume.labels ? 1 : 0);
    gl.uniform1i(uniforms.uComposite, volume.composite ? 1 : 0);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
  function renderSlice(pane) {
    if (!volume || !pane.context) return;
    const dimensions = volume.dimensions, width = dimensions[pane.horizontal], height = dimensions[pane.vertical];
    const selected = originalToDisplay(volume, crosshair), slice = Math.round(selected[pane.normal]);
    const cacheKey = `${volumeGeneration}:${slice}:${low}:${high}:${showLabels}`;
    if (pane.cacheKey !== cacheKey) {
      pane.canvas.width = width; pane.canvas.height = height;
      const pixels = pane.context.createImageData(width, height);
      const position = [0, 0, 0]; position[pane.normal] = slice;
      for (let y = 0; y < height; y++) {
        position[pane.vertical] = y;
        for (let x = 0; x < width; x++) {
          position[pane.horizontal] = x;
          const index = voxelIndex(dimensions, ...position), destination = (y * width + x) * 4;
          const alpha = volume.composite ? volume.data[index * 4 + 3] : 255;
          const gray = volume.composite ? 0 : clamp((volume.data[index] - low) / Math.max(1, high - low), 0, 1) * 255;
          const base = volume.composite
            ? [volume.data[index * 4], volume.data[index * 4 + 1], volume.data[index * 4 + 2]] : [gray, gray, gray];
          const label = alpha > 0 && showLabels && volume.labels ? volume.labels[index] : 0;
          const rgb = label ? labelColor(label).map((value, component) => .55 * base[component] + .45 * value) : base;
          pixels.data[destination] = rgb[0]; pixels.data[destination + 1] = rgb[1];
          pixels.data[destination + 2] = rgb[2]; pixels.data[destination + 3] = alpha;
        }
      }
      pane.context.putImageData(pixels, 0, 0); pane.cacheKey = cacheKey;
    }
    const aspect = volume.extent[pane.horizontal] / volume.extent[pane.vertical];
    const rect = pane.stage.getBoundingClientRect();
    const displayWidth = Math.max(1, Math.min(rect.width, rect.height * aspect));
    const displayHeight = displayWidth / aspect;
    pane.surface.style.width = `${displayWidth}px`; pane.surface.style.height = `${displayHeight}px`;
    pane.verticalLine.style.left = `${(selected[pane.horizontal] + .5) / width * 100}%`;
    pane.horizontalLine.style.top = `${(selected[pane.vertical] + .5) / height * 100}%`;
    pane.sliceRange.max = String(volume.originalDimensions[pane.normal] - 1);
    pane.sliceRange.value = String(Math.round(crosshair[pane.normal]));
    const shown = displayToOriginal(volume, selected.map((value, axis) => axis === pane.normal ? slice : value))[pane.normal];
    pane.sliceOutput.textContent = `${format(crosshair[pane.normal])}${Math.abs(shown - crosshair[pane.normal]) > .001 ? ` · displayed ≈ ${format(shown)}` : ""}`;
    pane.sliceRange.setAttribute("aria-valuetext", pane.sliceOutput.textContent);
    pane.sliceRange.disabled = volume.originalDimensions[pane.normal] <= 1;
  }
  function render() {
    frame = 0;
    if (disposed || !volume) return;
    renderGPU();
    for (const pane of Object.values(panes)) renderSlice(pane);
    coordinates.textContent = crosshair.map((value, axis) => `${"XYZ"[axis]} ${format(value)}`).join(" · ") + " (source voxel indices)";
  }
  function schedule() {
    if (!disposed && !frame) frame = requestAnimationFrame(render);
  }
  function moveCrosshair(xyz, notify) {
    if (!volume || !Array.isArray(xyz) || xyz.length !== 3 || !xyz.every(Number.isFinite)) return;
    crosshair = xyz.map((value, axis) => clamp(value, 0, volume.originalDimensions[axis] - 1));
    if (notify) emit("onCrosshair", [...crosshair]);
    schedule();
  }
  function adjustRotation(dx, dy) {
    yaw = ((yaw + dx + Math.PI) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI) - Math.PI;
    pitch = clamp(pitch + dy, -85 * Math.PI / 180, 85 * Math.PI / 180);
    updateControls(); schedule();
  }
  let drag = null;
  on(canvas, "pointerdown", (event) => {
    if (!volume || event.button !== 0) return;
    canvas.focus({ preventScroll: true }); canvas.setPointerCapture(event.pointerId);
    drag = { id: event.pointerId, x: event.clientX, y: event.clientY };
  });
  on(canvas, "pointermove", (event) => {
    if (!drag || event.pointerId !== drag.id) return;
    adjustRotation((event.clientX - drag.x) * .008, (event.clientY - drag.y) * .008);
    drag.x = event.clientX; drag.y = event.clientY;
  });
  const endDrag = (event) => {
    if (drag?.id !== event.pointerId) return;
    if (canvas.hasPointerCapture(event.pointerId)) canvas.releasePointerCapture(event.pointerId);
    drag = null;
  };
  on(canvas, "pointerup", endDrag); on(canvas, "pointercancel", endDrag);
  on(canvas, "wheel", (event) => {
    if (!volume || document.activeElement !== canvas) return;
    event.preventDefault(); zoom = clamp(zoom * Math.exp(-event.deltaY * .001), .5, 3);
    updateControls(); schedule();
  }, { passive: false });
  on(canvas, "keydown", (event) => {
    if (!volume) return;
    const moves = { ArrowLeft: [-.1, 0], ArrowRight: [.1, 0], ArrowUp: [0, -.1], ArrowDown: [0, .1] };
    if (moves[event.key]) { event.preventDefault(); adjustRotation(...moves[event.key]); }
    else if (["+", "=", "-", "_"].includes(event.key)) {
      event.preventDefault(); zoom = clamp(zoom + (["+", "="].includes(event.key) ? .1 : -.1), .5, 3);
      updateControls(); schedule();
    } else if (event.key === "Home") { event.preventDefault(); resetView(); }
  });
  on(canvas, "webglcontextlost", (event) => {
    event.preventDefault(); lost = true; glMessage = "The GPU context was lost.";
    texture = null; labelTexture = null; program = null; vertexArray = null;
    showStatus(); schedule();
  });
  on(canvas, "webglcontextrestored", () => {
    lost = false; initializeGPU(); showStatus(); schedule();
  });
  const observer = typeof ResizeObserver !== "undefined" ? new ResizeObserver(schedule) : null;
  observer?.observe(host);
  on(window, "resize", schedule);
  initializeGPU(); updateControls(); showStatus();

  return {
    setVolume(descriptor) {
      if (disposed) return;
      try {
        const next = decodeVolume(descriptor);
        const preserve = volume && volume.imageId === next.imageId &&
          volume.originalDimensions.every((size, axis) => size === next.originalDimensions[axis]);
        volume = next;
        volumeGeneration++;
        if (!preserve) crosshair = next.originalDimensions.map((size) => (size - 1) / 2);
        low = 0; high = 255;
        if (!program && !lost) initializeGPU(); else upload();
        updateControls(); showStatus(); schedule();
      } catch (error) {
        // Do not leave a prior volume visible under the new image's identity.
        volume = null; destroyGPU();
        canvas.hidden = true; fallback.hidden = false;
        fallback.textContent = "This volume could not be displayed.";
        for (const pane of Object.values(panes)) {
          pane.context?.clearRect(0, 0, pane.canvas.width, pane.canvas.height);
          pane.sliceRange.disabled = true;
        }
        updateControls();
        announce("error", error instanceof Error ? error.message : "This volume could not be displayed.");
        throw error;
      }
    },
    setCrosshair(xyz) { if (!disposed) moveCrosshair(xyz, false); },
    dispose() {
      if (disposed) return;
      disposed = true;
      if (frame) cancelAnimationFrame(frame);
      observer?.disconnect();
      for (const remove of removers) remove();
      destroyGPU(); gl = null; volume = null; host.remove();
    },
  };
}
