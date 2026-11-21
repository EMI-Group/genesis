// Run with: node --test apps/evo_dash/assets/js/hooks/motion_panel_dom.test.cjs
//
// Exercises the DOM half of the shared `motion-panel` / `data-motion-state`
// recipe through a small fake panel: the writer that turns the server-owned
// `data-motion-want` intent into the hook-owned `data-motion-state` plus
// `hidden`, the ONE armed settle per element, the bounded fallback and the
// stale guard that keeps a LiveView patch from snapping a running exit.
// The regression it pins: nothing in the app ever wrote `data-motion-state`, so
// section 4 of motion.css could only ever open — and a mounted panel whose exit
// is cut short (or whose `hidden` is re-applied mid-exit) pops instead of
// fading while its real content is still on screen.
// Matching the workbench_panel_dom.test.cjs convention: the pure block and the
// `// --- MotionPanel DOM writer:` block are sliced out of the shipped modules
// and evaluated in ONE node:vm context, so the real code is what is measured —
// and it imports nothing, so the slice needs no module resolution.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const PURE_SRC = `${__dirname}/motion_panel.js`;
const DOM_SRC = `${__dirname}/motion_panel_dom.js`;
const pureSrc = readFileSync(PURE_SRC, 'utf8');
const domSrc = readFileSync(DOM_SRC, 'utf8');

const pureStart = pureSrc.indexOf('// --- MotionPanel: pure intent/state decisions');
const pureEnd = pureSrc.indexOf('// MotionPanel hook:');
assert.ok(pureStart !== -1 && pureEnd > pureStart,
  'pure panel state block not found in motion_panel.js');
const domStart = domSrc.indexOf('// --- MotionPanel DOM writer:');
const domEnd = domSrc.indexOf('// end MotionPanel DOM writer');
assert.ok(domStart !== -1 && domEnd > domStart,
  'MotionPanel DOM writer block not found in motion_panel_dom.js');

const source = `${pureSrc.slice(pureStart, pureEnd)}
${domSrc.slice(domStart, domEnd)}
({createPanelWriter, PANEL_SETTLE_FALLBACK_MS});`;

// The bare context has no timers: capture the callback + delay so the tests can
// assert what is armed and fire it themselves.
function harness() {
  const timers = new Map();
  let nextTimer = 0;
  const context = vm.createContext({
    setTimeout(fn, delay) {
      const id = ++nextTimer;
      timers.set(id, {fn, delay});
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
  });
  return {api: vm.runInContext(source, context), timers};
}

function fakeRoot({want = null, hidden = true, state = null} = {}) {
  const attrs = new Map();
  if (want !== null) attrs.set('data-motion-want', want);
  if (state !== null) attrs.set('data-motion-state', state);
  const listeners = new Map();
  const root = {
    hidden,
    getAttribute(name) {
      return attrs.has(name) ? attrs.get(name) : null;
    },
    setAttribute(name, value) {
      attrs.set(name, String(value));
    },
    removeAttribute(name) {
      attrs.delete(name);
    },
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(fn);
    },
    removeEventListener(type, fn) {
      listeners.get(type)?.delete(fn);
    },
  };
  const dispatch = event => {
    for (const fn of [...(listeners.get('animationend') || [])]) fn(event);
  };
  const armed = () => (listeners.get('animationend')?.size || 0) > 0;
  return {
    root,
    attrs,
    dispatch,
    armed,
    state: () => attrs.get('data-motion-state'),
    want: value => {
      if (value === null) attrs.delete('data-motion-want');
      else attrs.set('data-motion-want', value);
    },
  };
}

