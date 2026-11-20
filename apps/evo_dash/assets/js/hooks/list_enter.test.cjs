// Run with: node --test apps/evo_dash/assets/js/hooks/list_enter.test.cjs
//
// Exercises the PURE insertion planner behind the shared list entry animation —
// "which keys are genuinely NEW in this scope, and may they animate?" — without
// a browser bundle. The DOM half (the coalesced requestAnimationFrame, the
// MutationObserver, the animationend listeners) lives in list_enter.js and has
// no decision of its own; it only executes the plans pinned here.
//
// Matching the workbench_panel.test.cjs / inspector_messages.test.cjs
// convention: the block between the source's markers is sliced out and run
// through node:vm, so the real shipped code is what is measured.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const src = readFileSync(`${__dirname}/list_enter.js`, 'utf8');
const start = src.indexOf('// --- ListEnter: pure insertion planning');
const end = src.indexOf('// ListEnter hook:');
assert.ok(start !== -1 && end > start, 'pure insertion planning block not found in list_enter.js');

const {planListEnter} = vm.runInContext(
  `${src.slice(start, end)}\n({planListEnter});`,
  vm.createContext({}),
);

const plan = (overrides) => planListEnter({scope: 'local|repo', previousScope: 'local|repo', ...overrides});

test('a genuinely new key in an unchanged scope is queued for animation', () => {
  const result = plan({keys: ['a', 'b'], seen: new Set(['a'])});
  assert.deepEqual([...result.animate], ['b']);
  assert.equal(result.changedScope, false);
});

test('an already-seen key never animates again', () => {
  const none = plan({keys: ['a'], seen: new Set(['a'])});
  assert.deepEqual([...none.animate], []);
  assert.equal(none.seen.has('a'), true, 'the key stays remembered');
});

test('the first call is a baseline: nothing animates, keys are seeded', () => {
  const first = planListEnter({scope: 'local|repo', keys: ['a', 'b'], seen: new Set()});
  assert.equal(first.changedScope, true, 'previousScope undefined is a scope change');
  assert.deepEqual([...first.animate], []);
  assert.deepEqual([...first.seen], ['a', 'b']);

  // The next insert in the SAME scope is a real insertion.
  const later = plan({keys: ['a', 'b', 'c'], seen: first.seen});
  assert.deepEqual([...later.animate], ['c']);
});

test('a scope change re-seeds the baseline and carries nothing over', () => {
  const switched = plan({
    scope: 'local|other',
    previousScope: 'local|repo',
    keys: ['a', 'b'],
    seen: new Set(['a', 'b', 'stale']),
  });
  assert.equal(switched.changedScope, true);
  assert.deepEqual([...switched.animate], [], 'a new scope must not animate its whole list');
  assert.equal(switched.seen.has('stale'), false, "the old scope's keys are not carried over");
  assert.deepEqual([...switched.seen], ['a', 'b'], 'the current rows become the new baseline');

  // A later insertion in the NEW scope does animate.
  const later = plan({
    scope: 'local|other',
    previousScope: 'local|other',
    keys: ['a', 'b', 'z'],
    seen: switched.seen,
  });
  assert.deepEqual([...later.animate], ['z']);
});

test('reduced motion seeds keys into the baseline but queues no animation', () => {
  const reduced = plan({keys: ['a', 'b'], seen: new Set(['a']), reducedMotion: true});
  assert.deepEqual([...reduced.animate], []);
  assert.deepEqual([...reduced.seen], ['a', 'b'], 'keys are still remembered');

  // The same insertion without reduced motion would have animated.
  assert.deepEqual([...plan({keys: ['a', 'b'], seen: new Set(['a'])}).animate], ['b']);
});

test('an unscoped wrapper is inert: no animation, keys still booked', () => {
  const inert = planListEnter({scope: '', previousScope: '', keys: ['a'], seen: new Set(), reducedMotion: false});
  assert.equal(inert.changedScope, false);
  assert.deepEqual([...inert.animate], []);
  assert.equal(inert.seen.has('a'), true);
});

test('empty, duplicate and non-string keys are ignored', () => {
  const result = plan({keys: ['', 'a', 'a', null, undefined, 7, {}, 'b'], seen: new Set()});
  assert.deepEqual([...result.animate], ['a', 'b'], 'first occurrence wins, in input order');
  assert.deepEqual([...result.seen].sort(), ['a', 'b']);
});

test('the input seen Set is never mutated and the result is a new Set', () => {
  const seen = new Set(['a']);
  const result = plan({keys: ['a', 'b'], seen});
  assert.deepEqual([...seen], ['a'], 'the caller-owned baseline is untouched');
  assert.notEqual(result.seen, seen);
  assert.deepEqual([...result.seen].sort(), ['a', 'b']);
});

test('missing or malformed input returns an empty, safe plan', () => {
  for (const bad of [undefined, null, {}, {keys: null}, {keys: 'a,b'}, {keys: {0: 'a'}}]) {
    const result = planListEnter(bad);
    assert.deepEqual([...result.animate], [], `${JSON.stringify(bad)} must not animate`);
    // A cross-realm Set (the plan is built inside the vm context).
    assert.equal(typeof result.seen.has, 'function');
    assert.equal(result.seen.size, 0);
    assert.equal(typeof result.changedScope, 'boolean');
  }
});
