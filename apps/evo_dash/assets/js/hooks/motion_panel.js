// The pure decision half of the `motion-panel` / `data-motion-state` recipe:
// assets/css/motion.css section 4 owns the entry/exit keyframes and the tokens,
// this module decides WHICH of the four states a panel is in, and
// motion_panel_dom.js is the only thing that writes that state onto an element.
// Everything between the markers below is total and side-effect free, so
// `motion_panel.test.cjs` can run THIS source through node:vm with no browser
// and no build step (the workbench_panel.test.cjs convention).

// --- MotionPanel: pure intent/state decisions
// The INTENT is server-owned: the server renders `data-motion-want` from the
// assign that decides visibility (and re-renders it on every patch), so the
// client never guesses what the panel should be showing.
const PANEL_WANT_ATTR = "data-motion-want"
// The STATE is hook-owned: only motion_panel_dom.js writes it, and motion.css
// keys the keyframes off it, so a LiveView patch can re-render the panel
// without cutting a running exit short.
const PANEL_STATE_ATTR = "data-motion-state"
const PANEL_OPENING = "opening"
const PANEL_OPEN = "open"
const PANEL_CLOSING = "closing"
const PANEL_CLOSED = "closed"
// Bounded fallback for a settle whose animationend never arrives (a hidden tab,
// an unrendered panel, a WebView that suppresses animations): 200 ms is just
// past the 120 ms `--motion-fast` exit and the 170 ms `--motion-base` entry, so
// it completes a stuck settle without being visible beside the 220 ms
// `--motion-slow` token. No other duration lives in JS.
const PANEL_SETTLE_FALLBACK_MS = 200

// ONLY the two literal spellings move anything: a missing attribute (a patch
// that stripped the server's intent) and an unknown value are BOTH `null`, so
// an unknown intent leaves the panel exactly where it is instead of guessing.
function wantedOpen(value) {
  if (value === "true") return true
  if (value === "false") return false
  return null
}

// A panel's state follows from its own attributes, and `hidden` follows from the
// state: `opening` is displayed (the entry animation runs), only `closed` is
// hidden — which is what lets a settle keep the panel on screen for its exit.
function hiddenFor(state) {
  return state === PANEL_CLOSED
}

// The state a panel STARTS in when nothing has written one yet. An open intent
// is a MOUNT-TIME ENTRY: the panel starts `opening` so the CSS entry animation
// is the entrance; anything else starts closed and hidden, so a panel the server
// rendered closed never paints.
function initialPanelState(wantOpen) {
  return wantOpen === true
    ? {state: PANEL_OPENING, hidden: false}
    : {state: PANEL_CLOSED, hidden: true}
}

// What one read of the server's intent does to the current state.
// `null` (no/unknown intent) changes nothing — a patch that drops the attribute
// is a no-op, never an implicit close.
// `true` enters from `closed` with `animate` (the entry keyframes are the whole
// animation) and is idempotent from `opening`/`open`; a re-entrant open while
// `closing` continues from the LIVE interpolated frame, so it needs no starting
// frame and no second entry — it just becomes `open` again.
// `false` starts ONE exit from `opening`/`open` and is idempotent from
// `closing`/`closed` (a repeated close never restarts the exit).
function planPanelChange(state, wantOpen) {
  if (wantOpen === true) {
    if (state === PANEL_CLOSED) return {state: PANEL_OPENING, hidden: false, animate: true}
    if (state === PANEL_CLOSING) return {state: PANEL_OPEN, hidden: false, animate: false}
    return {state, hidden: false, animate: false}
  }
  if (wantOpen === false) {
    if (state === PANEL_OPENING || state === PANEL_OPEN) {
      return {state: PANEL_CLOSING, hidden: false, animate: true}
    }
    return {state, hidden: hiddenFor(state), animate: false}
  }
  return {state, hidden: hiddenFor(state), animate: false}
}

// A settle completes exactly ONCE: only a panel that is actually opening (→
// `open`) or closing (→ `closed`) finishes, so a duplicated `animationend`
// after the fallback timer — or a timer after the event — is inert, and a
// late event can never hide a panel that was re-opened meanwhile.
function completePanelSettle(state) {
  if (state === PANEL_OPENING) return {state: PANEL_OPEN, hidden: false}
  if (state === PANEL_CLOSING) return {state: PANEL_CLOSED, hidden: true}
  return null
}

// Only a live entry/exit has anything to wait for, and `prefers-reduced-motion:
// reduce` strips the animation entirely (the global backstop in motion.css
// shrinks it to an unobservable .01 ms), so such a settle completes in the same
// task instead of waiting for an animationend that may never arrive.
function settleWaitsForAnimation(state, reducedMotion) {
  return (state === PANEL_OPENING || state === PANEL_CLOSING) && !reducedMotion
}

// The animation belongs to the PANEL ROOT itself (motion.css section 4), so the
// target check is required: a child's own animation (a spinner, a nested
// disclosure) bubbles its `animationend` up through the panel and must never
// settle it — that would hide a panel mid-exit or finish an entry early.
function isPanelSettleAnimationEnd(state, eventTarget, root) {
  return (
    (state === PANEL_OPENING || state === PANEL_CLOSING) &&
    Boolean(root) &&
    eventTarget === root
  )
}
// MotionPanel hook:

export {PANEL_WANT_ATTR, PANEL_STATE_ATTR, PANEL_OPENING, PANEL_OPEN, PANEL_CLOSING,
  PANEL_CLOSED, PANEL_SETTLE_FALLBACK_MS, wantedOpen, hiddenFor, initialPanelState,
  planPanelChange, completePanelSettle, settleWaitsForAnimation,
  isPanelSettleAnimationEnd}