test('an open intent enters, then settles to open on its own animationend', () => {
  const {api, timers} = harness();
  const writer = api.createPanelWriter(() => false);
  const panel = fakeRoot({want: 'true'});

  writer.apply(panel.root);

  assert.equal(panel.state(), 'opening', 'the entry keyframes are the entrance');
  assert.equal(panel.root.hidden, false);
  assert.equal(panel.armed(), true);
  assert.equal(timers.size, 1, 'exactly one bounded settle');
  const [timerId, pending] = [...timers.entries()][0];
  assert.ok(pending.delay > 0 && pending.delay <= api.PANEL_SETTLE_FALLBACK_MS,
    `bounded fallback expected, got ${pending.delay}`);

  // A child's animationend bubbles through the panel and must not settle it.
  panel.dispatch({target: {}, animationName: 'spin'});
  assert.equal(panel.state(), 'opening');

  panel.dispatch({target: panel.root, animationName: 'motion-fade-in'});
  assert.equal(panel.state(), 'open');
  assert.equal(panel.root.hidden, false);
  assert.equal(panel.armed(), false, 'the armed listener is released');
  assert.equal(timers.size, 0, 'the fallback is cleared');

  // A duplicated event and the captured fallback callback are both inert.
  panel.dispatch({target: panel.root, animationName: 'motion-fade-in'});
  pending.fn();
  assert.equal(panel.state(), 'open');
  assert.equal(panel.root.hidden, false);
  assert.ok(!timers.has(timerId));
  writer.destroy();
});

test('a close intent keeps the panel displayed for the exit, then hides it', () => {
  const {api, timers} = harness();
  const writer = api.createPanelWriter(() => false);
  const panel = fakeRoot({want: 'true'});

  writer.apply(panel.root);
  panel.dispatch({target: panel.root});
  assert.equal(panel.state(), 'open');

  panel.want('false');
  writer.apply(panel.root);

  assert.equal(panel.state(), 'closing');
  assert.equal(panel.root.hidden, false, 'the exit needs the real content on screen');
  assert.equal(panel.armed(), true);
  assert.equal(timers.size, 1);

  panel.dispatch({target: panel.root, animationName: 'motion-fade-out'});

  assert.equal(panel.state(), 'closed');
  assert.equal(panel.root.hidden, true, 'hidden is written only once the exit settled');
  assert.equal(panel.armed(), false);
  assert.equal(timers.size, 0);
  writer.destroy();
});

test('a repeated apply while closing keeps ONE close and repairs patched markup', () => {
  const {api, timers} = harness();
  const writer = api.createPanelWriter(() => false);
  const panel = fakeRoot({want: 'true'});

  writer.apply(panel.root);
  panel.dispatch({target: panel.root});
  panel.want('false');
  writer.apply(panel.root);
  assert.equal(timers.size, 1);
  const [timerId] = [...timers.entries()][0];

  // A LiveView patch puts the server markup back mid-exit: `hidden` from the
  // intent and our state attribute stripped. The hook's own state wins, and the
  // re-assert fixes the element in this same task so nothing collapsed paints.
  panel.root.hidden = true;
  panel.attrs.delete('data-motion-state');
  writer.apply(panel.root);

  assert.equal(panel.state(), 'closing');
  assert.equal(panel.root.hidden, false, 'the patch never snaps the panel shut');
  assert.equal(timers.size, 1, 'no second close is armed');
  assert.ok(timers.has(timerId), 'the original settle is the one that stays armed');
  writer.destroy();
});

test('a re-entrant open while closing cancels the armed close', () => {
  const {api, timers} = harness();
  const writer = api.createPanelWriter(() => false);
  const panel = fakeRoot({want: 'true'});

  writer.apply(panel.root);
  panel.dispatch({target: panel.root});
  panel.want('false');
  writer.apply(panel.root);
  assert.equal(panel.state(), 'closing');
  const [timerId, pending] = [...timers.entries()][0];

  panel.want('true');
  writer.apply(panel.root);

  assert.equal(panel.state(), 'open', 'it continues from its live interpolated frame');
  assert.equal(panel.root.hidden, false);
  assert.equal(panel.armed(), false, 'the stale animationend listener is gone');
  assert.equal(timers.size, 0, 'the stale fallback timer is cleared');
  // Neither the removed listener nor the cleared timer can hide the panel.
  panel.dispatch({target: panel.root});
  pending.fn();
  assert.equal(panel.state(), 'open');
  assert.equal(panel.root.hidden, false);
  assert.ok(!timers.has(timerId));
  writer.destroy();
});

