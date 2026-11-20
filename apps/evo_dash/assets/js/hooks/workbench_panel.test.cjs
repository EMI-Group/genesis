// Run with: node --test apps/evo_dash/assets/js/hooks/workbench_panel.test.cjs
//
// Exercises the PURE right-panel state machine behind the workbench history /
// Git aside — "may this panel be shown, and what does a user request do to it?"
// — without a browser bundle. The DOM half (the rAF starting frame, the
// transitionend listener, the bounded fallback timer) lives in workbench.js and
// has no decision of its own; it only executes the plans pinned here.
//
// Matching the state_persistence.test.cjs / agent_history_scroll.test.cjs
// convention: the block between the source's markers is sliced out and run
// through node:vm, so the real shipped code is what is measured.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const src = readFileSync(`${__dirname}/workbench_panel.js`, 'utf8');
const start = src.indexOf('// --- WorkbenchPanel: pure right-panel state machine');
const end = src.indexOf('// WorkbenchPanel hook:');
assert.ok(start !== -1 && end > start, 'pure panel state machine block not found in workbench_panel.js');
const source = src.slice(start, end);
const {
  PANEL_CLOSED, PANEL_OPEN, PANEL_CLOSING, PANEL_CLOSE_FALLBACK_MS,
  initialPanelState, planPanelRequest, completePanelClose,
  isPanelCloseTransition, panelCloseWaitsForTransition,
} = vm.runInContext(`${source}
  ({PANEL_CLOSED, PANEL_OPEN, PANEL_CLOSING, PANEL_CLOSE_FALLBACK_MS,
    initialPanelState, planPanelRequest, completePanelClose,
    isPanelCloseTransition, panelCloseWaitsForTransition});`, vm.createContext({}));

test('a fresh tab starts CLOSED — the panel is hidden by default', () => {
  assert.equal(initialPanelState(null), PANEL_CLOSED);
  assert.equal(initialPanelState(undefined), PANEL_CLOSED);
});

test('only an explicit open preference survives into the next load', () => {
  assert.equal(initialPanelState(true), PANEL_OPEN);
  // An explicit close is remembered as closed…
  assert.equal(initialPanelState(false), PANEL_CLOSED);
  // …and anything that is not literally `true` never opens the panel.
  for (const stray of ['true', 1, 'open', {}]) {
    assert.equal(initialPanelState(stray), PANEL_CLOSED, `${JSON.stringify(stray)} must not open`);
  }
});

test('an open request reveals the panel on a fresh starting frame', () => {
  const plan = planPanelRequest(PANEL_CLOSED, true);
  assert.equal(plan.state, PANEL_OPEN);
  assert.equal(plan.hidden, false);
  assert.equal(plan.cancelClose, false);
  assert.equal(plan.animate, true, 'a closed panel needs one frame at the closed style first');
});

test('an open request during closing cancels the pending hidden-marking', () => {
  const plan = planPanelRequest(PANEL_CLOSING, true);
  assert.equal(plan.state, PANEL_OPEN);
  assert.equal(plan.hidden, false);
  assert.equal(plan.cancelClose, true, 'the armed close must be dropped, not raced');
  assert.equal(plan.animate, false, 'it continues from its live interpolated style');
});

test('a late close completion cannot hide a re-opened panel', () => {
  let state = initialPanelState(null);
  state = planPanelRequest(state, true).state;
  state = planPanelRequest(state, false).state;
  assert.equal(state, PANEL_CLOSING);
  // The user re-opens mid-exit: whichever timer/listener was armed is now stale.
  state = planPanelRequest(state, true).state;
  assert.equal(state, PANEL_OPEN);
  assert.equal(completePanelClose(state), null, 'the stale close applies nothing');
});

test('closing is an animated exit that keeps the panel displayed', () => {
  const plan = planPanelRequest(PANEL_OPEN, false);
  assert.equal(plan.state, PANEL_CLOSING);
  assert.equal(plan.hidden, false, 'hidden is only set once the exit finished');
  assert.equal(plan.animate, true);
  assert.equal(plan.cancelClose, false);
});

test('a repeated request never restarts a running close or a stable open', () => {
  const closing = planPanelRequest(PANEL_CLOSING, false);
  assert.equal(closing.state, PANEL_CLOSING);
  assert.equal(closing.hidden, false);
  assert.equal(planPanelRequest(PANEL_OPEN, true).state, PANEL_OPEN);
  const closed = planPanelRequest(PANEL_CLOSED, false);
  assert.equal(closed.state, PANEL_CLOSED);
  assert.equal(closed.hidden, true);
  assert.equal(closed.animate, false, 'an already-closed panel must not animate');
});

test('a close reaches closed exactly once', () => {
  const finishing = planPanelRequest(initialPanelState(true), false);
  assert.equal(finishing.state, PANEL_CLOSING);
  const done = completePanelClose(finishing.state);
  // (Field comparison, not deepEqual: the plan is an object from the vm realm.)
  assert.equal(done.state, PANEL_CLOSED);
  assert.equal(done.hidden, true);
  // A second finishing event (transitionend after the fallback timer, or a
  // duplicated listener) is inert.
  assert.equal(completePanelClose(done.state), null);
  assert.equal(completePanelClose(PANEL_OPEN), null);
});

test('only the transform transition may finish a close', () => {
  assert.equal(isPanelCloseTransition(PANEL_CLOSING, 'transform'), true);
  for (const property of ['opacity', 'flex-basis', 'padding', 'border-inline-start-width']) {
    assert.equal(isPanelCloseTransition(PANEL_CLOSING, property), false, property);
  }
  assert.equal(isPanelCloseTransition(PANEL_OPEN, 'transform'), false);
  assert.equal(isPanelCloseTransition(PANEL_CLOSED, 'transform'), false);
});

test('the reduced-motion / no-transition path still ends in closed', () => {
  const close = planPanelRequest(PANEL_OPEN, false);
  assert.equal(panelCloseWaitsForTransition(close.animate, false), true);
  // No CSS transition → no transitionend will ever fire: close in this task.
  assert.equal(panelCloseWaitsForTransition(close.animate, true), false);
  assert.equal(completePanelClose(close.state).state, PANEL_CLOSED);
  // An initial seed (animate off) also completes without waiting.
  assert.equal(panelCloseWaitsForTransition(false, false), false);
});

test('the fallback timer is bounded and short enough to stay invisible', () => {
  assert.ok(Number.isFinite(PANEL_CLOSE_FALLBACK_MS));
  assert.ok(PANEL_CLOSE_FALLBACK_MS > 0 && PANEL_CLOSE_FALLBACK_MS <= 500,
    `expected a bounded fallback, got ${PANEL_CLOSE_FALLBACK_MS}`);
});
