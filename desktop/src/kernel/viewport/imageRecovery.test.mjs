import assert from "node:assert/strict";
import { test } from "node:test";
import { assetPath } from "./imageRecovery.ts";

test("asset URLs preserve native Windows paths and literal profile characters", () => {
  const path = "C:\\Users\\Jörg [lab]\\AppData\\Roaming\\com.alperengur.cellcounter\\CellCounter\\Images\\image.jpg";
  for (const scheme of ["http", "https"]) {
    assert.equal(assetPath(`${scheme}://asset.localhost/${encodeURIComponent(path)}`), path);
  }
});

test("asset URLs preserve absolute Unix paths and percent/hash characters", () => {
  const path = "/Users/lab/CellCounter/Images/100% #sample.tiff";
  assert.equal(assetPath(`asset://localhost/${encodeURIComponent(path)}`), path);
});

test("unrelated and malformed URLs cannot request a native preview", () => {
  for (const src of ["file:///tmp/image.jpg", "https://example.com/image.jpg",
    "http://asset.localhost.example.com/image.jpg", "data:image/png;base64,AA==",
    "asset://localhost/%ZZ", "not a URL"]) {
    assert.equal(assetPath(src), null);
  }
});
