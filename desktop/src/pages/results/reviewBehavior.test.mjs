import assert from 'node:assert/strict';
import { measurementPoints, pointRange, scatterSample, selectMeasurementPage, selectMeasurementRange, compareMasks, blocksImageWrites } from './reviewMath.ts';
import { appendMaskVersion, readMaskVersions, knownSavedRun, replaceMasksWithProvenance, MAX_VARIANT_BYTES } from './maskVersions.ts';

let scenarios = 0;
async function check(name, body) { await body(); scenarios++; console.log(`PASS ${name}`); }
const cell = (id, overrides = {}) => ({ id, cx: 10, cy: 20, diameterPx: 20, diameterUm: 10, confidence: .9, ...overrides });
const params = { modelId: 'cp-cyto3', pxPerUm: 2, confidenceThreshold: .5, channels: [0, 0], backgroundSubtract: false, rollingBallRadius: 50, watershedSplit: false, watershedMinDistanceUm: 8, smallThresholdUm: 20, largeThresholdUm: 30, expectedDiameterUm: 0, useGpu: false };
const run = { version: 1, detectionId: 'old-detection', runToken: 'original-token', params, task: 'countCells', calibrationSource: 'manual', ranAt: '2026-09-08T12:00:00Z' };
const savedVersion = { id: 'version-1', label: 'Original', savedAt: run.ranAt, detectorId: 'cellpose/cp-cyto3', cells: [cell('old-mask')], run, reviewPxPerUm: 3 };
const empty = { version: 1, imageId: 'image-1', versions: [] };
const many = Array.from({ length: 12001 }, (_, i) => cell(`cell-${i}`, { diameterUm: i, areaUm2: i * 10 }));

await check('50-row paging reaches every cell, including the final partial page', () => {
  const visited = [];
  for (let page = 0; page < Math.ceil(many.length / 50); page++) {
    const rows = selectMeasurementPage(many, page);
    assert.ok(rows.length <= 50); visited.push(...rows.map(cell => cell.id));
  }
  assert.deepEqual(visited, many.map(cell => cell.id));
  assert.equal(selectMeasurementPage(many, 9999)[0].id, 'cell-12000');
  assert.equal(selectMeasurementPage(many, -1)[0].id, 'cell-0');
  assert.deepEqual(selectMeasurementPage([], 0), []);
});
await check('scatter skips unknown measurements without treating them as zero', () => {
  const values = measurementPoints([cell('unknown'), cell('zero', { meanIntensity: 0 }), cell('invalid', { meanIntensity: NaN })], 'meanIntensity', 'confidence');
  assert.deepEqual(values, [{ id: 'zero', x: 0, y: .9 }]);
  assert.deepEqual(pointRange([], 'x'), [0, 1]);
  const range = pointRange(values, 'x'); assert.ok(range[0] < 0 && range[1] > 0);
});
await check('brush selects all measured cells outside the rendered sample in either drag direction', () => {
  const points = measurementPoints(many, 'diameterUm', 'confidence');
  const sample = scatterSample(points, new Set());
  assert.ok(sample.length <= 2500);
  const omitted = points.find(point => !sample.some(sample => sample.id === point.id));
  assert.ok(omitted);
  assert.deepEqual([...selectMeasurementRange(points, [omitted.x + .1, omitted.x - .1], [1, 0])], [omitted.id]);
  assert.equal(selectMeasurementRange(points, [12000, 0], [1, 0]).size, many.length);
  assert.ok(scatterSample(points, new Set([omitted.id])).some(point => point.id === omitted.id));
  assert.ok(scatterSample(points, new Set(many.map(cell => cell.id))).length <= 2500);
});
await check('comparison detects resize, addition and deletion independently of calibration', () => {
  const result = compareMasks([cell('kept'), cell('resized'), cell('deleted', { cx: 70 })], [cell('kept', { diameterUm: 999 }), cell('resized', { diameterPx: 25 }), cell('new', { cx: 80 })]);
  assert.equal(result.unchanged, 1); assert.equal(result.changed, 1);
  assert.deepEqual([...result.savedChanged], ['resized']); assert.deepEqual([...result.currentChanged], ['resized']);
  assert.deepEqual([...result.removed], ['deleted']); assert.deepEqual([...result.added], ['new']);
});
await check('comparison matches regenerated IDs with rotated/reversed contours one to one', () => {
  const contour = [[0, 0], [10, 0], [10, 10], [0, 10]];
  const result = compareMasks([cell('a', { contourPx: contour }), cell('b', { contourPx: contour })], [cell('new', { contourPx: [[10, 10], [10, 0], [0, 0], [0, 10], [10, 10]] })]);
  assert.equal(result.unchanged, 1); assert.equal(result.removed.size, 1); assert.equal(result.added.size, 0);
});
await check('saving preserves original document and refuses to silently evict the ninth version', () => {
  const full = { ...empty, versions: Array.from({ length: 8 }, (_, i) => ({ ...savedVersion, id: `v${i}` })) };
  const before = JSON.stringify(full);
  assert.throws(() => appendMaskVersion(full, savedVersion), /Remove a saved version/);
  assert.equal(JSON.stringify(full), before);
  const next = appendMaskVersion(empty, savedVersion);
  assert.equal(empty.versions.length, 0); assert.equal(next.versions.length, 1);
});
await check('UTF-8 byte cap rejects oversized versions and preserves saved data', () => {
  const oversized = { ...savedVersion, label: 'µ'.repeat(MAX_VARIANT_BYTES / 2) };
  assert.throws(() => appendMaskVersion(empty, oversized), /16 MiB/);
  assert.equal(empty.versions.length, 0);
});
await check('missing, mismatched or incomplete run provenance stays unknown', () => {
  assert.equal(knownSavedRun(null, { id: run.detectionId }), null);
  assert.equal(knownSavedRun(run, { id: 'different' }), null);
  for (const bad of [{ ...run, runToken: '' }, { ...run, params: undefined }, { ...run, params: { ...params, pxPerUm: 0 } }, { ...run, ranAt: 'bad-date' }, { ...run, task: 'future-task' }]) {
    assert.equal(knownSavedRun(bad, { id: run.detectionId }), null);
  }
  assert.equal(knownSavedRun(run, { id: run.detectionId }), run);
  assert.equal(readMaskVersions({ ...empty, versions: [{ ...savedVersion, run: { ...run, params: {} } }] }, empty.imageId).versions[0].run, null);
});
await check('unreadable saved versions fail closed instead of resetting the document', () => {
  for (const bad of [{ ...empty, version: 2 }, { ...empty, imageId: 'different' }, { ...empty, versions: [null] }, { ...empty, versions: [{ ...savedVersion, cells: [cell('a', { contourPx: [[NaN, 1]] })] }] }]) {
    assert.throws(() => readMaskVersions(bad, empty.imageId), /left unchanged/);
  }
  assert.deepEqual(readMaskVersions(null, empty.imageId), empty);
});
await check('active image writes are blocked while completed and unrelated images remain reviewable', () => {
  const jobs = [{ status: 'running', items: [{ imageId: 'running', status: 'running' }, { imageId: 'next', status: 'pending' }, { imageId: 'done', status: 'completed' }] }];
  assert.equal(blocksImageWrites('running', true, jobs), true);
  assert.equal(blocksImageWrites('next', true, jobs), true);
  assert.equal(blocksImageWrites('done', true, jobs), false);
  assert.equal(blocksImageWrites('unrelated', true, jobs), false);
  assert.equal(blocksImageWrites('running', false, jobs), false);
  assert.equal(blocksImageWrites(undefined, true, jobs), false);
});

