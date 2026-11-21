// The DOM half of the workbench right panel (project history and project Git
// share the shape). `workbench_panel.js` decides WHAT a user request does; this
// module owns the per-panel state map, the forced starting frame an OPEN needs
// and the armed close, so `workbench.js` only calls `apply(panel, wantOpen)`.
// The block between the markers below runs against a small fake panel in
// `workbench_panel_dom.test.cjs` (sliced out and evaluated in node:vm with
// `setTimeout`/`clearTimeout` stubs), the agent_history_scroll.test.cjs
// convention.
import {initialPanelState, planPanelRequest, completePanelClose, isPanelCloseTransition,
  panelCloseWaitsForTransition, panelOpenNeedsStartFrame, PANEL_CLOSED, PANEL_OPEN,
  PANEL_CLOSING, PANEL_CLOSE_FALLBACK_MS} from "./workbench_panel"

// --- WorkbenchPanel DOM host: per-panel state, forced start frame, armed close
// The aside arrives from the server `display: none` (rendered with `hidden`), so
// its last computed style is "not rendered". A style change applied in the SAME
// task as the un-hide would be the element's first style ever, and CSS starts no
// transition from no previous style — the panel pops in. Reading a layout
// property while the collapsed geometry is applied forces style recalc + layout,
// so the following data-panel-state change is an ordinary before → after
// computed-style change and the CSS transition runs.
// This is ONE mechanism — a synchronous flush in the same task, exactly the
// `void el.offsetWidth` convention node_switch_fade.js uses — NOT flush plus a
// frame schedule and NOT a two-frame deferral: a frame lands after that frame's
// style resolution (which is the pop-in this fixes) and would add a frame of
// delay plus a frame handle to cancel. The flush keeps the open deterministic
// and complete in the task that requested it.
function settleDisplayedLayout(panel) {
  void panel.offsetWidth
}

function createPanelHost(reducedMotion = () => false) {
  const states = new Map()
  const closes = new Map()

  const setState = (panel, state) => {
    if (panel.dataset.panelState !== state) panel.dataset.panelState = state
  }

  const clearClose = key => {
    const pending = closes.get(key)
    if (!pending) return
    clearTimeout(pending.timer)
    pending.panel.removeEventListener("transitionend", pending.onEnd)
    closes.delete(key)
  }

  const finishClose = panel => {
    const key = panel.id
    clearClose(key)
    const done = completePanelClose(states.get(key))
    if (!done) return false
    states.set(key, done.state)
    panel.hidden = done.hidden
    setState(panel, done.state)
    return true
  }

  const armClose = (panel, key) => {
    const onEnd = event => {
      if (event.target !== panel) return
      if (!isPanelCloseTransition(states.get(key), event.propertyName)) return
      finishClose(panel)
    }
    const timer = setTimeout(() => finishClose(panel), PANEL_CLOSE_FALLBACK_MS)
    panel.addEventListener("transitionend", onEnd)
    closes.set(key, {panel, onEnd, timer})
  }

  const apply = (panel, wantOpen, animate = true) => {
    const key = panel.id
    const state = states.get(key) || initialPanelState(panel.dataset.panelState === PANEL_OPEN)
    const plan = planPanelRequest(state, wantOpen)
    if (plan.state === state) {
      // An unchanged state is a pure re-assert: a LiveView patch puts the server
      // markup back (`hidden` + `data-panel-state="closed"`), and repairing it in
      // this same task means nothing collapsed ever paints and no re-entrant
      // animation starts.
      if (panel.hidden !== plan.hidden) panel.hidden = plan.hidden
      setState(panel, plan.state)
      return plan
    }
    states.set(key, plan.state)
    clearClose(key)
    if (plan.state === PANEL_OPEN) {
      panel.hidden = false
      if (animate && panelOpenNeedsStartFrame(plan.animate, reducedMotion())) {
        // Re-asserting the collapsed state is normally a no-op mutation, but the
        // flush below is what gives the transition a start value — keep both.
        setState(panel, PANEL_CLOSED)
        settleDisplayedLayout(panel)
        setState(panel, PANEL_OPEN)
      } else {
        // Seed, reduced motion, or a re-entrant open that continues from the
        // live interpolated style: applied in this task, nothing collapsed paints.
        setState(panel, PANEL_OPEN)
      }
    } else if (plan.state === PANEL_CLOSING) {
      panel.hidden = false
      setState(panel, PANEL_CLOSING)
      if (animate && panelCloseWaitsForTransition(plan.animate, reducedMotion())) {
        armClose(panel, key)
      } else {
        finishClose(panel)
      }
    } else {
      panel.hidden = true
      setState(panel, PANEL_CLOSED)
    }
    return plan
  }

  return {
    apply,
    destroy() {
      for (const key of [...closes.keys()]) clearClose(key)
      states.clear()
    },
  }
}
// end WorkbenchPanel DOM host

export {createPanelHost, settleDisplayedLayout}
