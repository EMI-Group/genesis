// Run with: node --test apps/evo_dash/assets/js/hooks/motion_panel.test.cjs
//
// Exercises the PURE intent → state decisions behind the shared
// `motion-panel` / `data-motion-state` recipe: "does the server's intent move
// this panel, into which of the four states, and does the move wait for the CSS
// animation?" — without a browser bundle. The DOM half (the writer, the armed
// settle, the bounded fallback) lives in motion_panel_dom.js and is pinned by
// motion_panel_dom.test.cjs; it only executes the decisions pinned here.
//
// Matching the workbench_panel.test.cjs convention: the block between the
// source's markers is sliced out and run through node:vm, so the real shipped
// code is what is measured.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const src = readFileSync(`${__dirname}/motion_panel.js`, 'utf8');
const start = src.indexOf('// --- MotionPanel: pure intent/state decisions');
const end = src.indexOf('// MotionPanel hook:');
assert.ok(start !== -1 && end > start, 'pure panel state block not found in motion_panel.js');
const source = src.slice(start, end);
const {
  PANEL_WANT_ATTR, PANEL_STATE_ATTR, PANEL_OPENING, PANEL_OPEN, PANEL_CLOSING, PANEL_CLOSED,
  PANEL_SETTLE_FALLBACK_MS, wantedOpen, hiddenFor, initialPanelState, planPanelChange,
  completePanelSettle, settleWaitsForAnimation, isPanelSettleAnimationEnd,
} = vm.runInContext(`${source}
  ({PANEL_WANT_ATTR, PANEL_STATE_ATTR, PANEL_OPENING, PANEL_OPEN, PANEL_CLOSING, PANEL_CLOSED,
    PANEL_SETTLE_FALLBACK_MS, wantedOpen, hiddenFor, initialPanelState, planPanelChange,
    completePanelSettle, settleWaitsForAnimation, isPanelSettleAnimationEnd});`,
vm.createContext({}));

test('the two channels are separate attributes, never one shared one', () => {
  // The server owns the intent, the hook owns the state: collapsing them would
  // make every patch fight the running animation.
  assert.equal(PANEL_WANT_ATTR, 'data-motion-want');
  assert.equal(PANEL_STATE_ATTR, 'data-motion-state');
  assert.notEqual(PANEL_WANT_ATTR, PANEL_STATE_ATTR);
});

test('only the two literal spellings are an intent', () => {
  assert.equal(wantedOpen('true'), true);
  assert.equal(wantedOpen('false'), false);
  // A missing attribute (a patch that dropped it) and every stray spelling are
  // `null`: an unknown intent may never move the panel.
  for (const stray of [null, undefined, '', 'TRUE', 'True', '1', '0', 'open', 'false ', 1, true, {}]) {
    assert.equal(wantedOpen(stray), null, `${JSON.stringify(stray)} must not move the panel`);
  }
});

test('hidden follows the state — only closed is off screen', () => {
  assert.equal(hiddenFor(PANEL_CLOSED), true);
  for (const state of [PANEL_OPENING, PANEL_OPEN, PANEL_CLOSING]) {
    assert.equal(hiddenFor(state), false, `${state} keeps the panel displayed`);
  }
});

test('an open intent mounts ENTERING; anything else mounts closed and hidden', () => {
  const entering = initialPanelState(true);
  assert.equal(entering.state, PANEL_OPENING, 'the CSS entry animation IS the entrance');
  assert.equal(entering.hidden, false);
  for (const want of [false, null, undefined]) {
    const closed = initialPanelState(want);
    assert.equal(closed.state, PANEL_CLOSED);
    assert.equal(closed.hidden, true, 'a panel the server rendered closed never paints');
  }
});

test('a closed panel opens with an animation and is then idempotent', () => {
  const plan = planPanelChange(PANEL_CLOSED, true);
  assert.equal(plan.state, PANEL_OPENING);
  assert.equal(plan.hidden, false);
  assert.equal(plan.animate, true);
  // A repeated open intent never restarts the entry.
  for (const state of [PANEL_OPENING, PANEL_OPEN]) {
    const repeat = planPanelChange(state, true);
    assert.equal(repeat.state, state);
    assert.equal(repeat.hidden, false);
    assert.equal(repeat.animate, false, `${state} must not re-animate`);
  }
});

test('a re-entrant open while closing continues from the live frame', () => {
  const plan = planPanelChange(PANEL_CLOSING, true);
  assert.equal(plan.state, PANEL_OPEN);
  assert.equal(plan.hidden, false);
  assert.equal(plan.animate, false, 'no starting frame and no second entry');
});

