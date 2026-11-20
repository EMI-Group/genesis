// Run with: node --test apps/evo_dash/assets/js/hooks/adaptive_input.test.cjs
//
// Pins the ONE deferred-apply frame of the AdaptiveInput hook: a broadcast
// burst (several LiveView patches in consecutive frames, each calling
// updated()) must coalesce onto a single pending measure + layout pass for the
// SAME element, and a teardown must cancel that frame instead of running the
// pass against a detached textarea.
//
// Matching the workbench_panel.test.cjs / disclosure_motion.test.cjs
// convention: the shipped `AdaptiveInput` object is sliced out of the source
// and run through node:vm against small seams (rAF, MutationObserver,
// getComputedStyle), so no browser bundle or DOM library is loaded.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const src = readFileSync(`${__dirname}/adaptive_input.js`, 'utf8');
const start = src.indexOf('const AdaptiveInput = {');
const end = src.indexOf('export default AdaptiveInput;');
assert.ok(start !== -1 && end > start, 'AdaptiveInput object not found in adaptive_input.js');
const hookSource = src.slice(start, end);

// A harness with one textarea, one layout container, collected frames and a
// measurement counter (getComputedStyle runs exactly once per full pass).
function harness() {
  const frames = new Map();
  const cancelled = [];
  let nextId = 1;
  let measures = 0;

  const layoutEl = {dataset: {layout: 'compact'}};
  const listeners = new Map();
  const el = {
    value: '',
    placeholder: '',
    scrollHeight: 120,
    dataset: {},
    style: {},
    addEventListener(name, fn) { listeners.set(name, fn); },
    removeEventListener(name, fn) { if (listeners.get(name) === fn) listeners.delete(name); },
    closest(selector) { return selector === '.input-layout' ? layoutEl : null; }
  };

  const context = vm.createContext({
    requestAnimationFrame(fn) {
      const id = nextId++;
      frames.set(id, fn);
      return id;
    },
    cancelAnimationFrame(id) {
      cancelled.push(id);
      frames.delete(id);
    },
    getComputedStyle() {
      measures += 1;
      return {maxHeight: '320px', lineHeight: '20px'};
    },
    MutationObserver: class {
      observe() {}
      disconnect() { this.disconnected = true; }
    },
    // No visualViewport: the --app-vh listeners stay off (guarded in mounted()).
    window: {},
    document: {documentElement: {style: {setProperty() {}}}}
  });

  const AdaptiveInput = vm.runInContext(`${hookSource}\nAdaptiveInput;`, context);
  const hook = Object.create(AdaptiveInput);
  hook.el = el;
  hook.handleEvent = () => {};

  return {
    hook,
    el,
    listeners,
    frameCount: () => frames.size,
    cancelled,
    measures: () => measures,
    runFrames() {
      const pending = [...frames.values()];
      frames.clear();
      for (const fn of pending) fn();
    }
  };
}

test('a burst of post-patch re-applies coalesces onto ONE pending frame', () => {
  const h = harness();
  h.hook.mounted(); // cold-mount deferral schedules frame #1
  h.hook.updated();
  h.hook.updated();
  h.hook.updated();

  assert.equal(h.frameCount(), 1, 'only one deferred apply may be queued at a time');
  assert.equal(h.measures(), 0, 'nothing is measured synchronously');

  h.runFrames();
  assert.equal(h.measures(), 1, 'the coalesced frame runs exactly one measure + layout pass');
  assert.equal(h.frameCount(), 0, 'the pending-frame guard is released when the frame runs');
});

test('a later patch schedules a fresh frame once the previous one ran', () => {
  const h = harness();
  h.hook.mounted();
  h.runFrames();
  assert.equal(h.measures(), 1);

  h.hook.updated();
  assert.equal(h.frameCount(), 1);
  h.hook.updated();
  assert.equal(h.frameCount(), 1);
  h.runFrames();
  assert.equal(h.measures(), 2);
});

test('user input still applies synchronously, never through the frame', () => {
  const h = harness();
  h.hook.mounted();
  h.runFrames();
  const before = h.measures();

  h.el.value = 'hello';
  h.listeners.get('input')();

  assert.equal(h.measures(), before + 1, 'the input handler measures immediately');
  assert.equal(h.frameCount(), 0, 'no frame is queued by typing');
});

test('destroyed() cancels the pending frame, then disconnects the observers', () => {
  const h = harness();
  h.hook.mounted();
  h.hook.updated();
  assert.equal(h.frameCount(), 1);

  h.hook.destroyed();

  assert.equal(h.frameCount(), 0, 'the pending frame is cancelled');
  assert.equal(h.cancelled.length, 1);
  assert.equal(h.listeners.size, 0, 'the input listener is removed');
  assert.equal(h.hook._layoutObserver.disconnected, true);
  assert.equal(h.hook._placeholderObserver.disconnected, true);

  h.runFrames();
  assert.equal(h.measures(), 0, 'no measurement runs after teardown');
});
