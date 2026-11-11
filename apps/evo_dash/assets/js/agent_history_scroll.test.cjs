// Run with: node --test apps/evo_dash/assets/js/agent_history_scroll.test.cjs
//
// Exercises the PURE pinning decision of the AgentHistoryAutoScroll hook — the
// "should the transcript follow new content?" question — without a browser
// bundle, matching the state_persistence.test.cjs convention (Node's built-in
// test runner + vm over the hook source sliced out of app.js). The DOM half of
// the hook (rAF coalescing, ResizeObserver, listeners) is deliberately not
// faked here: it has no decision of its own.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const app = readFileSync(`${__dirname}/app.js`, 'utf8');
const start = app.indexOf('// --- AgentHistoryAutoScroll: pure pinning decision');
const end = app.indexOf('// AgentHistoryAutoScroll hook:');
assert.ok(start !== -1 && end > start, 'pure pinning decision block not found in app.js');
const source = app.slice(start, end);
const context = vm.createContext({});
const {shouldFollowLatest, STICK_TO_BOTTOM_THRESHOLD_PX} =
  vm.runInContext(`${source}\n({shouldFollowLatest, STICK_TO_BOTTOM_THRESHOLD_PX});`, context);
// Geometry: content 2000px tall inside a 600px viewport → max scrollTop 1400.
const VIEW = 600;
const CONTENT = 2000;
const MAX_TOP = CONTENT - VIEW;
test('pinned exactly at the bottom', () => {
  assert.equal(shouldFollowLatest(MAX_TOP, CONTENT, VIEW), true);
});
test('pinned inside the generous slack (a reader at the bottom is never dropped)', () => {
  assert.equal(shouldFollowLatest(MAX_TOP - 1, CONTENT, VIEW), true);
  assert.equal(shouldFollowLatest(MAX_TOP - 40, CONTENT, VIEW), true);
});
test('threshold boundary is inclusive, one pixel more unpins', () => {
  const threshold = STICK_TO_BOTTOM_THRESHOLD_PX;
  assert.equal(shouldFollowLatest(MAX_TOP - threshold, CONTENT, VIEW), true);
  assert.equal(shouldFollowLatest(MAX_TOP - threshold - 1, CONTENT, VIEW), false);
});
test('a deliberate scroll into history stays put', () => {
  assert.equal(shouldFollowLatest(0, CONTENT, VIEW), false);
  assert.equal(shouldFollowLatest(MAX_TOP / 2, CONTENT, VIEW), false);
});
test('content that fits needs no scrolling and always follows', () => {
  assert.equal(shouldFollowLatest(0, 400, VIEW), true);
  assert.equal(shouldFollowLatest(0, VIEW, VIEW), true);
});
test('overscroll past the bottom counts as at the bottom, rubber-banding above the top does not', () => {
  // Overscrolling down (transiently larger than max) is still "at the latest".
  assert.equal(shouldFollowLatest(MAX_TOP + 20, CONTENT, VIEW), true);
  // A rubber-band bounce above the top is deep in history — stay unpinned.
  assert.equal(shouldFollowLatest(-20, CONTENT, VIEW), false);
});
test('unmeasurable geometry keeps following (never lose a pin to a hidden panel)', () => {
  assert.equal(shouldFollowLatest(NaN, CONTENT, VIEW), true);
  assert.equal(shouldFollowLatest(MAX_TOP, undefined, VIEW), true);
  assert.equal(shouldFollowLatest(MAX_TOP, CONTENT, NaN), true);
});
test('an explicit threshold overrides the default', () => {
  assert.equal(shouldFollowLatest(MAX_TOP - 100, CONTENT, VIEW, 120), true);
  assert.equal(shouldFollowLatest(MAX_TOP - 100, CONTENT, VIEW, 20), false);
  // A non-numeric threshold falls back to the module default.
  assert.equal(shouldFollowLatest(MAX_TOP - 40, CONTENT, VIEW, undefined), true);
});
test('default threshold sits in the documented 48-64 px band', () => {
  assert.ok(STICK_TO_BOTTOM_THRESHOLD_PX >= 48 && STICK_TO_BOTTOM_THRESHOLD_PX <= 64);
});
