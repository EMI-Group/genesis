// Run with: node --test apps/evo_dash/assets/js/hooks/disclosure_motion.test.cjs
//
// Exercises the shared motion foundation behind every animated exit: "does this
// close have to wait for an animation, and which animationend may finish it?"
// — without a browser bundle. The DOM half (the listener, the bounded fallback
// timer) only executes the decisions pinned here, and is also driven below
// through fake nodes so exactly-once completion stays pinned.
//
// Matching the workbench_panel.test.cjs / agent_history_scroll.test.cjs
// convention: the blocks between the source's markers are sliced out and run
// through node:vm, so the real shipped code is what is measured.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const src = readFileSync(`${__dirname}/disclosure_motion.js`, 'utf8');
const pureStart = src.indexOf('// --- DisclosureMotion: pure close decisions (unit-tested)');
const pureEnd = src.indexOf('// DisclosureMotion: DOM orchestration + hook');
const domStart = pureEnd;
const domEnd = src.indexOf('const DisclosureMotion = {');
assert.ok(pureStart !== -1 && pureEnd > pureStart, 'pure close decisions block not found in disclosure_motion.js');
assert.ok(pureEnd !== -1 && domEnd > domStart, 'DOM orchestration block not found in disclosure_motion.js');

const pureSource = src.slice(pureStart, pureEnd);
const domSource = src.slice(domStart, domEnd);

// A pure context has NO window: the same situation as a browser without
// matchMedia and of this test runner itself.
const pure = vm.runInContext(`${pureSource}
  ({DISCLOSURE_CLOSE_FALLBACK_MS, DISCLOSURE_STATE_ATTR, DISCLOSURE_CLOSING,
    prefersReducedMotion, isPanelAnimationEnd, closeWaitsForAnimation});`, vm.createContext({}));
const {
  DISCLOSURE_CLOSE_FALLBACK_MS, DISCLOSURE_STATE_ATTR, DISCLOSURE_CLOSING,
  prefersReducedMotion, isPanelAnimationEnd, closeWaitsForAnimation,
} = pure;

// A fake node records its own attributes and listeners, so a close can be driven
// event by event. Timers are collected instead of scheduled: a 200 ms fallback
// must never reach the test runner's real clock.
function fakeNode({open = true} = {}) {
  const attributes = new Map();
  const listeners = new Map();
  if (open) attributes.set('open', '');
  return {
    open,
    listeners,
    getAttribute: name => attributes.get(name) ?? null,
    setAttribute(name, value) {
      attributes.set(name, value);
      if (name === 'open') this.open = true;
    },
    hasAttribute: name => attributes.has(name),
    removeAttribute(name) {
      attributes.delete(name);
      if (name === 'open') this.open = false;
    },
    addEventListener(name, fn) { listeners.set(name, fn); },
    removeEventListener(name, fn) { if (listeners.get(name) === fn) listeners.delete(name); },
    fire(name, target) { listeners.get(name)?.({target}); },
    close() { this.closedNatively = true; this.removeAttribute('open'); }
  };
}

function motionContext({reduced = false} = {}) {
  const timers = [];
  const context = vm.createContext({
    window: {matchMedia: () => ({matches: reduced})},
    setTimeout: (fn, ms) => { const timer = {fn, ms, cleared: false}; timers.push(timer); return timer; },
    clearTimeout: timer => { if (timer) timer.cleared = true; },
  });
  const {closeAnimated} = vm.runInContext(`${pureSource}
    ${domSource}
    ({closeAnimated});`, context);
  return {closeAnimated, timers};
}

test('reduced motion is a guarded, never-throwing preference lookup', () => {
  // No matchMedia at all (the vm contexts, an old WebView) is "no preference" —
  // the unguarded call capsule_panel.js makes would throw here.
  assert.equal(prefersReducedMotion(undefined), false);
  assert.equal(prefersReducedMotion({}), false);
  assert.equal(prefersReducedMotion({matchMedia: 'nope'}), false);
  assert.equal(prefersReducedMotion({matchMedia: () => ({matches: true})}), true);
  assert.equal(prefersReducedMotion({matchMedia: () => ({matches: false})}), false);
  // The default parameter reads the ambient window, which this context lacks.
  assert.equal(prefersReducedMotion(), false);
});

test('a close waits for an animation only when there is one to wait for', () => {
  // A present panel, no reduced motion and no close already running: wait.
  assert.equal(closeWaitsForAnimation({reduced: false, panelPresent: true, closing: false}), true);
  // Reduced motion removes the animation → complete in the same task.
  assert.equal(closeWaitsForAnimation({reduced: true, panelPresent: true, closing: false}), false);
  // No panel (nothing rendered to animate) → same task.
  assert.equal(closeWaitsForAnimation({reduced: false, panelPresent: false, closing: false}), false);
  // A close that is already running is finished, never re-armed.
  assert.equal(closeWaitsForAnimation({reduced: false, panelPresent: true, closing: true}), false);
  // Missing options are inert, not a crash.
  assert.equal(closeWaitsForAnimation(), false);
});

test('only an animationend on the panel itself may finish a close', () => {
  const panel = fakeNode();
  const child = fakeNode();
  assert.equal(isPanelAnimationEnd(DISCLOSURE_CLOSING, panel, panel), true);
  assert.equal(isPanelAnimationEnd(DISCLOSURE_CLOSING, child, panel), false, 'a child animation bubbles up');
  assert.equal(isPanelAnimationEnd(DISCLOSURE_CLOSING, panel, null), false);
  assert.equal(isPanelAnimationEnd('open', panel, panel), false);
  assert.equal(isPanelAnimationEnd(DISCLOSURE_CLOSING, undefined, panel), false);
});

