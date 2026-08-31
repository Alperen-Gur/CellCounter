import { connectedComponents, mean } from "./math";
import { assertCalibration, assertLabelMap, type IdentifiedPoint, type LabelMap } from "./types";

export interface Soma extends IdentifiedPoint { readonly radiusPx?: number }
export interface NeuriteCellMeasurement {
  readonly somaId: string;
  readonly totalLengthUm: number;
  readonly primaryProcessCount: number;
  readonly branchPointCount: number;
  readonly skeletonPixelCount: number;
}
export interface NeuriteResult {
  readonly cells: readonly NeuriteCellMeasurement[];
  readonly skeleton: Uint8Array;
  readonly meanNeuriteLengthUm: number;
  readonly totalSkeletonLengthUm: number;
  readonly unattributedLengthUm: number;
  readonly caveat: string;
  readonly message: string | null;
}

/** Zhang–Suen thinning over a copied binary mask. */
export function skeletonize(mask: LabelMap, signal?: AbortSignal): Uint8Array {
  assertLabelMap(mask);
  const output = new Uint8Array(mask.data.length);
  for (let index = 0; index < output.length; index += 1) output[index] = mask.data[index] ? 1 : 0;
  const { width, height } = mask;
  const marked = new Uint8Array(output.length);
  const mark = (secondPass: boolean): number => {
    marked.fill(0); let count = 0;
    for (let y = 1; y < height - 1; y += 1) {
      if ((y & 63) === 0) signal?.throwIfAborted();
      for (let x = 1; x < width - 1; x += 1) {
      const index = y * width + x;
      if (!output[index]) continue;
      const p = [
        output[index - width], output[index - width + 1], output[index + 1], output[index + width + 1],
        output[index + width], output[index + width - 1], output[index - 1], output[index - width - 1],
      ];
      const neighbors = p.reduce((sum, value) => sum + value, 0);
      if (neighbors < 2 || neighbors > 6) continue;
      let transitions = 0;
      for (let n = 0; n < 8; n += 1) if (!p[n] && p[(n + 1) % 8]) transitions += 1;
      if (transitions !== 1) continue;
      const blocked = secondPass ? p[0] * p[2] * p[6] || p[0] * p[4] * p[6] : p[0] * p[2] * p[4] || p[2] * p[4] * p[6];
      if (blocked) continue;
      marked[index] = 1; count += 1;
    }
    }
    for (let index = 0; index < output.length; index += 1) if (marked[index]) output[index] = 0;
    return count;
  };
  while (mark(false) + mark(true) > 0) { signal?.throwIfAborted(); }
  return output;
}

interface KdNode { readonly somaIndex: number; readonly axis: 0 | 1; readonly left: KdNode | null; readonly right: KdNode | null }
function buildKdTree(indices: number[], somas: readonly Soma[], depth = 0): KdNode | null {
  if (!indices.length) return null;
  const axis = (depth % 2) as 0 | 1;
  const coordinate = (index: number) => axis ? somas[index].y : somas[index].x;
  indices.sort((a, b) => coordinate(a) - coordinate(b) || somas[a].id.localeCompare(somas[b].id));
  const middle = Math.floor(indices.length / 2);
  return { somaIndex: indices[middle], axis, left: buildKdTree(indices.slice(0, middle), somas, depth + 1), right: buildKdTree(indices.slice(middle + 1), somas, depth + 1) };
}
function nearestSoma(root: KdNode | null, somas: readonly Soma[], x: number, y: number): number {
  let bestIndex = -1; let bestDistance = Infinity;
  const visit = (node: KdNode | null): void => {
    if (!node) return;
    const soma = somas[node.somaIndex];
    const distance = (soma.x - x) ** 2 + (soma.y - y) ** 2;
    if (distance < bestDistance || (distance === bestDistance && (bestIndex < 0 || soma.id < somas[bestIndex].id))) { bestDistance = distance; bestIndex = node.somaIndex; }
    const delta = node.axis ? y - soma.y : x - soma.x;
    visit(delta <= 0 ? node.left : node.right);
    if (delta * delta <= bestDistance) visit(delta <= 0 ? node.right : node.left);
  };
  visit(root);
  return bestIndex;
}

function skeletonDegree(skeleton: Uint8Array, index: number, width: number, height: number): number {
  const x = index % width; const y = Math.floor(index / width); let degree = 0;
  for (let dy = -1; dy <= 1; dy += 1) for (let dx = -1; dx <= 1; dx += 1) {
    if ((!dx && !dy) || x + dx < 0 || x + dx >= width || y + dy < 0 || y + dy >= height) continue;
    degree += skeleton[(y + dy) * width + x + dx];
  }
  return degree;
}