test('closing is an animated exit that keeps the panel displayed', () => {
  for (const state of [PANEL_OPENING, PANEL_OPEN]) {
    const plan = planPanelChange(state, false);
    assert.equal(plan.state, PANEL_CLOSING, state);
    assert.equal(plan.hidden, false, 'hidden is only set once the exit settled');
    assert.equal(plan.animate, true);
  }
});

test('a repeated close never restarts the exit or un-hides a closed panel', () => {
  const repeat = planPanelChange(PANEL_CLOSING, false);
  assert.equal(repeat.state, PANEL_CLOSING);
  assert.equal(repeat.hidden, false);
  assert.equal(repeat.animate, false);
  const closed = planPanelChange(PANEL_CLOSED, false);
  assert.equal(closed.state, PANEL_CLOSED);
  assert.equal(closed.hidden, true);
  assert.equal(closed.animate, false);
});

test('an absent intent changes nothing at all', () => {
  for (const state of [PANEL_CLOSED, PANEL_OPENING, PANEL_OPEN, PANEL_CLOSING]) {
    for (const want of [null, undefined]) {
      const plan = planPanelChange(state, want);
      assert.equal(plan.state, state, `${state} must stay put`);
      assert.equal(plan.hidden, hiddenFor(state));
      assert.equal(plan.animate, false);
    }
  }
});

test('an entry settles to open and an exit to closed, exactly once', () => {
  const opened = completePanelSettle(PANEL_OPENING);
  assert.equal(opened.state, PANEL_OPEN);
  assert.equal(opened.hidden, false);
  const closed = completePanelSettle(PANEL_CLOSING);
  assert.equal(closed.state, PANEL_CLOSED);
  assert.equal(closed.hidden, true, 'the close hides the panel only now');
  // A second completion (animationend after the fallback timer, or a duplicate
  // listener) is inert, and a stable state has nothing to settle.
  for (const state of [PANEL_OPEN, PANEL_CLOSED, null, undefined, 'nonsense']) {
    assert.equal(completePanelSettle(state), null, `${state} settles nothing`);
  }
});

test('a settle waits for the animation only when there is one to wait for', () => {
  for (const state of [PANEL_OPENING, PANEL_CLOSING]) {
    assert.equal(settleWaitsForAnimation(state, false), true, state);
    // Reduced motion shrinks the animation to an unobservable .01 ms: the
    // settle completes in the same task instead of waiting for an event.
    assert.equal(settleWaitsForAnimation(state, true), false, state);
  }
  for (const state of [PANEL_OPEN, PANEL_CLOSED, null, undefined]) {
    assert.equal(settleWaitsForAnimation(state, false), false, `${state} waits for nothing`);
  }
});

test('only the panel ROOT may settle itself, never a child animation', () => {
  const root = {};
  assert.equal(isPanelSettleAnimationEnd(PANEL_OPENING, root, root), true);
  assert.equal(isPanelSettleAnimationEnd(PANEL_CLOSING, root, root), true);
  // A child's animationend bubbles through the panel: it must not settle it.
  assert.equal(isPanelSettleAnimationEnd(PANEL_CLOSING, {}, root), false);
  assert.equal(isPanelSettleAnimationEnd(PANEL_OPENING, null, root), false);
  // A stable state has no settle to finish, and a missing root never matches.
  assert.equal(isPanelSettleAnimationEnd(PANEL_OPEN, root, root), false);
  assert.equal(isPanelSettleAnimationEnd(PANEL_OPENING, undefined, undefined), false);
});

test('the settle fallback is bounded and short enough to stay invisible', () => {
  assert.ok(Number.isFinite(PANEL_SETTLE_FALLBACK_MS));
  assert.ok(PANEL_SETTLE_FALLBACK_MS > 0 && PANEL_SETTLE_FALLBACK_MS <= 500,
    `expected a bounded fallback, got ${PANEL_SETTLE_FALLBACK_MS}`);
  // Just past the 170 ms entry and the 120 ms exit it must cover.
  assert.ok(PANEL_SETTLE_FALLBACK_MS >= 170);
});

test('the shipped CSS owns every duration the JS waits for', () => {
  const css = readFileSync(`${__dirname}/../../css/motion.css`, 'utf8');
  // The one JS constant only guards an animation that never fires; the
  // keyframes it waits for stay token-driven in motion.css.
  assert.match(css, /--motion-fast:\s*120ms/);
  assert.match(css, /--motion-base:\s*170ms/);
});
