import { mean } from "./math";
import { assertCalibration, type IdentifiedPoint } from "./types";

export interface TrackingFrame {
  readonly frame: number;
  readonly points: readonly IdentifiedPoint[];
}

export interface TrackPoint {
  readonly frame: number;
  readonly sourceId: string;
  readonly xPx: number;
  readonly yPx: number;
  readonly xUm: number;
  readonly yUm: number;
}

export interface CellTrack {
  readonly trackId: number;
  readonly startFrame: number;
  readonly endFrame: number;
  readonly durationFrames: number;
  readonly durationMin: number;
  readonly totalPathLengthUm: number;
  readonly netDisplacementUm: number;
  readonly meanSpeedUmPerMin: number;
  readonly directionalityRatio: number;
  readonly points: readonly TrackPoint[];
}

export interface TrackingResult {
  readonly frameCount: number;
  readonly tracks: readonly CellTrack[];
  readonly summary: {
    readonly trackCount: number;
    readonly tracksWithMotion: number;
    readonly meanSpeedUmPerMin: number;
    readonly meanDirectionalityRatio: number;
    readonly meanTrackDurationMin: number;
  };
  readonly parameters: { readonly pxPerUm: number; readonly frameIntervalMin: number; readonly maxDisplacementUm: number };
}

/** Minimum-cost rectangular assignment. Rows must not exceed columns. */
function hungarian(cost: readonly (readonly number[])[]): number[] {
  const rows = cost.length;
  const columns = cost[0]?.length ?? 0;
  if (!rows) return [];
  if (columns < rows || cost.some((row) => row.length !== columns)) throw new RangeError("Assignment matrix must be rectangular with rows ≤ columns.");
  const u = new Float64Array(rows + 1);
  const v = new Float64Array(columns + 1);
  const p = new Int32Array(columns + 1);
  const way = new Int32Array(columns + 1);
  for (let i = 1; i <= rows; i += 1) {
    p[0] = i;
    let j0 = 0;
    const minimum = new Float64Array(columns + 1); minimum.fill(Infinity);
    const used = new Uint8Array(columns + 1);
    do {
      used[j0] = 1;
      const i0 = p[j0];
      let delta = Infinity; let j1 = 0;
      for (let j = 1; j <= columns; j += 1) {
        if (used[j]) continue;
        const current = cost[i0 - 1][j - 1] - u[i0] - v[j];
        if (current < minimum[j]) { minimum[j] = current; way[j] = j0; }
        if (minimum[j] < delta) { delta = minimum[j]; j1 = j; }
      }
      for (let j = 0; j <= columns; j += 1) {
        if (used[j]) { u[p[j]] += delta; v[j] -= delta; }
        else minimum[j] -= delta;
      }
      j0 = j1;
    } while (p[j0] !== 0);
    do {
      const j1 = way[j0]; p[j0] = p[j1]; j0 = j1;
    } while (j0 !== 0);
  }
  const assignment = new Array<number>(rows).fill(-1);
  for (let j = 1; j <= columns; j += 1) if (p[j] > 0) assignment[p[j] - 1] = j - 1;
  return assignment;
}

export function trackCells(
  framesInput: readonly TrackingFrame[],
  options: { readonly pxPerUm: number; readonly frameIntervalMin: number; readonly maxDisplacementUm: number },
): TrackingResult {
  assertCalibration(options.pxPerUm);
  if (!(options.frameIntervalMin > 0) || !(options.maxDisplacementUm > 0)) throw new RangeError("Frame interval and maximum displacement must be positive.");
  if (framesInput.length < 2) throw new RangeError("Tracking needs at least two frames.");
  const frames = [...framesInput].sort((a, b) => a.frame - b.frame);
  if (new Set(frames.map(({ frame }) => frame)).size !== frames.length) throw new RangeError("Tracking frame numbers must be unique.");
  for (const frame of frames) if (new Set(frame.points.map(({ id }) => id)).size !== frame.points.length) throw new RangeError(`Source ids must be unique within frame ${frame.frame}.`);
  type MutableTrack = { trackId: number; points: TrackPoint[] };
  const toTrackPoint = (frame: number, point: IdentifiedPoint): TrackPoint => ({ frame, sourceId: point.id, xPx: point.x, yPx: point.y, xUm: point.x / options.pxPerUm, yUm: point.y / options.pxPerUm });
  let nextTrackId = 1;
  const allTracks: MutableTrack[] = frames[0].points.map((point) => ({ trackId: nextTrackId++, points: [toTrackPoint(frames[0].frame, point)] }));
  let active = [...allTracks];
  for (let frameIndex = 1; frameIndex < frames.length; frameIndex += 1) {
    const frame = frames[frameIndex];
    const detections = frame.points;
    const realColumns = detections.length;
    const dummyCost = options.maxDisplacementUm + Number.EPSILON;
    const invalidCost = dummyCost * 1_000_000;
    const cost = active.map((track) => {
      const previous = track.points.at(-1)!;
      const real = detections.map((point) => {
        const distance = Math.hypot(previous.xPx - point.x, previous.yPx - point.y) / options.pxPerUm;
        return distance <= options.maxDisplacementUm ? distance : invalidCost;
      });
      return [...real, ...new Array(active.length).fill(dummyCost)];
    });
    const assignment = hungarian(cost);
    const usedDetections = new Set<number>();
    const continuing: MutableTrack[] = [];
    assignment.forEach((column, row) => {
      if (column >= 0 && column < realColumns && cost[row][column] < dummyCost) {
        active[row].points.push(toTrackPoint(frame.frame, detections[column]));
        usedDetections.add(column);
        continuing.push(active[row]);
      }
    });
    detections.forEach((point, index) => {
      if (usedDetections.has(index)) return;
      const created = { trackId: nextTrackId++, points: [toTrackPoint(frame.frame, point)] };
      allTracks.push(created); continuing.push(created);
    });
    active = continuing;
  }
  const tracks: CellTrack[] = allTracks.map(({ trackId, points }) => {
    let totalPathLengthUm = 0;
    for (let index = 1; index < points.length; index += 1) totalPathLengthUm += Math.hypot(points[index].xUm - points[index - 1].xUm, points[index].yUm - points[index - 1].yUm);
    const first = points[0]; const last = points.at(-1)!;
    const durationFrames = last.frame - first.frame;
    const durationMin = durationFrames * options.frameIntervalMin;
    const netDisplacementUm = Math.hypot(last.xUm - first.xUm, last.yUm - first.yUm);
    return {
      trackId, startFrame: first.frame, endFrame: last.frame, durationFrames, durationMin,
      totalPathLengthUm, netDisplacementUm,
      meanSpeedUmPerMin: durationMin > 0 ? totalPathLengthUm / durationMin : 0,
      directionalityRatio: totalPathLengthUm > 0 ? netDisplacementUm / totalPathLengthUm : 0,
      points,
    };
  }).sort((a, b) => a.trackId - b.trackId);
  const moving = tracks.filter(({ durationFrames }) => durationFrames >= 1);
  return {
    frameCount: frames.length,
    tracks,
    summary: {
      trackCount: tracks.length,
      tracksWithMotion: moving.length,
      meanSpeedUmPerMin: mean(moving.map(({ meanSpeedUmPerMin }) => meanSpeedUmPerMin)) ?? 0,
      meanDirectionalityRatio: mean(moving.map(({ directionalityRatio }) => directionalityRatio)) ?? 0,
      meanTrackDurationMin: mean(moving.map(({ durationMin }) => durationMin)) ?? 0,
    },
    parameters: options,
  };
}
