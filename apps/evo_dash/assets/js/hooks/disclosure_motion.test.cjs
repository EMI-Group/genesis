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
const hookStart = domEnd;
const hookEnd = src.indexOf('// ONE shared motion bridge');
assert.ok(pureStart !== -1 && pureEnd > pureStart, 'pure close decisions block not found in disclosure_motion.js');
assert.ok(pureEnd !== -1 && domEnd > domStart, 'DOM orchestration block not found in disclosure_motion.js');
assert.ok(hookStart !== -1 && hookEnd > hookStart, 'the DisclosureMotion hook object was not found');

const pureSource = src.slice(pureStart, pureEnd);
const domSource = src.slice(domStart, domEnd);
const hookSource = src.slice(hookStart, hookEnd);

// A pure context has NO window: the same situation as a browser without
// matchMedia and of this test runner itself.
const pure = vm.runInContext(`${pureSource}
  ({DISCLOSURE_CLOSE_FALLBACK_MS, DISCLOSURE_STATE_ATTR, DISCLOSURE_CLOSING,
    prefersReducedMotion, isPanelAnimationEnd, closeWaitsForAnimation,
    planOpenReconcile});`, vm.createContext({}));
const {
  DISCLOSURE_CLOSE_FALLBACK_MS, DISCLOSURE_STATE_ATTR, DISCLOSURE_CLOSING,
  prefersReducedMotion, isPanelAnimationEnd, closeWaitsForAnimation, planOpenReconcile,
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
    // A live browser node is connected; `updated()` only skips an element that
    // is EXPLICITLY detached (undefined means "assume mounted").
    isConnected: true,
    summary: undefined,
    panelNode: undefined,
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
    close() { this.closedNatively = true; this.removeAttribute('open'); },
    querySelector(selector) {
      if (selector === ':scope > summary') return this.summary ?? null;
      if (selector === ':scope > :not(summary)') return this.panelNode ?? null;
      return null;
    }
  };
}

