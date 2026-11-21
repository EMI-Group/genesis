// Run with: node --test apps/evo_dash/assets/js/hooks/workbench_panel_dom.test.cjs
//
// Exercises the DOM half of the right-panel workbench asides through a small fake
// panel: the start-frame flush an OPEN needs after the aside is un-hidden, the
// armed close (its transitionend filter and bounded fallback) and the
// destroy/re-assert bookkeeping.
// The regression it pins: the panel arrives from the server `display: none`, so a
// state flip applied without a forced style+layout pass at the collapsed
// geometry is the element's FIRST style ever — CSS starts no transition from no
// previous style and the panel pops in. A single deferred frame is not enough.
// Matching the workbench_panel.test.cjs convention: the pure block and the
// `// --- WorkbenchPanel DOM host:` block are sliced out of the shipped modules
// and evaluated in ONE node:vm context, so the real code is what is measured.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const PANEL_SRC = `${__dirname}/workbench_panel.js`;
const DOM_SRC = `${__dirname}/workbench_panel_dom.js`;
const panelSrc = readFileSync(PANEL_SRC, 'utf8');
const domSrc = readFileSync(DOM_SRC, 'utf8');

const pureStart = panelSrc.indexOf('// --- WorkbenchPanel: pure right-panel state machine');
const pureEnd = panelSrc.indexOf('// WorkbenchPanel hook:');
assert.ok(pureStart !== -1 && pureEnd > pureStart,
  'pure panel state machine block not found in workbench_panel.js');
const domStart = domSrc.indexOf('// --- WorkbenchPanel DOM host:');
const domEnd = domSrc.indexOf('// end WorkbenchPanel DOM host');
assert.ok(domStart !== -1 && domEnd > domStart,
  'WorkbenchPanel DOM host block not found in workbench_panel_dom.js');

const source = `${panelSrc.slice(pureStart, pureEnd)}
${domSrc.slice(domStart, domEnd)}
({createPanelHost, settleDisplayedLayout, PANEL_CLOSE_FALLBACK_MS});`;

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

function fakePanel({id = 'workbench-history', state = 'closed', hidden = true} = {}) {
  const listeners = new Map();
  const record = {flushes: 0, flushStates: []};
  const panel = {
    id,
    hidden,
    dataset: {panelState: state},
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(fn);
    },
    removeEventListener(type, fn) {
      listeners.get(type)?.delete(fn);
    },
    get offsetWidth() {
      record.flushes += 1;
      record.flushStates.push(panel.dataset.panelState);
      return 800;
    },
  };
  const dispatch = event => {
    for (const fn of [...(listeners.get('transitionend') || [])]) fn(event);
  };
  const armed = () => (listeners.get('transitionend')?.size || 0) > 0;
  return {panel, record, dispatch, armed};
}

test('opening a closed panel settles its start frame exactly once', () => {
  const {api, timers} = harness();
  const host = api.createPanelHost(() => false);
  const {panel, record} = fakePanel();

  host.apply(panel, true);

  assert.equal(record.flushes, 1, 'the un-hide needs ONE forced style+layout pass');
  assert.deepEqual(record.flushStates, ['closed'],
    'the flush must happen while the collapsed geometry is applied');
  assert.equal(panel.hidden, false);
  assert.equal(panel.dataset.panelState, 'open');
  assert.equal(timers.size, 0, 'an open arms no timer');
  host.destroy();
});

test('a seed or reduced-motion open applies in this task with no start frame', () => {
  for (const [animate, reduced] of [[false, false], [true, true]]) {
    const {api, timers} = harness();
    const host = api.createPanelHost(() => reduced);
    const {panel, record, armed} = fakePanel();

    host.apply(panel, true, animate);

    assert.equal(record.flushes, 0,
      `animate=${animate} reduced=${reduced} must not flush`);
    assert.equal(panel.hidden, false);
    assert.equal(panel.dataset.panelState, 'open');
    assert.equal(armed(), false, 'nothing to wait for');
    assert.equal(timers.size, 0);
    host.destroy();
  }
});