test('the fallback timer is bounded and short enough to stay invisible', () => {
  assert.ok(Number.isFinite(DISCLOSURE_CLOSE_FALLBACK_MS));
  assert.ok(DISCLOSURE_CLOSE_FALLBACK_MS > 0 && DISCLOSURE_CLOSE_FALLBACK_MS <= 500,
    `expected a bounded fallback, got ${DISCLOSURE_CLOSE_FALLBACK_MS}`);
});

test('the hook owns exactly one attribute: data-disclosure-state="closing"', () => {
  assert.equal(DISCLOSURE_STATE_ATTR, 'data-disclosure-state');
  assert.equal(DISCLOSURE_CLOSING, 'closing');
});

test('reduced motion completes an animated close in the same task', () => {
  const {closeAnimated, timers} = motionContext({reduced: true});
  const root = fakeNode();
  const panel = fakeNode();
  let completions = 0;
  closeAnimated(root, {panel, onComplete: () => { completions += 1; }});
  // Everything already happened, synchronously, before the call returned.
  assert.equal(completions, 1);
  assert.equal(timers.length, 0, 'no waiting timer is armed under reduced motion');
  assert.equal(root.hasAttribute(DISCLOSURE_STATE_ATTR), false);
  assert.equal(root.open, false);
  assert.equal(panel.listeners.size, 0);
});

test('a missing panel and a missing root never wait and never throw', () => {
  const {closeAnimated, timers} = motionContext();
  const root = fakeNode();
  let completions = 0;
  closeAnimated(root, {panel: null, onComplete: () => { completions += 1; }});
  assert.equal(completions, 1);
  assert.equal(timers.length, 0);
  assert.equal(root.open, false);
  // No root at all: a no-op, not a crash.
  assert.doesNotThrow(() => closeAnimated(null, {panel: fakeNode()}));
});

test('an animationend from anything but the panel does not finish the close', () => {
  const {closeAnimated, timers} = motionContext();
  const root = fakeNode();
  const panel = fakeNode();
  const child = fakeNode();
  let completions = 0;
  closeAnimated(root, {panel, onComplete: () => { completions += 1; }});
  assert.equal(root.getAttribute(DISCLOSURE_STATE_ATTR), DISCLOSURE_CLOSING, 'the exit keyframes are armed');
  assert.equal(timers.length, 1, 'the bounded fallback is the safety net');
  panel.fire('animationend', child);
  assert.equal(completions, 0, 'a child animation must not end the exit');
  assert.equal(root.hasAttribute('open'), true, 'the element stays open while it animates out');
  panel.fire('animationend', panel);
  assert.equal(completions, 1);
  assert.equal(root.getAttribute(DISCLOSURE_STATE_ATTR), null);
  assert.equal(root.open, false);
  assert.equal(panel.listeners.size, 0, 'the listener is released on completion');
  assert.equal(timers[0].cleared, true, 'the fallback is cancelled on completion');
});

test('a close completes exactly once — a later timer or a repeated request is inert', () => {
  const {closeAnimated, timers} = motionContext();
  const root = fakeNode();
  const panel = fakeNode();
  let completions = 0;
  closeAnimated(root, {panel, onComplete: () => { completions += 1; }});
  panel.fire('animationend', panel);
  // The fallback timer still fires afterwards (a real clearTimeout may race).
  timers.forEach(timer => timer.fn());
  assert.equal(completions, 1);
  // A second close request on the finished root arms nothing new.
  closeAnimated(root, {panel, onComplete: () => { completions += 1; }});
  timers.forEach(timer => timer.fn());
  assert.equal(completions, 2, 'one completion per close, never a duplicate');
  assert.equal(timers.length, 2, 'the second close had no running close to reuse');
});

test('a repeated request during the exit completes the same close once', () => {
  const {closeAnimated, timers} = motionContext();
  const root = fakeNode();
  const panel = fakeNode();
  const completions = [];
  closeAnimated(root, {panel, onComplete: () => completions.push('first')});
  const armed = timers.length;
  closeAnimated(root, {panel, onComplete: () => completions.push('second')});
  // The running close is finished in the same task; no second listener/timer.
  assert.equal(timers.length, armed, 'no second fallback timer is armed');
  assert.deepEqual(completions, ['first', 'second']);
  assert.equal(root.open, false);
  assert.equal(panel.listeners.size, 0);
  timers.forEach(timer => timer.fn());
  assert.deepEqual(completions, ['first', 'second'], 'the settled close stays settled');
});

test('a <dialog>-shaped root is released through its own close() so "close" listeners fire', () => {
  const {closeAnimated} = motionContext({reduced: true});
  const root = fakeNode();
  const panel = fakeNode();
  closeAnimated(root, {panel, attr: 'data-window-state'});
  assert.equal(root.closedNatively, true);
  assert.equal(root.open, false);
  assert.equal(root.hasAttribute('data-window-state'), false);

  // A custom attribute is honoured (workbench windows).
  const {closeAnimated: animated} = motionContext();
  const windowRoot = fakeNode();
  const windowPanel = fakeNode();
  animated(windowRoot, {panel: windowPanel, attr: 'data-window-state'});
  assert.equal(windowRoot.getAttribute('data-window-state'), 'closing');
  windowPanel.fire('animationend', windowPanel);
  assert.equal(windowRoot.hasAttribute('data-window-state'), false);
});
