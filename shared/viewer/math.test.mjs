import assert from "node:assert/strict";
import test from "node:test";
import { decodeVolume, displayToOriginal, originalToDisplay, planePoint, voxelIndex, rotationMatrix } from "./math.js";

function descriptor(overrides = {}) {
  return {
    imageId: "sample", timeIndex: 0, channel: 0, dtype: "uint8", order: "zyx",
    dimensions: [2, 3, 4], originalDimensions: [4, 9, 16],
    data: new Uint8Array(24).map((_, index) => index),
    displayRange: [0, 65535], transform: { scale: [2, 3, 4], offset: [.5, 1, 1.5] },
    voxelSizeUm: { x: .2, y: .2, z: 1 },
    ...overrides,
  };
}

test("center-aligned source coordinates round-trip and retain physical anisotropy", () => {
  const volume = decodeVolume(descriptor());
  const source = displayToOriginal(volume, [1, 2, 3]);
  assert.deepEqual(source, [2.5, 7, 13.5]);
  assert.deepEqual(originalToDisplay(volume, source), [1, 2, 3]);
  assert.deepEqual(volume.extent, [.8, 1.8, 16]);
  assert.equal(volume.calibrated, true);
});

test("all orthogonal planes index the same X-fastest volume", () => {
  const volume = decodeVolume(descriptor());
  assert.equal(volume.data[voxelIndex(volume.dimensions, 1, 2, 3)], 23);
  const crosshair = displayToOriginal(volume, [1, 1, 2]);
  assert.deepEqual(planePoint(volume, "xy", 0, 2, crosshair).displayVoxel, [0, 2, 2]);
  assert.deepEqual(planePoint(volume, "xz", 0, 3, crosshair).displayVoxel, [0, 1, 3]);
  assert.deepEqual(planePoint(volume, "yz", 2, 0, crosshair).displayVoxel, [1, 2, 0]);
  assert.deepEqual(planePoint(volume, "yz", 99, -1, crosshair).displayVoxel, [1, 2, 0]);
});

test("missing spacing never becomes an invented physical Z scale", () => {
  const volume = decodeVolume(descriptor({ voxelSizeUm: { x: .2, y: .2, z: null } }));
  assert.equal(volume.calibrated, false);
  assert.deepEqual(volume.extent, [4, 9, 16]);
});

test("base64 intensity and uint32 little-endian labels are exact", () => {
  const labels = Buffer.alloc(24 * 4);
  labels.writeUInt32LE(0xffffffff, 23 * 4);
  const volume = decodeVolume(descriptor({
    data: undefined, dataBase64: Buffer.from([...Array(24).keys()]).toString("base64"),
    labelDataBase64: labels.toString("base64"), labelDtype: "uint32-le",
  }));
  assert.equal(volume.data[23], 23);
  assert.equal(volume.labels[23], 0xffffffff);
  assert.equal(volume.labels[0], 0);
  assert.equal(volume.dataBase64, undefined);
  assert.equal(volume.labelDataBase64, undefined);
});

test("malformed, oversized or mismatched display allocations are rejected", () => {
  for (const invalid of [
    { dimensions: [129, 1, 1] }, { dimensions: [2, 0, 4] }, { originalDimensions: [1, 1, 1] },
    { transform: { scale: [2, 3, 4], offset: [0, 0, 0] } },
    { data: new Uint8Array(25) }, { data: undefined, dataBase64: "not base64" },
    { data: undefined, dataBase64: Buffer.from([1, 2]).toString("base64") },
    { labelData: new Uint32Array(25) }, { displayRange: [Infinity, 5] },
    { displayRange: [5, 2] }, { dtype: "float64" },
  ]) assert.throws(() => decodeVolume(descriptor(invalid)));
});

test("a one-voxel axis and identity source/display transform remain valid", () => {
  const volume = decodeVolume(descriptor({
    dimensions: [2, 3, 1], originalDimensions: [2, 3, 1], data: new Uint8Array(6),
    transform: { scale: [1, 1, 1], offset: [0, 0, 0] },
  }));
  assert.deepEqual(displayToOriginal(volume, [1, 2, 0]), [1, 2, 0]);
  assert.deepEqual(planePoint(volume, "xy", 10, 10, [0, 0, 0]).voxel, [1, 2, 0]);
});

test("rotation is orthonormal and does not distort anisotropic world geometry", () => {
  const matrix = rotationMatrix(.7, -.4);
  for (let first = 0; first < 3; first++) {
    for (let second = 0; second < 3; second++) {
      let product = 0;
      for (let row = 0; row < 3; row++) product += matrix[first * 3 + row] * matrix[second * 3 + row];
      assert.ok(Math.abs(product - (first === second ? 1 : 0)) < 1e-6);
    }
  }
});