test('re-opening while closing continues from the live style and drops the armed close', () => {
  const {api, timers} = harness();
  const host = api.createPanelHost(() => false);
  const {panel, record, dispatch, armed} = fakePanel();

  host.apply(panel, true);
  assert.equal(record.flushes, 1);

  host.apply(panel, false, true);
  assert.equal(panel.dataset.panelState, 'closing');
  assert.equal(panel.hidden, false);
  assert.equal(armed(), true);
  assert.equal(timers.size, 1);
  const [timerId, pending] = [...timers.entries()][0];

  host.apply(panel, true, true);

  assert.equal(record.flushes, 1, 'a re-entrant open adds NO start frame');
  assert.equal(panel.dataset.panelState, 'open');
  assert.equal(panel.hidden, false);
  assert.equal(armed(), false, 'the stale transitionend listener is gone');
  assert.equal(timers.size, 0, 'the stale fallback timer is cleared');
  // Neither the removed listener nor the cleared timer can hide the panel.
  dispatch({target: panel, propertyName: 'transform'});
  pending.fn();
  assert.equal(panel.dataset.panelState, 'open');
  assert.equal(panel.hidden, false);
  assert.ok(!timers.has(timerId));
  host.destroy();
});

test('a close arms ONE bounded fallback and finishes only on the transform end', () => {
  const {api, timers} = harness();
  const host = api.createPanelHost(() => false);
  const {panel, dispatch, armed} = fakePanel();

  host.apply(panel, true);
  host.apply(panel, false, true);

  assert.equal(panel.dataset.panelState, 'closing');
  assert.equal(panel.hidden, false, 'the exit needs the panel displayed');
  assert.equal(armed(), true);
  assert.equal(timers.size, 1, 'exactly one fallback timer');
  const [timerId, pending] = [...timers.entries()][0];
  assert.ok(pending.delay > 0 && pending.delay <= api.PANEL_CLOSE_FALLBACK_MS,
    `bounded fallback expected, got ${pending.delay}`);

  // The exit animates transform, opacity and flex-basis: only transform counts.
  dispatch({target: panel, propertyName: 'opacity'});
  assert.equal(panel.dataset.panelState, 'closing');
  assert.equal(panel.hidden, false);
  // A child's transform is not the panel's own transition.
  dispatch({target: {}, propertyName: 'transform'});
  assert.equal(panel.dataset.panelState, 'closing');

  dispatch({target: panel, propertyName: 'transform'});
  assert.equal(panel.hidden, true);
  assert.equal(panel.dataset.panelState, 'closed');
  assert.equal(armed(), false);
  assert.equal(timers.size, 0);

  // A duplicated event and the captured fallback callback are both inert.
  dispatch({target: panel, propertyName: 'transform'});
  pending.fn();
  assert.equal(panel.dataset.panelState, 'closed');
  assert.equal(panel.hidden, true);
  assert.ok(!timers.has(timerId));
  host.destroy();
});

test('an unchanged state is a pure re-assert that repairs patched server markup', () => {
  const {api, timers} = harness();
  const host = api.createPanelHost(() => false);
  const {panel, record} = fakePanel();

  host.apply(panel, true);
  assert.equal(panel.dataset.panelState, 'open');
  // A LiveView patch puts the server markup back (`hidden` + closed).
  panel.hidden = true;
  panel.dataset.panelState = 'closed';

  host.apply(panel, true);

  assert.equal(panel.hidden, false, 'the same task repairs hidden');
  assert.equal(panel.dataset.panelState, 'open');
  assert.equal(record.flushes, 1, 'a stable open never re-animates');
  assert.equal(timers.size, 0);
  host.destroy();
});

test('destroy releases an armed close and the module schedules no frame', () => {
  const {api, timers} = harness();
  const host = api.createPanelHost(() => false);
  const {panel, armed} = fakePanel();

  host.apply(panel, true);
  host.apply(panel, false, true);
  assert.equal(armed(), true);
  assert.equal(timers.size, 1);

  host.destroy();

  assert.equal(timers.size, 0, 'no fallback timer may outlive the hook');
  assert.equal(armed(), false);
  assert.equal(/requestAnimationFrame/.test(domSrc), false,
    'the start frame is a synchronous flush, never a frame schedule');
});
