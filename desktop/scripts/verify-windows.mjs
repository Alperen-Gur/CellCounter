import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const directory = dirname(fileURLToPath(import.meta.url));
const checks = [
  "verify-windows-bundle.mjs",
  "verify-windows-ci.mjs",
  "verify-windows-docs.mjs",
  "verify-models.mjs",
  "verify-parity.mjs",
  "verify-speed-contract.mjs",
];

for (const check of checks) {
  const result = spawnSync(process.execPath, [join(directory, check)], {
    cwd: join(directory, ".."),
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}

console.log("Windows release contract verification passed");
