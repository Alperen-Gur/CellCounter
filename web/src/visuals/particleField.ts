import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";

export interface ParticleField {
  setShape(value: number, immediate?: boolean): void;
  setMotion(enabled: boolean): void;
  rotate(direction: number): void;
  reset(): void;
  dispose(): void;
}

// An illustration, never derived from a user's specimen or analysis results.
function positions(count: number) {
  const membrane = new Float32Array(count * 3);
  const separated = new Float32Array(count * 3);
  const boundaries = new Float32Array(count * 3);
  const measured = new Float32Array(count * 3);
  const seeds = new Float32Array(count);
  const golden = Math.PI * (3 - Math.sqrt(5));
  const centers = [[-0.7, 0.55], [0.7, 0.42], [0, -0.68]];
  for (let i = 0; i < count; i++) {
    const seed = ((i * 16807 + 113) % 65521) / 65521;
    const y = 1 - 2 * (i + 0.5) / count;
    const radial = Math.sqrt(1 - y * y);
    const angle = i * golden;
    const x = Math.cos(angle) * radial;
    const z = Math.sin(angle) * radial;
    // A stride coprime with the three groups gives every cell an inner structure.
    const inner = i % 7 === 0;
    const shell = inner ? 0.5 + seed * 0.17 : 1.32 + seed * 0.055 + Math.sin(angle * 3) * 0.025;
    membrane.set([x * shell * 1.1, y * shell, z * shell * 0.83], i * 3);
    const center = centers[i % centers.length];
    const local = inner ? 0.21 + seed * 0.07 : 0.54 + seed * 0.035;
    separated.set([center[0] + x * local, center[1] + y * local * 1.1, z * local + (i % 3 - 1) * 0.16], i * 3);
    const radius = inner ? seed * 0.13 : 0.55 + seed * 0.02;
    boundaries.set([center[0] + Math.cos(angle) * radius, center[1] + Math.sin(angle) * radius * 1.1, (seed - 0.5) * 0.065], i * 3);
    // An ordered spatial arrangement, with no invented axis values or measurements.
    const column = i % 13;
    const row = Math.floor(i / 13) % 28;
    const layer = Math.floor(i / (13 * 28));
    measured.set([(column - 6) * 0.29 + (seed - 0.5) * 0.08, (row - 13.5) * 0.065, (layer - count / 728) * 0.045], i * 3);
    seeds[i] = seed;
  }
  return { membrane, separated, boundaries, measured, seeds };
}

const vertexShader = `
  attribute vec3 separated;
  attribute vec3 boundaries;
  attribute vec3 measured;
  attribute float seed;
  uniform float uTime;
  uniform float uMorph;
  uniform float uPixelRatio;
  uniform float uCompact;
  varying float vLight;
  varying float vSeed;

  // Analytic curl of a smooth trigonometric vector potential; deliberately subtle.
  vec3 flow(vec3 p, float t) {
    return vec3(
      -sin(p.x-t)*sin(p.y)-cos(p.z+t)*cos(p.x),
      -sin(p.y+t)*sin(p.z-t)-cos(p.x-t)*cos(p.y),
      -sin(p.z+t)*sin(p.x)-cos(p.y+t)*cos(p.z-t)
    );
  }
  void main() {
    float a = smoothstep(0.0, 1.0, clamp(uMorph, 0.0, 1.0));
    float b = smoothstep(0.0, 1.0, clamp(uMorph-1.0, 0.0, 1.0));
    float c = smoothstep(0.0, 1.0, clamp(uMorph-2.0, 0.0, 1.0));
    vec3 p = mix(mix(mix(position, separated, a), boundaries, b), measured, c);
    p *= mix(1.0, 0.63, uCompact);
    float transition = sin(fract(uMorph) * 3.14159265);
    p += flow(p * 1.5 + seed, uTime * 0.14) * (0.028 + transition * 0.12);
    vec4 view = modelViewMatrix * vec4(p, 1.0);
    float depth = clamp(4.5 / -view.z, 0.55, 1.8);
    gl_PointSize = clamp((2.1 + seed * 2.1) * depth * uPixelRatio, 1.0, 8.0);
    gl_Position = projectionMatrix * view;
    // Position in screen space so rotating a form never swings it across the copy.
    vec2 anchor = mix(mix(mix(vec2(0.38, -0.04), vec2(-0.38, -0.04), a), vec2(0.38, -0.04), b), vec2(0.0, -0.73), c);
    anchor = mix(anchor, vec2(0.0, mix(-0.4, -0.62, c)), uCompact);
    gl_Position.xy += anchor * gl_Position.w;
    vLight = clamp(depth * 0.82, 0.35, 1.0) * mix(1.0, 0.55, c);
    vSeed = seed;
  }
`;
const fragmentShader = `
  varying float vLight;
  varying float vSeed;
  void main() {
    float d = length(gl_PointCoord - 0.5) * 2.0;
    if (d > 1.0) discard;
    float core = exp(-d*d*11.0);
    float halo = exp(-d*d*4.0) * 0.32;
    vec3 color = mix(vec3(0.17, 0.26, 0.38), vec3(0.36, 0.48, 0.63), vSeed);
    if (vSeed > 0.92) color = vec3(0.36, 0.37, 0.51);
    gl_FragColor = vec4(color, min((core + halo) * vLight * 1.2, 1.0));
  }
`;

