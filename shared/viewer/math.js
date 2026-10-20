/** Geometry for bounded display volumes. Scientific arrays remain in the runtime. */
export const MAX_DIMENSION = 128;
export const MAX_VOXELS = MAX_DIMENSION ** 3;
export const clamp = (value, low, high) => Math.min(high, Math.max(low, value));

function triple(value, name, predicate) {
  if (!Array.isArray(value) || value.length !== 3 || !value.every(predicate)) {
    throw new Error(`${name} must contain three valid X, Y and Z values.`);
  }
  return [...value];
}

function bytes(base64, expected, name) {
  if (typeof base64 !== "string" || base64.length > Math.ceil(expected / 3) * 4 + 4) {
    throw new Error(`${name} exceeds its bounded volume allocation.`);
  }
  let decoded;
  try { decoded = atob(base64); } catch { throw new Error(`${name} is not valid base64.`); }
  if (decoded.length !== expected) throw new Error(`${name} byte count does not match its dimensions.`);
  const result = new Uint8Array(expected);
  for (let index = 0; index < expected; index++) result[index] = decoded.charCodeAt(index);
  return result;
}

export function decodeVolume(descriptor) {
  if (!descriptor || descriptor.dtype !== "uint8" || descriptor.order !== "zyx") {
    throw new Error("The viewer requires an X-fastest uint8 volume with ZYX storage order.");
  }
  const dimensions = triple(descriptor.dimensions, "Dimensions",
    (value) => Number.isInteger(value) && value > 0 && value <= MAX_DIMENSION);
  const originalDimensions = triple(descriptor.originalDimensions, "Original dimensions",
    (value) => Number.isInteger(value) && value > 0 && value <= 1_000_000);
  if (dimensions.some((size, axis) => size > originalDimensions[axis])) {
    throw new Error("Display dimensions cannot exceed the original volume.");
  }
  const length = dimensions.reduce((product, size) => product * size, 1);
  if (length > MAX_VOXELS) throw new Error("Display volume exceeds 128³ voxels.");
  const composite = descriptor.displayKind === "composite";
  const components = descriptor.components ?? 1;
  if ((composite && (components !== 4 || descriptor.componentOrder !== "rgba")) ||
      (!composite && components !== 1)) {
    throw new Error("Display data must contain one intensity component or four composite RGBA components.");
  }
  if (descriptor.displayKind != null && !["intensity", "composite"].includes(descriptor.displayKind)) {
    throw new Error("The volume display kind is unsupported.");
  }
  const byteLength = length * components;
  const scale = triple(descriptor.transform?.scale, "Display scale", (value) => Number.isFinite(value) && value > 0);
  const offset = triple(descriptor.transform?.offset, "Display offset", Number.isFinite);
  if (scale.some((value, axis) => Math.abs(value - originalDimensions[axis] / dimensions[axis]) > 1e-6) ||
      offset.some((value, axis) => Math.abs(value - (scale[axis] - 1) / 2) > 1e-6)) {
    throw new Error("Display coordinates do not match the center-aligned source transform.");
  }
  const range = descriptor.displayRange;
  if (!Array.isArray(range) || range.length !== 2 || !range.every(Number.isFinite) || range[0] > range[1]) {
    throw new Error("The source intensity range is invalid.");
  }
  if (composite && (range[0] !== 0 || range[1] !== 255)) {
    throw new Error("Composite colors must use the normalized 0–255 display range.");
  }
  if (descriptor.data instanceof Uint8Array && descriptor.data.length !== byteLength)
    throw new Error("Intensity byte count does not match its dimensions.");
  const data = descriptor.data instanceof Uint8Array
    ? new Uint8Array(descriptor.data) : bytes(descriptor.dataBase64, byteLength, "Display data");
  if (data.length !== byteLength) throw new Error("Display byte count does not match its dimensions.");
  let labels = null;
  if (descriptor.labelData instanceof Uint32Array) {
    if (descriptor.labelData.length !== length) throw new Error("Label count does not match its dimensions.");
    labels = new Uint32Array(descriptor.labelData);
  } else if (descriptor.labelDataBase64 != null) {
    if (descriptor.labelDtype !== "uint32-le") throw new Error("Display labels must be unsigned 32-bit little-endian integers.");
    const raw = bytes(descriptor.labelDataBase64, length * 4, "Label data");
    labels = new Uint32Array(length);
    const view = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
    for (let index = 0; index < length; index++) labels[index] = view.getUint32(index * 4, true);
  }
  const spacing = ["x", "y", "z"].map((axis) => descriptor.voxelSizeUm?.[axis]);
  const calibrated = spacing.every((value) => Number.isFinite(value) && value > 0);
  const extent = originalDimensions.map((size, axis) => size * (calibrated ? spacing[axis] : 1));
  const longest = Math.max(...extent);
  const decoded = {
    ...descriptor, dimensions, originalDimensions, data, labels, components, composite,
    transform: { scale, offset }, displayRange: [...range],
    extent, halfExtent: extent.map((size) => size / longest / 2),
    calibrated, voxelSizeUm: { ...descriptor.voxelSizeUm },
  };
  delete decoded.dataBase64; delete decoded.labelDataBase64; delete decoded.labelData;
  return decoded;
}

export function displayToOriginal(volume, xyz) {
  return xyz.map((value, axis) => clamp(
    value * volume.transform.scale[axis] + volume.transform.offset[axis],
    0, volume.originalDimensions[axis] - 1));
}

export function originalToDisplay(volume, xyz) {
  return xyz.map((value, axis) => clamp(
    (value - volume.transform.offset[axis]) / volume.transform.scale[axis],
    0, volume.dimensions[axis] - 1));
}

export const PLANE_AXES = {
  xy: { horizontal: 0, vertical: 1, normal: 2 },
  xz: { horizontal: 0, vertical: 2, normal: 1 },
  yz: { horizontal: 1, vertical: 2, normal: 0 },
};

export function voxelIndex(dimensions, x, y, z) {
  return (z * dimensions[1] + y) * dimensions[0] + x;
}

export function planePoint(volume, plane, horizontal, vertical, crosshair) {
  const axes = PLANE_AXES[plane];
  if (!axes) throw new Error("Unknown orthogonal plane.");
  const display = originalToDisplay(volume, crosshair).map(Math.round);
  display[axes.horizontal] = clamp(Math.round(horizontal), 0, volume.dimensions[axes.horizontal] - 1);
  display[axes.vertical] = clamp(Math.round(vertical), 0, volume.dimensions[axes.vertical] - 1);
  return { displayVoxel: display, voxel: displayToOriginal(volume, display) };
}

export function rotationMatrix(yaw, pitch) {
  const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
  return new Float32Array([cy, 0, -sy, sy * sp, cp, cy * sp, sy * cp, -sp, cy * cp]);
}