test('an unchanged state is a pure re-assert and never re-animates', () => {
  const {api, timers} = harness();
  const writer = api.createPanelWriter(() => false);
  const panel = fakeRoot({want: 'true'});

  writer.apply(panel.root);
  panel.dispatch({target: panel.root});

  panel.root.hidden = true;
  panel.attrs.delete('data-motion-state');
  writer.apply(panel.root);

  assert.equal(panel.state(), 'open');
  assert.equal(panel.root.hidden, false, 'the same task repairs hidden');
  assert.equal(timers.size, 0, 'a stable open never re-arms a settle');
  writer.destroy();
});

test('a missing intent leaves the panel exactly where it is', () => {
  const {api, timers} = harness();
  const writer = api.createPanelWriter(() => false);
  const panel = fakeRoot({want: 'true'});

  writer.apply(panel.root);
  panel.dispatch({target: panel.root});

  // A patch that strips the intent is a no-op, never an implicit close.
  panel.want(null);
  writer.apply(panel.root);

  assert.equal(panel.state(), 'open');
  assert.equal(panel.root.hidden, false);
  assert.equal(timers.size, 0);
  writer.destroy();
});

test('reduced motion settles in the same task, with no listener and no timer', () => {
  for (const [want, expected] of [['true', ['open', false]], ['false', ['closed', true]]]) {
    const {api, timers} = harness();
    const writer = api.createPanelWriter(() => true);
    const panel = fakeRoot({want: want === 'true' ? 'false' : 'true'});

    writer.apply(panel.root); // mount in the opposite state first
    panel.want(want);
    writer.apply(panel.root);

    assert.equal(panel.state(), expected[0], `want=${want}`);
    assert.equal(panel.root.hidden, expected[1], `want=${want}`);
    assert.equal(panel.armed(), false, 'there is no animation to wait for');
    assert.equal(timers.size, 0);
    writer.destroy();
  }
});

test('the bounded fallback settles a panel whose animation never fires', () => {
  const {api, timers} = harness();
  const writer = api.createPanelWriter(() => false);
  const panel = fakeRoot({want: 'true'});

  writer.apply(panel.root);
  assert.equal(panel.state(), 'opening');
  const [timerId, pending] = [...timers.entries()][0];

  // No animationend ever arrives (hidden tab, suppressed animations).
  pending.fn();

  assert.equal(panel.state(), 'open');
  assert.equal(panel.root.hidden, false);
  assert.equal(panel.armed(), false);
  assert.ok(!timers.has(timerId), 'the fired timer releases itself');
  writer.destroy();
});

test('destroy releases every armed settle and the module schedules no frame', () => {
  const {api, timers} = harness();
  const writer = api.createPanelWriter(() => false);
  const first = fakeRoot({want: 'true'});
  const second = fakeRoot({want: 'true'});

  writer.apply(first.root);
  writer.apply(second.root);
  assert.equal(first.armed(), true);
  assert.equal(second.armed(), true);
  assert.equal(timers.size, 2);

  writer.destroy();

  assert.equal(timers.size, 0, 'no fallback timer may outlive the hook');
  assert.equal(first.armed(), false);
  assert.equal(second.armed(), false);
  assert.equal(/requestAnimationFrame/.test(domSrc), false,
    'a CSS animation needs no frame schedule');
});

test('the writer never imports, so the vm slice stays module-free', () => {
  const block = domSrc.slice(domStart, domEnd);
  assert.equal(/\bimport\s/.test(block), false);
  assert.equal(/\brequire\(/.test(block), false);
  // The ONLY duration in the DOM half is the shared bounded fallback.
  assert.equal(/\b\d+(\.\d+)?m?s\b/.test(block), false);
});
