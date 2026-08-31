import { readFile, readdir } from "node:fs/promises";
import { join, relative } from "node:path";

const root = new URL("../", import.meta.url);
const sourceRoot = new URL("../src/", import.meta.url);

async function filesUnder(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map((entry) => {
    const path = join(directory.pathname, entry.name);
    if (entry.isDirectory()) return filesUnder(new URL(`file://${path}/`));
    return /\.(ts|tsx)$/.test(entry.name) ? [path] : [];
  }));
  return nested.flat();
}

const forbidden = [
  [/navigator\.sendBeacon\s*\(/, "sendBeacon"],
  [/new\s+XMLHttpRequest\s*\(/, "XMLHttpRequest"],
  [/new\s+WebSocket\s*\(/, "WebSocket"],
  [/new\s+EventSource\s*\(/, "EventSource"],
  [/RTCPeerConnection/, "peer connection"],
  [/\b(?:segment|mixpanel|amplitude|sentry|posthog|google-analytics)\b/i, "telemetry dependency"],
];

function privacyFindings(contents, path) {
  const findings = forbidden.filter(([pattern]) => pattern.test(contents)).map(([, label]) => `${path}: ${label}`);
  if (!path.endsWith("src/models/WebGpuInference.ts") && /\bfetch\s*\(/.test(contents)) findings.push(`${path}: network fetch outside model loader`);
  if (!path.endsWith("src/models/catalog.ts") && /https?:\/\//.test(contents)) findings.push(`${path}: external URL`);
  return findings;
}

const positive = privacyFindings("navigator.sendBeacon('/telemetry', pixels); fetch('/upload')", "positive-control.ts");
if (positive.length < 2) throw new Error("Privacy scanner positive control did not detect forbidden network paths");

const sourceFiles = await filesUnder(sourceRoot);
const findings = [];
for (const file of sourceFiles) {
  findings.push(...privacyFindings(await readFile(file, "utf8"), relative(root.pathname, file)));
}

const [html, viteConfig, packageJson, inference, catalog] = await Promise.all([
  readFile(new URL("../index.html", import.meta.url), "utf8"),
  readFile(new URL("../vite.config.ts", import.meta.url), "utf8"),
  readFile(new URL("../package.json", import.meta.url), "utf8"),
  readFile(new URL("../src/models/WebGpuInference.ts", import.meta.url), "utf8"),
  readFile(new URL("../src/models/catalog.ts", import.meta.url), "utf8"),
]);

if (!html.includes("connect-src 'self'")) findings.push("index.html: CSP permits external connections");
if (!html.includes("form-action 'none'")) findings.push("index.html: forms are not disabled by CSP");
if (!html.includes("img-src 'self' blob: data:")) findings.push("index.html: local Blob image display is not explicit");
if (!viteConfig.includes("runtimeCaching: []")) findings.push("vite.config.ts: service worker has a runtime network cache");
if (!inference.includes("credentials: \"same-origin\"") || !inference.includes("referrerPolicy: \"no-referrer\"")) findings.push("model fetch lacks strict same-origin privacy options");
if (!/url:\s*"\/models\//.test(catalog) || /url:\s*"https?:/.test(catalog)) findings.push("model artifacts are not constrained to same-origin paths");

const dependencies = Object.keys(JSON.parse(packageJson).dependencies ?? {});
if (dependencies.some((name) => /analytics|telemetry|sentry|segment|mixpanel|posthog/i.test(name))) findings.push("package.json: telemetry dependency found");

if (findings.length) throw new Error(`Privacy audit failed:\n${findings.join("\n")}`);
console.log(`Web privacy verification passed (${sourceFiles.length} source files; positive control detected ${positive.length} violations)`);