function restorePorts(options = {}) {
  const calls = []; let checks = 0; let recorded;
  return { calls, get recorded() { return recorded; }, ports: {
    assertWritable() { calls.push('guard'); if (options.blockAt === ++checks) throw new Error('processing'); },
    async deleteRun() { calls.push('delete-run'); if (options.failDelete) throw new Error('delete failed'); },
    async saveDetection(detectorId, cells) { calls.push('save-masks'); assert.equal(detectorId, savedVersion.detectorId); assert.deepEqual(cells, savedVersion.cells); if (options.failMasks) throw new Error('masks failed'); return { id: 'old-detection' }; },
    async saveRun(value) { calls.push('save-run'); if (options.failRun) throw new Error('metadata failed'); recorded = value; },
    async refresh() { calls.push('refresh'); },
    newToken() { return 'new-token'; },
  } };
}
await check('restore clears previous provenance before masks and mints a new token even when SQLite reuses the ID', async () => {
  const mock = restorePorts(); await replaceMasksWithProvenance(savedVersion, mock.ports);
  assert.deepEqual(mock.calls, ['guard', 'delete-run', 'guard', 'save-masks', 'save-run', 'refresh']);
  assert.equal(mock.recorded.runToken, 'new-token'); assert.equal(mock.recorded.detectionId, run.detectionId);
  assert.deepEqual(mock.recorded.params, run.params); assert.equal(mock.recorded.ranAt, run.ranAt);
  assert.equal(run.runToken, 'original-token');
});
await check('importing masks without provenance does not attach the prior analysis settings', async () => {
  const mock = restorePorts(); await replaceMasksWithProvenance({ ...savedVersion, run: null }, mock.ports);
  assert.deepEqual(mock.calls, ['guard', 'delete-run', 'guard', 'save-masks', 'refresh']); assert.equal(mock.recorded, undefined);
});
await check('failed metadata clearing prevents mask overwrite entirely', async () => {
  const mock = restorePorts({ failDelete: true });
  await assert.rejects(replaceMasksWithProvenance(savedVersion, mock.ports), /delete failed/);
  assert.deepEqual(mock.calls, ['guard', 'delete-run']);
});
await check('partial metadata failure refreshes replaced masks so old editor cells cannot silently overwrite them', async () => {
  const mock = restorePorts({ failRun: true });
  await assert.rejects(replaceMasksWithProvenance(savedVersion, mock.ports), /metadata failed/);
  assert.equal(mock.calls.at(-1), 'refresh'); assert.equal(mock.recorded, undefined);
});
await check('failed mask replacement does not write saved-run metadata and still refreshes', async () => {
  const mock = restorePorts({ failMasks: true });
  await assert.rejects(replaceMasksWithProvenance(savedVersion, mock.ports), /masks failed/);
  assert.ok(!mock.calls.includes('save-run')); assert.equal(mock.calls.at(-1), 'refresh');
});
await check('processing guard is rechecked after awaited metadata clearing', async () => {
  const mock = restorePorts({ blockAt: 2 });
  await assert.rejects(replaceMasksWithProvenance(savedVersion, mock.ports), /processing/);
  assert.deepEqual(mock.calls, ['guard', 'delete-run', 'guard', 'refresh']);
  const initiallyBusy = restorePorts({ blockAt: 1 });
  await assert.rejects(replaceMasksWithProvenance(savedVersion, initiallyBusy.ports), /processing/);
  assert.deepEqual(initiallyBusy.calls, ['guard']);
});
console.log(`RESULTS_BEHAVIOR_VERIFIED (${scenarios} scenarios)`);
