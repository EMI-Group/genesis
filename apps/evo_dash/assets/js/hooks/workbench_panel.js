// The pure decision half of the workbench right panel (project history and
// project Git share the shape). The DOM half lives in workbench_panel_dom.js;
// everything between the markers below is total and side-effect free, so
// `workbench_panel.test.cjs` can run THIS source through node:vm with no
// browser and no build step (the agent_history_scroll.test.cjs convention).

// --- WorkbenchPanel: pure right-panel state machine
// States: "closed" (the aside carries `hidden`) | "open" | "closing" (the exit
// animation runs and `hidden` is already absent).
const PANEL_CLOSED = "closed"
const PANEL_OPEN = "open"
const PANEL_CLOSING = "closing"
// Bounded fallback so a close whose transform transition never fires (hidden
// tab, zero-duration transition, interrupted animation) still reaches closed.
const PANEL_CLOSE_FALLBACK_MS = 300
const PANEL_TRANSITION_PROPERTY = "transform"

// A fresh tab stores no preference and starts CLOSED on every breakpoint; only
// an explicit `true` — the user opened the panel in this tab — starts open.
function initialPanelState(preference) {
  return preference === true ? PANEL_OPEN : PANEL_CLOSED
}

// What a user request does to the panel. `cancelClose` marks the re-entrant
// open-while-closing case: the pending hidden-marking is dropped, never raced,
// and the panel continues from its live interpolated style (no starting frame).
// `animate` is true only when a transition needs a freshly painted start.
function planPanelRequest(state, open) {
  if (open) {
    return {
      state: PANEL_OPEN,
      hidden: false,
      cancelClose: state === PANEL_CLOSING,
      animate: state === PANEL_CLOSED,
    }
  }
  if (state === PANEL_OPEN || state === PANEL_CLOSING) {
    return {state: PANEL_CLOSING, hidden: false, cancelClose: false, animate: true}
  }
  return {state: PANEL_CLOSED, hidden: true, cancelClose: false, animate: false}
}

// A close completes exactly ONCE: only a panel that is actually closing reaches
// closed. Anything else (already closed, re-opened meanwhile) is a no-op.
function completePanelClose(state) {
  return state === PANEL_CLOSING ? {state: PANEL_CLOSED, hidden: true} : null
}

// The exit animates transform, opacity and flex-basis together, so each property
// fires its own transitionend; ONLY the transform end may finish the close.
function isPanelCloseTransition(state, propertyName) {
  return state === PANEL_CLOSING && propertyName === PANEL_TRANSITION_PROPERTY
}

// `prefers-reduced-motion: reduce` removes the CSS transition, so there is no
// transitionend to wait for: such a close completes in the same task.
function panelCloseWaitsForTransition(animate, reducedMotion) {
  return Boolean(animate) && !reducedMotion
}

// The OPEN transition needs a RESOLVED starting frame. The panel arrives
// `display: none` (the server renders the aside `hidden`), so its last computed
// style is "not rendered": a style change applied together with the un-hide
// would be the element's FIRST style, and CSS starts no transition from no
// previous style. The DOM half therefore forces one style+layout pass at the
// collapsed geometry while the panel is displayed, then flips it to open.
// Reduced motion removes the CSS transition, so there is nothing to start: such
// an open is applied in this same task and nothing collapsed ever paints.
// `animate` is false for the mount/resize seed, and for a re-entrant open while
// the panel is still closing (it is displayed at a live interpolated style,
// which is its own start value).
function panelOpenNeedsStartFrame(animate, reducedMotion) {
  return Boolean(animate) && !reducedMotion
}
// WorkbenchPanel hook:

export {PANEL_CLOSED, PANEL_OPEN, PANEL_CLOSING, PANEL_CLOSE_FALLBACK_MS,
  PANEL_TRANSITION_PROPERTY, initialPanelState, planPanelRequest, completePanelClose,
  isPanelCloseTransition, panelCloseWaitsForTransition, panelOpenNeedsStartFrame}
