import { spawnSync } from "node:child_process";

const result = spawnSync(process.execPath, ["node_modules/vitest/vitest.mjs", "--run", "tests/parity"], { stdio: "inherit" });
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
console.log("Web parity analysis verification passed");
