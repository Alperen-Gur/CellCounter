import type { Calibration, LineageEdge, LineageEdgeKind, LineageGraph, LineageNode, OperationOptions, WorkspaceTrack } from './types';
import { checkAbort, fail, finite, integer, newID, yieldTask } from './guards';
export function validateLineage(graph: LineageGraph): void {
  if (!Array.isArray(graph.nodes) || !Array.isArray(graph.edges) || graph.nodes.length > 100_000 || graph.edges.length > 200_000) fail('resource-limit', 'Lineage exceeds the local graph limits.');
  const identifier = (value: unknown) => typeof value === 'string' && value.trim().length > 0 && value.length <= 1024;
  const nodes = new Map<string, LineageNode>();
  for (const node of graph.nodes) { if (!identifier(node.id) || nodes.has(node.id)) fail('duplicate-node', 'Lineage node identifiers must be bounded, nonempty, unique strings.'); for (const value of [node.label, node.sourceCellID]) if (value !== undefined && (typeof value !== 'string' || value.length > 1024)) fail('invalid-node', 'Lineage labels and source cell identifiers must be bounded strings.'); integer(node.frame, 'Lineage frame', 0); finite(node.coordinate.x, 'Lineage X'); finite(node.coordinate.y, 'Lineage Y'); nodes.set(node.id, node); }
  const edgeIDs = new Set<string>(); const links = new Set<string>();
  for (const edge of graph.edges) {
    if (!identifier(edge.id) || !identifier(edge.parentID) || !identifier(edge.childID) || edgeIDs.has(edge.id)) fail('duplicate-edge', 'Lineage relation identifiers must be bounded nonempty strings; edge identifiers must be unique.'); edgeIDs.add(edge.id);
    const parent = nodes.get(edge.parentID); const child = nodes.get(edge.childID);
    if (!parent || !child) fail('missing-node', 'A lineage link references a missing observation.');
    if (parent!.id === child!.id || child!.frame <= parent!.frame) fail('invalid-time-order', 'Lineage links must move forward in time.');
    if (!['continuation', 'gap', 'division', 'merge'].includes(edge.kind)) fail('invalid-lineage-kind', 'Unknown lineage relation.');
    const key = JSON.stringify([edge.parentID, edge.childID]); if (links.has(key)) fail('duplicate-edge', 'This lineage link already exists.'); links.add(key);
  }
  // Strict time increase proves acyclicity without recursive DFS stack overflow.
}
export function addLineageNode(graph: LineageGraph, node: Omit<LineageNode, 'id'> & { id?: string }): LineageNode {
  if (graph.nodes.length >= 100_000) fail('resource-limit', 'Lineage node limit reached.');
  integer(node.frame, 'Lineage frame', 0); finite(node.coordinate.x, 'Lineage X'); finite(node.coordinate.y, 'Lineage Y'); const created: LineageNode = { ...node, id: node.id ?? newID() };
  if (graph.nodes.some(item => item.id === created.id)) fail('duplicate-node', 'Lineage observation already exists.'); graph.nodes.push(created); return created;
}
export function linkLineage(graph: LineageGraph, parentID: string, childID: string, kind: LineageEdgeKind = 'continuation'): LineageEdge {
  if (graph.edges.length >= 200_000) fail('resource-limit', 'Lineage edge limit reached.');
  const edge: LineageEdge = { id: newID(), parentID, childID, kind };
  // Validate before mutation so failed/cyclic/dangling edits never persist.
  validateLineage({ nodes: graph.nodes, edges: [...graph.edges, edge] }); graph.edges.push(edge); return edge;
}
export function unlinkLineage(graph: LineageGraph, edgeID: string): void { graph.edges = graph.edges.filter(edge => edge.id !== edgeID); }
export function removeLineageNode(graph: LineageGraph, nodeID: string): void { graph.nodes = graph.nodes.filter(node => node.id !== nodeID); graph.edges = graph.edges.filter(edge => edge.parentID !== nodeID && edge.childID !== nodeID); }
export function lineageTracks(graph: LineageGraph): WorkspaceTrack[] {
  validateLineage(graph); const children = new Map<string, string[]>(); const parents = new Map<string, string[]>(); const nodes = new Map(graph.nodes.map(node => [node.id, node]));
  for (const edge of graph.edges) { const childList = children.get(edge.parentID) ?? []; childList.push(edge.childID); children.set(edge.parentID, childList); const parentList = parents.get(edge.childID) ?? []; parentList.push(edge.parentID); parents.set(edge.childID, parentList); }
  const tracks = []; const visited = new Set<string>();
  for (const start of graph.nodes.filter(node => (parents.get(node.id)?.length ?? 0) !== 1 || (children.get(parents.get(node.id)![0])?.length ?? 0) !== 1).concat(graph.nodes)) {
    if (visited.has(start.id)) continue; const vertices = []; let current: LineageNode | undefined = start;
    while (current && !visited.has(current.id)) { visited.add(current.id); vertices.push({ frame: current.frame, coordinate: { ...current.coordinate } }); const next: string[] = children.get(current.id) ?? []; current = next.length === 1 && (parents.get(next[0])?.length ?? 0) === 1 ? nodes.get(next[0]) : undefined; }
    tracks.push({ id: start.id, name: `Track ${tracks.length + 1}`, vertices });
  }
  return tracks;
}
interface Candidate { parent: number; child: number; distance: number }
function before(a: Candidate, b: Candidate): boolean { return a.distance < b.distance || (a.distance === b.distance && (a.parent < b.parent || a.parent === b.parent && a.child < b.child)); }
class CandidateHeap {
  private values: Candidate[] = [];
  push(value: Candidate): void { this.values.push(value); let child = this.values.length - 1; while (child > 0) { const parent = (child - 1) >>> 1; if (!before(this.values[child], this.values[parent])) break; [this.values[child], this.values[parent]] = [this.values[parent], this.values[child]]; child = parent; } }
  pop(): Candidate | undefined { if (!this.values.length) return undefined; const result = this.values[0]; const last = this.values.pop()!; if (this.values.length) { this.values[0] = last; let parent = 0; while (parent * 2 + 1 < this.values.length) { const left = parent * 2 + 1, right = left + 1; const child = right < this.values.length && before(this.values[right], this.values[left]) ? right : left; if (!before(this.values[child], this.values[parent])) break; [this.values[parent], this.values[child]] = [this.values[child], this.values[parent]]; parent = child; } } return result; }
}
export interface LineageBuildOptions extends OperationOptions { maxDistance: number; calibration?: Calibration; maxDistanceEvaluations?: number }
/** Consecutive observed-frame, distance-ordered one-to-one greedy links. Manual
 * gap/division/merge relations remain editable; no automatic biological claims. */
