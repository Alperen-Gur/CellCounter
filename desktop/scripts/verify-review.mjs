import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const desktop = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (path) => readFileSync(join(desktop,path),"utf8");
function contract(hook, registry) {
  for (const name of ["review_page","review_context","review_decision","review_undo"]) {
    assert.ok(hook.includes(`"${name}"`),`Review must call ${name}`);
    assert.ok(registry.includes(`db::review::${name}`),`Backend must register ${name}`);
  }
  for (const bulk of [".getDetections(",".allImages(",".allBatches(",".commitCellEdit("]) {
    assert.ok(!hook.includes(bulk),`Review cannot use ${bulk}`);
  }
}
const hook = read("src/pages/review/useReviewQueue.ts");
const registry = read("src-tauri/src/lib.rs");
contract(hook,registry);
assert.throws(() => contract(hook.replace('"review_page"','"missing"'),registry));
assert.throws(() => contract(`${hook}\nport.getDetections(ids)`,registry));
function run(args) {
  const result = spawnSync(process.execPath,args,{ cwd: desktop, stdio:"inherit" });
  if (result.error) throw result.error;
  assert.equal(result.status,0,`Review verification failed: ${args.join(" ")}`);
}
run(["--experimental-strip-types","--test","scripts/review-session.test.mjs"]);
if (process.argv.includes("--build")) {
  run(["node_modules/typescript/bin/tsc"]);
  run(["node_modules/vite/bin/vite.js","build"]);
}
console.log("Review integration verification passed");