export function createParticleField(host: HTMLElement, onFailure: () => void): ParticleField {
  const count = matchMedia("(max-width: 640px)").matches ? 2800 : 6200;
  const ratio = Math.min(window.devicePixelRatio || 1, 1.5);
  const renderer = new THREE.WebGLRenderer({ antialias: false, alpha: true, powerPreference: "low-power" });
  renderer.setPixelRatio(ratio);
  renderer.setClearColor(0xf5f7fa, 0);
  renderer.domElement.setAttribute("aria-hidden", "true");
  host.appendChild(renderer.domElement);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(42, 1, 0.1, 30);
  camera.position.set(0, 0.12, 5.7);
  const controls = new OrbitControls(camera, renderer.domElement);
  controls.enablePan = false;
  controls.enableZoom = false;
  controls.enableDamping = false;
  controls.autoRotateSpeed = 0.18;
  controls.minPolarAngle = 0.25;
  controls.maxPolarAngle = Math.PI - 0.25;
  // Allow vertical page scrolling on touch; rotate with mouse or the visible buttons.
  renderer.domElement.style.touchAction = "pan-y";
  const data = positions(count);
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.BufferAttribute(data.membrane, 3));
  geometry.setAttribute("separated", new THREE.BufferAttribute(data.separated, 3));
  geometry.setAttribute("boundaries", new THREE.BufferAttribute(data.boundaries, 3));
  geometry.setAttribute("measured", new THREE.BufferAttribute(data.measured, 3));
  geometry.setAttribute("seed", new THREE.BufferAttribute(data.seeds, 1));
  const material = new THREE.ShaderMaterial({
    vertexShader, fragmentShader,
    uniforms: { uTime: { value: 0 }, uMorph: { value: 0 }, uPixelRatio: { value: ratio }, uCompact: { value: 0 } },
    transparent: true, depthWrite: false, blending: THREE.NormalBlending,
  });
  const points = new THREE.Points(geometry, material);
  points.frustumCulled = false;
  scene.add(points);
  let target = 0;
  let motion = false;
  let visible = true;
  let disposed = false;
  let frame = 0;
  let previous = 0;
  const render = () => { if (!disposed && visible && !document.hidden) renderer.render(scene, camera); };
  const tick = (now: number) => {
    frame = 0;
    if (disposed || !visible || document.hidden || !motion) return;
    const dt = previous ? Math.min((now - previous) / 1000, 0.05) : 0;
    previous = now;
    material.uniforms.uTime.value += dt;
    material.uniforms.uMorph.value += (target - material.uniforms.uMorph.value) * (1 - Math.exp(-dt * 6));
    controls.autoRotate = true;
    controls.update(dt);
    render();
    frame = requestAnimationFrame(tick);
  };
  const sync = () => {
    if (frame) cancelAnimationFrame(frame);
    frame = 0;
    previous = 0;
    controls.autoRotate = motion && visible && !document.hidden;
    if (controls.autoRotate) frame = requestAnimationFrame(tick);
    else render();
  };
  const resize = () => {
    const width = Math.max(host.clientWidth, 1);
    const height = Math.max(host.clientHeight, 1);
    camera.aspect = width / height;
    // Keep the illustration comfortably inside portrait frames.
    camera.fov = width < 700 ? 52 : 42;
    material.uniforms.uCompact.value = width < 700 ? 1 : 0;
    camera.updateProjectionMatrix();
    const boundedRatio = Math.min(ratio, Math.sqrt(3_000_000 / (width * height)));
    renderer.setPixelRatio(boundedRatio);
    material.uniforms.uPixelRatio.value = boundedRatio;
    renderer.setSize(width, height, false);
    render();
  };
  const observer = new ResizeObserver(resize);
  observer.observe(host);
  const intersection = new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; sync(); });
  intersection.observe(host);
  const lost = (event: Event) => { event.preventDefault(); motion = false; sync(); onFailure(); };
  renderer.domElement.addEventListener("webglcontextlost", lost);
  const onControlChange = () => { if (!motion) render(); };
  controls.addEventListener("change", onControlChange);
  document.addEventListener("visibilitychange", sync);
  resize();
  return {
    setShape(value, immediate = false) {
      target = Math.max(0, Math.min(3, value));
      if (!motion || immediate) material.uniforms.uMorph.value = target;
      render();
    },
    setMotion(value) { motion = value; sync(); },
    rotate(direction) { controls.rotateLeft(direction * 0.22); controls.update(); render(); },
    reset() { camera.position.set(0, 0.12, 5.7); controls.target.set(0, 0, 0); controls.update(); render(); },
    dispose() {
      disposed = true;
      if (frame) cancelAnimationFrame(frame);
      document.removeEventListener("visibilitychange", sync);
      renderer.domElement.removeEventListener("webglcontextlost", lost);
      observer.disconnect(); intersection.disconnect(); controls.removeEventListener("change", onControlChange); controls.dispose();
      geometry.dispose(); material.dispose(); renderer.dispose();
      renderer.domElement.remove();
    },
  };
}
