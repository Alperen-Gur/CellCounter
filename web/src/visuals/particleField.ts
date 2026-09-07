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
  const division = new Float32Array(count * 3);
  const orbital = new Float32Array(count * 3);
  const seeds = new Float32Array(count);
  const golden = Math.PI * (3 - Math.sqrt(5));
  for (let i = 0; i < count; i++) {
    const seed = ((i * 16807 + 113) % 65521) / 65521;
    const y = 1 - 2 * (i + 0.5) / count;
    const radial = Math.sqrt(1 - y * y);
    const angle = i * golden;
    const x = Math.cos(angle) * radial;
    const z = Math.sin(angle) * radial;
    const shell = i % 7 === 0 ? 0.5 + seed * 0.2 : 1.35 + seed * 0.1;
    membrane.set([x * shell, y * shell * 1.05, z * shell], i * 3);
    const side = i % 2 === 0 ? -1 : 1;
    division.set([x * shell * 0.68 + side * 0.86, y * shell * 0.79, z * shell * 0.75], i * 3);
    if (i % 5 === 0) {
      orbital.set([x * shell * 0.46, y * shell * 0.46, z * shell * 0.46], i * 3);
    } else {
      const ring = i % 9;
      const theta = angle + seed * 0.25;
      const r = 1.4 + ring * 0.045 + seed * 0.035;
      const tilt = ring * Math.PI / 9;
      const horizontal = Math.sin(theta) * r * 0.65;
      orbital.set([Math.cos(theta) * r, horizontal * Math.cos(tilt), horizontal * Math.sin(tilt)], i * 3);
    }
    seeds[i] = seed;
  }
  return { membrane, division, orbital, seeds };
}

const vertexShader = `
  attribute vec3 division;
  attribute vec3 orbital;
  attribute float seed;
  uniform float uTime;
  uniform float uMorph;
  uniform float uPixelRatio;
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
    vec3 p = mix(mix(position, division, a), orbital, b);
    p += flow(p * 1.5 + seed, uTime * 0.14) * 0.035;
    vec4 view = modelViewMatrix * vec4(p, 1.0);
    float depth = clamp(4.5 / -view.z, 0.55, 1.8);
    gl_PointSize = clamp((3.0 + seed * 3.0) * depth * uPixelRatio, 1.0, 11.0);
    gl_Position = projectionMatrix * view;
    vLight = clamp(depth * 0.88, 0.45, 1.15);
    vSeed = seed;
  }
`;
const fragmentShader = `
  varying float vLight;
  varying float vSeed;
  void main() {
    float d = length(gl_PointCoord - 0.5) * 2.0;
    if (d > 1.0) discard;
    float core = exp(-d*d*16.0);
    float halo = exp(-d*d*4.0) * 0.32;
    vec3 color = mix(vec3(0.47, 0.62, 0.80), vec3(0.86, 0.91, 0.97), vSeed);
    if (vSeed > 0.92) color = vec3(0.68, 0.62, 0.83);
    gl_FragColor = vec4(color, (core + halo) * vLight);
  }
`;

export function createParticleField(host: HTMLElement, onFailure: () => void): ParticleField {
  const count = matchMedia("(max-width: 640px)").matches ? 2048 : 4800;
  const ratio = Math.min(window.devicePixelRatio || 1, 1.5);
  const renderer = new THREE.WebGLRenderer({ antialias: false, alpha: true, powerPreference: "low-power" });
  renderer.setPixelRatio(ratio);
  renderer.setClearColor(0x111820, 0);
  renderer.domElement.setAttribute("aria-hidden", "true");
  host.appendChild(renderer.domElement);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(42, 1, 0.1, 30);
  camera.position.set(0, 0.2, 5.7);
  const controls = new OrbitControls(camera, renderer.domElement);
  controls.enablePan = false;
  controls.enableZoom = false;
  controls.enableDamping = false;
  controls.autoRotateSpeed = 0.32;
  controls.minPolarAngle = 0.25;
  controls.maxPolarAngle = Math.PI - 0.25;
  // Allow vertical page scrolling on touch; rotate with mouse or the visible buttons.
  renderer.domElement.style.touchAction = "pan-y";
  const data = positions(count);
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.BufferAttribute(data.membrane, 3));
  geometry.setAttribute("division", new THREE.BufferAttribute(data.division, 3));
  geometry.setAttribute("orbital", new THREE.BufferAttribute(data.orbital, 3));
  geometry.setAttribute("seed", new THREE.BufferAttribute(data.seeds, 1));
  const material = new THREE.ShaderMaterial({
    vertexShader, fragmentShader,
    uniforms: { uTime: { value: 0 }, uMorph: { value: 0 }, uPixelRatio: { value: ratio } },
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
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
    camera.fov = width < height ? 52 : 42;
    camera.updateProjectionMatrix();
    renderer.setSize(width, height, false);
    render();
  };
  const observer = new ResizeObserver(resize);
  observer.observe(host);
  const intersection = new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; sync(); });
  intersection.observe(host);
  const lost = (event: Event) => { event.preventDefault(); motion = false; sync(); onFailure(); };
  renderer.domElement.addEventListener("webglcontextlost", lost);
  controls.addEventListener("change", render);
  document.addEventListener("visibilitychange", sync);
  resize();
  return {
    setShape(value, immediate = false) {
      target = Math.max(0, Math.min(2, value));
      if (!motion || immediate) material.uniforms.uMorph.value = target;
      render();
    },
    setMotion(value) { motion = value; sync(); },
    rotate(direction) { controls.rotateLeft(direction * 0.22); controls.update(); render(); },
    reset() { camera.position.set(0, 0.2, 5.7); controls.target.set(0, 0, 0); controls.update(); render(); },
    dispose() {
      disposed = true;
      if (frame) cancelAnimationFrame(frame);
      document.removeEventListener("visibilitychange", sync);
      renderer.domElement.removeEventListener("webglcontextlost", lost);
      observer.disconnect(); intersection.disconnect(); controls.dispose();
      geometry.dispose(); material.dispose(); renderer.dispose();
      renderer.domElement.remove();
    },
  };
}