export function analyzeNeurites(
  neuriteMask: LabelMap,
  somas: readonly Soma[],
  options: { readonly pxPerUm: number; readonly defaultSomaRadiusUm?: number; readonly signal?: AbortSignal },
): NeuriteResult {
  assertLabelMap(neuriteMask); assertCalibration(options.pxPerUm);
  if (new Set(somas.map(({ id }) => id)).size !== somas.length) throw new RangeError("Soma ids must be unique.");
  const somaResolved = somas.map((soma) => ({ ...soma, radiusPx: soma.radiusPx ?? (options.defaultSomaRadiusUm ?? 6) * options.pxPerUm }));
  const punched = new Uint32Array(neuriteMask.data);
  // Punch each compact soma footprint directly instead of scanning every mask pixel against every soma.
  for (const soma of somaResolved) {
    options.signal?.throwIfAborted();
    const x0 = Math.max(0, Math.floor(soma.x - soma.radiusPx)); const x1 = Math.min(neuriteMask.width - 1, Math.ceil(soma.x + soma.radiusPx));
    const y0 = Math.max(0, Math.floor(soma.y - soma.radiusPx)); const y1 = Math.min(neuriteMask.height - 1, Math.ceil(soma.y + soma.radiusPx));
    for (let y = y0; y <= y1; y += 1) for (let x = x0; x <= x1; x += 1) if ((x - soma.x) ** 2 + (y - soma.y) ** 2 <= soma.radiusPx ** 2) punched[y * neuriteMask.width + x] = 0;
  }
  const skeleton = skeletonize({ data: punched, width: neuriteMask.width, height: neuriteMask.height }, options.signal);
  const components = connectedComponents(skeleton, neuriteMask.width, neuriteMask.height, true, options.signal);
  const tree = buildKdTree(somaResolved.map((_, index) => index), somaResolved);
  const ownerByPixel = new Int32Array(skeleton.length); ownerByPixel.fill(-1);
  const componentsByOwner: number[][] = Array.from({ length: somaResolved.length }, () => []);
  for (let componentIndex = 0; componentIndex < components.length; componentIndex += 1) {
    options.signal?.throwIfAborted();
    const component = components[componentIndex];
    if (!somaResolved.length) continue;
    const votes = new Map<number, number>();
    for (const index of component.pixels) {
      const x = index % neuriteMask.width; const y = Math.floor(index / neuriteMask.width);
      const nearest = nearestSoma(tree, somaResolved, x, y);
      votes.set(nearest, (votes.get(nearest) ?? 0) + 1);
    }
    const owner = [...votes].sort((a, b) => b[1] - a[1] || somaResolved[a[0]].id.localeCompare(somaResolved[b[0]].id))[0][0];
    componentsByOwner[owner].push(componentIndex);
    for (const pixel of component.pixels) ownerByPixel[pixel] = owner;
  }
  const lengthByOwner = new Float64Array(somaResolved.length + 1);
  const unattributedIndex = somaResolved.length;
  for (let index = 0; index < skeleton.length; index += 1) {
    if ((index & 0xffff) === 0) options.signal?.throwIfAborted();
    if (!skeleton[index]) continue;
    const x = index % neuriteMask.width; const y = Math.floor(index / neuriteMask.width);
    for (const [dx, dy] of [[1, 0], [0, 1], [1, 1], [-1, 1]]) {
      const nx = x + dx; const ny = y + dy;
      if (nx < 0 || nx >= neuriteMask.width || ny >= neuriteMask.height) continue;
      const next = ny * neuriteMask.width + nx;
      if (!skeleton[next]) continue;
      const owner = ownerByPixel[index] === ownerByPixel[next] && ownerByPixel[index] >= 0 ? ownerByPixel[index] : unattributedIndex;
      lengthByOwner[owner] += (dx && dy ? Math.SQRT2 : 1) / options.pxPerUm;
    }
  }
  const cells = somaResolved.map((soma, somaIndex) => {
    const ownedComponents = componentsByOwner[somaIndex].map((index) => components[index]);
    let skeletonPixelCount = 0;
    let branchPointCount = 0;
    for (const component of ownedComponents) for (const index of component.pixels) {
      skeletonPixelCount += 1;
      if (skeletonDegree(skeleton, index, neuriteMask.width, neuriteMask.height) >= 3) branchPointCount += 1;
    }
    const primaryProcessCount = ownedComponents.filter((component) => component.pixels.some((index) => {
      const x = index % neuriteMask.width; const y = Math.floor(index / neuriteMask.width);
      const distance = Math.hypot(x - soma.x, y - soma.y);
      return distance <= soma.radiusPx + 2;
    })).length;
    return {
      somaId: soma.id,
      totalLengthUm: lengthByOwner[somaIndex],
      primaryProcessCount,
      branchPointCount,
      skeletonPixelCount,
    };
  });
  let totalSkeletonLengthUm = 0;
  for (const length of lengthByOwner) totalSkeletonLengthUm += length;
  const caveat = "Overlapping neurites cannot be reliably separated: connected skeleton fragments are attributed to the nearest soma by majority vote, a Voronoi estimate rather than true instance segmentation.";
  return {
    cells,
    skeleton,
    meanNeuriteLengthUm: mean(cells.map(({ totalLengthUm }) => totalLengthUm)) ?? 0,
    totalSkeletonLengthUm,
    unattributedLengthUm: lengthByOwner[unattributedIndex],
    caveat,
    message: skeleton.some(Boolean) ? somas.length ? null : "No somas were supplied; only whole-image skeleton length is available." : "The neurite mask contains no measurable skeleton.",
  };
}