export async function buildLineage(observations: LineageNode[], options: LineageBuildOptions): Promise<LineageGraph> {
  const graph: LineageGraph = { nodes: observations.map(node => ({ ...node, coordinate: { ...node.coordinate } })), edges: [] }; validateLineage(graph);
  const maximum = finite(options.maxDistance, 'Lineage maximum distance'); if (maximum <= 0 || maximum > 1e9) fail('invalid-distance', 'Lineage distance must be in (0, 1e9].');
  const maxWork = integer(options.maxDistanceEvaluations ?? 5_000_000, 'Lineage distance work budget', 1, 5_000_000); const sx = options.calibration?.x ?? 1, sy = options.calibration?.y ?? 1;
  finite(sx, 'Lineage X calibration'); finite(sy, 'Lineage Y calibration'); if (sx <= 0 || sy <= 0) fail('invalid-calibration', 'Lineage X/Y calibration must be positive.');
  const snapshots = new Map<number, LineageNode[]>(); for (const node of graph.nodes) { const bucket = snapshots.get(node.frame) ?? []; bucket.push(node); snapshots.set(node.frame, bucket); }
  const frames = [...snapshots.keys()].sort((a, b) => a - b); let work = 0;
  const key = (x: number, y: number) => `${x},${y}`; const gridCoordinate = (node: LineageNode) => ({ x: integer(Math.floor(node.coordinate.x * sx / maximum), 'Lineage grid X', -Number.MAX_SAFE_INTEGER + 1, Number.MAX_SAFE_INTEGER - 1), y: integer(Math.floor(node.coordinate.y * sy / maximum), 'Lineage grid Y', -Number.MAX_SAFE_INTEGER + 1, Number.MAX_SAFE_INTEGER - 1) });
  for (let transition = 0; transition + 1 < frames.length; transition++) {
    await yieldTask(options.signal); const parents = snapshots.get(frames[transition])!, children = snapshots.get(frames[transition + 1])!; const grid = new Map<string, number[]>(); const usedParents = new Uint8Array(parents.length), usedChildren = new Uint8Array(children.length); const heap = new CandidateHeap();
    for (let child = 0; child < children.length; child++) { const p = gridCoordinate(children[child]), name = key(p.x, p.y); const bucket = grid.get(name) ?? []; bucket.push(child); grid.set(name, bucket); }
    const nearest = async (parent: number): Promise<Candidate | undefined> => {
      const p = parents[parent]; const center = gridCoordinate(p); let best: Candidate | undefined;
      for (let gy = -1; gy <= 1; gy++) for (let gx = -1; gx <= 1; gx++) for (const child of grid.get(key(center.x + gx, center.y + gy)) ?? []) {
        if (usedChildren[child]) continue; if (++work > maxWork) fail('resource-limit', 'Dense lineage matching exceeds the local work budget. Reduce the matching distance or process fewer observations.'); if (work % 2048 === 0) await yieldTask(options.signal);
        const c = children[child]; const dx = (p.coordinate.x - c.coordinate.x) * sx, dy = (p.coordinate.y - c.coordinate.y) * sy; const distance = dx * dx + dy * dy;
        if (!Number.isFinite(distance) || distance > maximum * maximum) continue; const candidate = { parent, child, distance }; if (!best || before(candidate, best)) best = candidate;
      }
      return best;
    };
    for (let parent = 0; parent < parents.length; parent++) { if (parent % 256 === 0) await yieldTask(options.signal); const candidate = await nearest(parent); if (candidate) heap.push(candidate); }
    let popped = 0; let candidate: Candidate | undefined;
    while ((candidate = heap.pop())) {
      if (++popped % 1024 === 0) await yieldTask(options.signal); if (usedParents[candidate.parent]) continue;
      if (usedChildren[candidate.child]) { const next = await nearest(candidate.parent); if (next) heap.push(next); continue; }
      usedParents[candidate.parent] = 1; usedChildren[candidate.child] = 1; graph.edges.push({ id: newID(), parentID: parents[candidate.parent].id, childID: children[candidate.child].id, kind: frames[transition + 1] === frames[transition] + 1 ? 'continuation' : 'gap' });
    }
    options.onProgress?.((transition + 1) / Math.max(1, frames.length - 1));
  }
  checkAbort(options.signal); validateLineage(graph); return graph;
}
