import { readFile, stat } from "node:fs/promises";
import { resolve } from "node:path";

const dist = resolve("dist");
const serviceWorker = await readFile(resolve(dist, "sw.js"), "utf8");
const urls = [...serviceWorker.matchAll(/url:\s*["']([^"']+)["']/g)].map((match) => match[1]);
const forbidden = urls.filter((url) => /(?:\/ort(?:[.-])|inference\.worker-|\/models\/|\.onnx(?:$|\?))/.test(url));
if (forbidden.length) throw new Error(`Inference-only assets are eagerly precached: ${forbidden.join(", ")}`);

let eagerBytes = 0;
for (const url of new Set(urls)) {
  const relative = url.replace(/^\//, "").split("?")[0];
  try { eagerBytes += (await stat(resolve(dist, relative))).size; }
  catch { /* Workbox may include generated URLs not represented as ordinary files. */ }
}
const budget = 2 * 1024 * 1024;
if (eagerBytes > budget) throw new Error(`Eager precache is ${eagerBytes} bytes, above ${budget}`);
console.log(`Web performance verification passed: eager precache ${eagerBytes} bytes (${urls.length} entries)`);
