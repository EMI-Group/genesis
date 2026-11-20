// Run with: node --test apps/evo_dash/assets/js/hooks/workbench_project_preview.test.cjs
//
// Exercises the PURE cache planning of workbench_project_preview.js — "which
// warm handoff windows may stay cached, and what does a hit or an insert do to
// the recency order?" — without a browser bundle. The DOM half (the shadow-DOM
// host, the `#main-content` clone, `release()`) has no decision of its own; it
// only executes the plans pinned here.
//
// Matching the workbench_panel.test.cjs / sidebar_collapse.test.cjs convention:
// the block between the source's markers is sliced out and run through node:vm,
// so the real shipped code is what is measured.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const src = readFileSync(`${__dirname}/workbench_project_preview.js`, 'utf8');
const start = src.indexOf('// --- ProjectPreview: pure cache planning');
const end = src.indexOf('// projectPreview:', start);
assert.ok(start !== -1 && end > start, 'pure cache planning block not found in workbench_project_preview.js');
const source = src.slice(start, end);
const {MAX_WINDOWS, touch, keysToEvict} = vm.runInContext(
  `${source}\n({MAX_WINDOWS, touch, keysToEvict});`,
  vm.createContext({})
);

// A tiny stand-in for the one policy the module applies on insert: write, then
// drop whatever `keysToEvict` names (oldest first). Kept beside the tests so a
// rule change shows up as a failing expectation rather than silently agreeing
// with itself.
function insert(cache, key, entry) {
  cache.set(key, entry);
  return [...keysToEvict(cache, key)];
}

test('the cache bound is a small, named, positive constant', () => {
  assert.equal(typeof MAX_WINDOWS, 'number');
  assert.ok(Number.isInteger(MAX_WINDOWS) && MAX_WINDOWS > 0, `got ${MAX_WINDOWS}`);
  // One entry is the project being left; two tolerates a fast back-and-forth.
  assert.ok(MAX_WINDOWS <= 4, `a handoff cache must stay tiny, got ${MAX_WINDOWS}`);
});

test('a touch on a miss is a no-op', () => {
  const cache = new Map([['a', {key: 'a'}]]);
  assert.equal(touch(cache, 'missing'), undefined);
  assert.deepEqual([...cache.keys()], ['a']);
});

test('a touch on a hit makes that entry the newest', () => {
  const a = {key: 'a'};
  const b = {key: 'b'};
  const c = {key: 'c'};
  const cache = new Map([['a', a], ['b', b], ['c', c]]);
  assert.equal(touch(cache, 'b'), b, 'the stored entry itself is answered');
  // Map insertion order is the recency order: b moved to the end.
  assert.deepEqual([...cache.keys()], ['a', 'c', 'b']);
});

test('a cache at or under the bound evicts nothing', () => {
  const cache = new Map();
  assert.deepEqual([...keysToEvict(cache, 'a')], []);
  cache.set('a', {});
  assert.deepEqual([...keysToEvict(cache, 'a')], []);
});

test('an over-full cache evicts the oldest entries first', () => {
  const cache = new Map([['old', {}], ['mid', {}], ['new', {}]]);
  assert.deepEqual([...keysToEvict(cache, 'new', 2)], ['old']);
  assert.deepEqual([...keysToEvict(cache, 'new', 1)], ['old', 'mid']);
});

test('the entry just inserted is never evicted by its own insert', () => {
  // Even when the Map order still has `keep` first (a stale-order cache), the
  // keep key is skipped — a live handoff is never yanked.
  const cache = new Map([['keep', {}], ['x', {}], ['y', {}]]);
  assert.deepEqual([...keysToEvict(cache, 'keep', 1)], ['x', 'y']);
});

test('repeated inserts keep exactly the newest MAX_WINDOWS entries', () => {
  const cache = new Map();
  const inserted = Array.from({length: MAX_WINDOWS + 3}, (_, i) => `p${i}`);
  const evicted = [];

  for (const key of inserted) {
    evicted.push(...insert(cache, key, {key}));
    // Enforce the policy the module applies: every named key is dropped.
    for (const dropped of keysToEvict(cache, key)) cache.delete(dropped);
    assert.ok(cache.size <= MAX_WINDOWS, `cache grew to ${cache.size}`);
  }

  const expected = inserted.slice(-MAX_WINDOWS);
  assert.deepEqual([...cache.keys()], expected, 'only the newest snapshots survive');
  assert.deepEqual([...new Set(evicted)].sort(), inserted.slice(0, 3).sort(), 'the oldest three were dropped exactly once');
  assert.equal(cache.has('p0'), false, 'the oldest snapshot is gone');
  assert.equal(cache.has(inserted[inserted.length - 1]), true, 'the newest snapshot is kept');
});
