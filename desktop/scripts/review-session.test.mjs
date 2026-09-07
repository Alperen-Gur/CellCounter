import assert from "node:assert/strict";
import test from "node:test";
import { ReviewSession } from "../src/pages/review/reviewSession.ts";

function fixture(count = 1205) {
  const rows = Array.from({ length: count }, (_, index) => ({
    key: `d:${String(index).padStart(5, "0")}`,
    detectionId: "d", cell: { id: String(index).padStart(5, "0"), confidence: 0.1 },
  }));
  const corrected = new Set();
  const pages = [];
  const writes = [];
  let lastUndo;
  const api = {
    async page(after) {
      pages.push(after);
      const available = rows.filter((item) => !corrected.has(item.key) && (!after || item.cell.id > after.cellId));
      const items = available.slice(0,64);
      const last = items.at(-1);
      return { items, totalPending: count - corrected.size, nextCursor: available.length > 64
        ? { confidence: 0.1, detectionId: "d", cellId: last.cell.id } : null };
    },
    async decide(item, action, diameterUm) {
      writes.push({ key: item.key, action, diameterUm });
      corrected.add(item.key);
      lastUndo = { token: `undo-${writes.length}`, key: item.key };
      return { undoToken: lastUndo.token };
    },
    async undo(token) {
      assert.equal(token,lastUndo?.token);
      corrected.delete(lastUndo.key);
      lastUndo = undefined;
    },
  };
  return { api, rows, pages, writes, corrected };
}
function current(session) { const s = session.getSnapshot(); return s.restored ?? s.items[s.index]; }

test("1205 decisions/skips keep at most one page and reopen only skipped cells", async () => {
  const f = fixture();
  const session = new ReviewSession(f.api);
  await session.start();
  let visited = 0;
  const skipped = [];
  while (current(session)) {
    assert.ok(session.getSnapshot().items.length <= 64);
    if (visited++ % 9 === 0) { skipped.push(current(session).key); await session.skip(); }
    else await session.decide("keep");
  }
  assert.equal(visited,1205);
  assert.equal(session.getSnapshot().visited,1205);
  assert.equal(session.getSnapshot().skipped,skipped.length);
  assert.equal(f.pages.length,19);
  const reopened = new ReviewSession(f.api);
  await reopened.start();
  const actual = [];
  while (current(reopened)) { actual.push(current(reopened).key); await reopened.skip(); }
  assert.deepEqual(actual,skipped);
});

test("failed decision retains its card and retry does not overwrite the next cell", async () => {
  const f = fixture(2);
  let fail = true;
  const session = new ReviewSession({ ...f.api, async decide(...args) {
    if (fail) throw new Error("disk full");
    return f.api.decide(...args);
  } });
  await session.start();
  const key = current(session).key;
  assert.equal(await session.decide("resize",22),false);
  assert.equal(current(session).key,key);
  assert.match(session.getSnapshot().error,/disk full/);
  assert.equal(session.getSnapshot().visited,0);
  fail = false;
  assert.equal(await session.decide("resize",22),true);
  assert.notEqual(current(session).key,key);
  assert.deepEqual(f.writes,[{ key, action: "resize", diameterUm: 22 }]);
});

test("a failed next-page read retries its keyset without reapplying committed decisions", async () => {
  const f = fixture(65);
  let fail = true;
  const session = new ReviewSession({ ...f.api, async page(after) {
    if (after && fail) throw new Error("busy database");
    return f.api.page(after);
  } });
  await session.start();
  for (let i=0;i<64;i++) await session.decide("reject");
  assert.equal(current(session),undefined);
  assert.match(session.getSnapshot().error,/busy database/);
  fail = false;
  await session.retryPage();
  assert.equal(current(session).key,f.rows[64].key);
  assert.equal(f.writes.length,64);
  assert.equal(session.getSnapshot().error,null);
});

test("rapid action/skip inputs serialize while a decision is saving", async () => {
  const f = fixture(2);
  let release;
  const wait = new Promise((resolve) => { release = resolve; });
  const session = new ReviewSession({ ...f.api, async decide(...args) { await wait; return f.api.decide(...args); } });
  await session.start();
  const pending = session.decide("keep");
  assert.equal(await session.decide("reject"),false);
  await session.skip();
  assert.equal(session.getSnapshot().visited,0);
  release();
  await pending;
  assert.equal(session.getSnapshot().visited,1);
  assert.equal(f.writes.length,1);
});

test("discarded loads cannot replace a newer visit; skipping clears a prior write error", async () => {
  const f = fixture(1);
  let release;
  const wait = new Promise((resolve) => { release = resolve; });
  let first = true;
  const session = new ReviewSession({ ...f.api, async page(after) {
    if (first) { first = false; await wait; return { items: [], totalPending: 0, nextCursor: null }; }
    return f.api.page(after);
  }, async decide() { throw new Error("failed"); } });
  const old = session.start();
  session.dispose();
  await session.start();
  release();
  await old;
  assert.equal(current(session).key,f.rows[0].key);
  await session.decide("keep");
  await session.skip();
  assert.equal(session.getSnapshot().error,null);
  assert.equal(session.getSnapshot().skipped,1);
});

test("Undo restores the last decision after a page change without losing the next page", async () => {
  const f = fixture(130);
  const session = new ReviewSession(f.api);
  await session.start();
  for (let i=0;i<63;i++) await session.skip();
  const reviewedKey = current(session).key;
  await session.decide("reject");
  const nextPageKey = current(session).key;
  assert.equal(nextPageKey,f.rows[64].key);
  assert.equal(await session.undo(),true);
  assert.equal(current(session).key,reviewedKey);
  assert.equal(f.corrected.has(reviewedKey),false);
  assert.equal(session.getSnapshot().undo,null);
  await session.skip();
  assert.equal(current(session).key,nextPageKey);
  assert.equal(session.getSnapshot().items.length,64);
});

test("Undo conflict retains newer state and failed-page Undo can resume its pending cursor", async () => {
  const f = fixture(65);
  let failPage = true;
  let conflict = true;
  const session = new ReviewSession({ ...f.api,
    async page(after) { if (after && failPage) throw new Error("busy"); return f.api.page(after); },
    async undo(token) { if (conflict) throw new Error("saved result changed"); await f.api.undo(token); },
  });
  await session.start();
  for (let i=0;i<63;i++) await session.skip();
  await session.decide("resize",22);
  assert.equal(session.getSnapshot().pageError,true);
  assert.equal(await session.undo(),false);
  assert.match(session.getSnapshot().error,/saved result changed/);
  assert.equal(f.corrected.size,1);
  conflict = false;
  assert.equal(await session.undo(),true);
  assert.equal(current(session).key,f.rows[63].key);
  failPage = false;
  await session.skip();
  assert.equal(current(session).key,f.rows[64].key);
  assert.equal(session.getSnapshot().pageError,false);
});