function summaryClick(summary) {
  return {
    target: {closest: name => (name === 'summary' ? summary : null)},
    prevented: false,
    preventDefault() { this.prevented = true; }
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

// The REAL hook object, evaluated with the same slices, so `mounted`/`updated`/
// `handleClick`/`destroyed` run as shipped (no reimplementation in the test).
function hookContext({reduced = false} = {}) {
  const timers = [];
  const context = vm.createContext({
    window: {matchMedia: () => ({matches: reduced})},
    setTimeout: (fn, ms) => { const timer = {fn, ms, cleared: false}; timers.push(timer); return timer; },
    clearTimeout: timer => { if (timer) timer.cleared = true; },
  });
  // The leading `;` terminates the slice's object literal, so the export
  // expression is not parsed as a call on it.
  const {DisclosureMotion} = vm.runInContext(`${pureSource}
    ${domSource}
    ${hookSource}
    ;({DisclosureMotion});`, context);
  return {DisclosureMotion, timers};
}

function mountDisclosure(ctx, {open = true, panel = true} = {}) {
  const root = fakeNode({open});
  const panelNode = panel ? fakeNode() : undefined;
  root.panelNode = panelNode;
  root.summary = fakeNode();
  const hook = Object.assign(Object.create(ctx.DisclosureMotion), {el: root});
  hook.mounted();
  return {hook, root, panelNode};
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

// --- planOpenReconcile: the server-owned `open` contract
// The one surface whose markup renders `open` from server state is the Settings
// provider account's "Advanced" disclosure; every other disclosure here leaves
// `open` browser-native, for which the plan must always answer "none".

test('agreement is inert: a patch that matches the hook\'s intent changes nothing', () => {
  const open = planOpenReconcile({domOpen: true, wantOpen: true, closing: false});
  assert.equal(open.action, 'none');
  assert.equal(open.wantOpen, true);

  const closed = planOpenReconcile({domOpen: false, wantOpen: false, closing: false});
  assert.equal(closed.action, 'none');
  assert.equal(closed.wantOpen, false);

  // Total: a missing/garbage plan is a closed, inert disclosure, never a throw.
  assert.equal(planOpenReconcile().action, 'none');
  assert.equal(planOpenReconcile().wantOpen, false);
  assert.equal(planOpenReconcile({domOpen: 'yes', wantOpen: 1}).action, 'none');
  assert.equal(planOpenReconcile({domOpen: 'yes', wantOpen: 1}).wantOpen, false);
});

test('mid-exit with the patch already dropping open keeps the frame ("readd")', () => {
  const plan = planOpenReconcile({domOpen: false, wantOpen: false, closing: true});
  assert.equal(plan.action, 'readd');
  // A running exit already settled the intent: the close primitive owns `open`.
  assert.equal(plan.wantOpen, false);

  // ...and while the exit runs with `open` still present there is nothing to do.
  assert.equal(planOpenReconcile({domOpen: true, wantOpen: false, closing: true}).action, 'none');
  assert.equal(planOpenReconcile({domOpen: true, wantOpen: true, closing: true}).action, 'none');
});

test('a server close of an open disclosure is animated, not snapped ("readd-and-close")', () => {
  const plan = planOpenReconcile({domOpen: false, wantOpen: true, closing: false});
  assert.equal(plan.action, 'readd-and-close');
  assert.equal(plan.wantOpen, false, 'the hook accepts the server close and plays the exit');
});

test('a stale server re-open of a closed disclosure is dropped ("drop")', () => {
  const plan = planOpenReconcile({domOpen: true, wantOpen: false, closing: false});
  assert.equal(plan.action, 'drop');
  assert.equal(plan.wantOpen, false, 'client intent wins until the server catches up');
});

test('mounted seeds the intent and the toggle listener keeps it current', () => {
  const ctx = hookContext();
  const {hook, root} = mountDisclosure(ctx, {open: true});
  assert.equal(hook.wantOpen, true);
  assert.deepEqual([...root.listeners.keys()].sort(), ['click', 'toggle']);

  // A native/open-by-browser change (find-in-page, a keyboard toggle) is truth.
  root.open = false;
  root.fire('toggle', root);
  assert.equal(hook.wantOpen, false);

  hook.destroyed();
  assert.equal(root.listeners.size, 0, 'destroyed() releases BOTH listeners');
  assert.equal(hook.onClick, null);
  assert.equal(hook.onToggle, null);
});

test('an OPEN click stays native but arms the intent', () => {
  const ctx = hookContext();
  const {hook, root} = mountDisclosure(ctx, {open: false});
  const event = summaryClick(root.summary);
  hook.handleClick(event);
  assert.equal(event.prevented, false, 'opening is the CSS-only path');
  assert.equal(hook.wantOpen, true);
  assert.equal(ctx.timers.length, 0, 'no exit is armed for an open');

  // The native toggle lands afterwards; the patch that follows is inert.
  root.open = true;
  root.fire('toggle', root);
  hook.updated();
  assert.equal(hook.wantOpen, true);
  assert.equal(root.open, true);
  assert.equal(ctx.timers.length, 0);
});

test('updated() re-asserts the frame mid-exit and leaves exactly ONE close', () => {
  const ctx = hookContext();
  const {hook, root, panelNode} = mountDisclosure(ctx, {open: true});

  const event = summaryClick(root.summary);
  hook.handleClick(event);
  assert.equal(event.prevented, true, 'the native close is intercepted');
  assert.equal(hook.wantOpen, false);
  assert.equal(root.getAttribute(DISCLOSURE_STATE_ATTR), DISCLOSURE_CLOSING);
  assert.equal(ctx.timers.length, 1);

  // morphdom applies the server patch that removes `open` mid-exit.
  root.open = false;
  hook.updated();
  assert.equal(root.open, true, 'the previous frame is re-asserted in the same task');
  assert.equal(ctx.timers.length, 1, 'no second close is ever armed');
  assert.equal(root.getAttribute(DISCLOSURE_STATE_ATTR), DISCLOSURE_CLOSING, 'the exit gate is untouched');

  // A second mid-exit patch is reconciled the same way.
  root.open = false;
  hook.updated();
  assert.equal(root.open, true);
  assert.equal(ctx.timers.length, 1);

  // The exit finishes normally.
  panelNode.fire('animationend', panelNode);
  assert.equal(root.open, false);
  assert.equal(root.getAttribute(DISCLOSURE_STATE_ATTR), null);
  // ...and a later agreeing patch is inert.
  hook.updated();
  assert.equal(root.open, false);
  assert.equal(ctx.timers.length, 1);
});

test('updated() animates a server close instead of snapping the content away', () => {
  const ctx = hookContext();
  const {hook, root, panelNode} = mountDisclosure(ctx, {open: true});

  // No click came from the user: the server rendered `open=false`.
  root.open = false;
  hook.updated();
  assert.equal(root.open, true, 'the frame is re-asserted');
  assert.equal(hook.wantOpen, false);
  assert.equal(root.getAttribute(DISCLOSURE_STATE_ATTR), DISCLOSURE_CLOSING);
  assert.equal(ctx.timers.length, 1);

  panelNode.fire('animationend', panelNode);
  assert.equal(root.open, false);
  assert.equal(root.getAttribute(DISCLOSURE_STATE_ATTR), null);
});

test('updated() drops a stale server open on a closed disclosure, without arming an exit', () => {
  const ctx = hookContext();
  const {hook, root} = mountDisclosure(ctx, {open: false});

  root.open = true; // the server has not caught up with the user's close yet
  hook.updated();
  assert.equal(root.open, false);
  assert.equal(hook.wantOpen, false);
  assert.equal(ctx.timers.length, 0, 'a closed disclosure has no exit to play');

  // The agreeing patch that follows is inert.
  hook.updated();
  assert.equal(root.open, false);
  assert.equal(ctx.timers.length, 0);
});

test('a panel-less disclosure still closes through the bounded fallback', () => {
  const ctx = hookContext();
  const {hook, root} = mountDisclosure(ctx, {open: true, panel: false});

  root.open = false;
  hook.updated();
  assert.equal(root.open, true);
  assert.equal(ctx.timers.length, 1, 'the fallback timer is the safety net');
  ctx.timers.forEach(timer => timer.fn());
  assert.equal(root.open, false);
  assert.equal(root.getAttribute(DISCLOSURE_STATE_ATTR), null);
});

test('under reduced motion a reconciled close completes in the same task', () => {
  const ctx = hookContext({reduced: true});
  const {hook, root, panelNode} = mountDisclosure(ctx, {open: true});

  root.open = false;
  hook.updated();
  assert.equal(root.open, false, 'no frame is kept when there is no exit to play');
  assert.equal(root.getAttribute(DISCLOSURE_STATE_ATTR), null);
  assert.equal(ctx.timers.length, 0);
  assert.equal(panelNode.listeners.size, 0);
});

test('a detached element is never re-opened, closed or re-animated by a patch', () => {
  const ctx = hookContext();
  const {hook, root} = mountDisclosure(ctx, {open: true});

  root.isConnected = false;
  root.open = false;
  hook.updated();
  assert.equal(root.open, false, 'the element is leaving the DOM');
  assert.equal(ctx.timers.length, 0);
  assert.equal(root.getAttribute(DISCLOSURE_STATE_ATTR), null);
});
