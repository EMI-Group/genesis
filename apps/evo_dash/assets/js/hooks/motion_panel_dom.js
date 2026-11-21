// The DOM half of the `motion-panel` / `data-motion-state` recipe.
// `motion_panel.js` decides WHAT the server's intent does to a panel; this
// module is the ONLY writer of `data-motion-state` and of the `hidden` frame —
// it owns the per-element state, arms ONE settle per element (the entry or the
// exit) and repairs server markup in the same task a patch lands.
// The block between the markers below runs against a small fake root in
// `motion_panel_dom.test.cjs` (sliced out and evaluated in node:vm with
// `setTimeout`/`clearTimeout` stubs), the workbench_panel_dom.test.cjs
// convention — which is why the block itself imports nothing: every decision it
// needs already lives in the pure block above it, and the two imports under it
// are outside the slice.
import {PANEL_WANT_ATTR, PANEL_STATE_ATTR, PANEL_OPENING, PANEL_CLOSING, wantedOpen,
  initialPanelState, planPanelChange, completePanelSettle, settleWaitsForAnimation,
  isPanelSettleAnimationEnd, PANEL_SETTLE_FALLBACK_MS} from "./motion_panel"
import {prefersReducedMotion} from "./disclosure_motion"

// --- MotionPanel DOM writer: intent → state, one armed settle per element
// Per-element state lives in Maps, NOT in the DOM, and that is the whole stale
// guard: a LiveView patch puts the server markup back (`hidden` from the
// intent, `data-motion-state` possibly stripped), but during a settle the
// hook's own state and `hidden` win — the re-assert at the bottom of `apply`
// repairs the element in the same task, so nothing collapsed ever paints and a
// patch can never cut an exit short.
// A CSS ANIMATION needs no starting frame (unlike the workbench panel's
// transition): writing the state attribute starts the keyframes in that same
// frame, whether the panel was just un-hidden or was already displayed.
function createPanelWriter(reducedMotion = () => false) {
  const states = new Map()
  const settles = new Map()

  const readAttr = (el, name) =>
    typeof el.getAttribute === "function" ? el.getAttribute(name) : null

  const setState = (el, state) => {
    if (typeof el.setAttribute !== "function") return
    // Equality-guarded: an unchanged state is a pure re-assert and must not
    // restart a keyframe animation (or fight the browser) either.
    if (el.getAttribute(PANEL_STATE_ATTR) !== state) el.setAttribute(PANEL_STATE_ATTR, state)
  }

  const setHidden = (el, hidden) => {
    if (el.hidden !== hidden) el.hidden = hidden
  }

  const clearSettle = el => {
    const pending = settles.get(el)
    if (!pending) return
    clearTimeout(pending.timer)
    if (typeof el.removeEventListener === "function") el.removeEventListener("animationend", pending.onEnd)
    settles.delete(el)
  }

  // Exactly-once completion: `completePanelSettle` returns null for anything
  // that is not mid-settle, so a duplicated event, the fallback timer after the
  // event, or a stale captured callback applies nothing (and cannot hide a
  // panel another request already re-opened).
  const finishSettle = el => {
    clearSettle(el)
    const done = completePanelSettle(states.get(el))
    if (!done) return false
    states.set(el, done.state)
    // `hidden` is ONLY written here for a close: the exit needs the panel
    // displayed for its whole animation.
    setHidden(el, done.hidden)
    setState(el, done.state)
    return true
  }

  const armSettle = el => {
    const onEnd = event => {
      if (isPanelSettleAnimationEnd(states.get(el), event && event.target, el)) finishSettle(el)
    }
    const timer = setTimeout(() => finishSettle(el), PANEL_SETTLE_FALLBACK_MS)
    if (typeof el.addEventListener === "function") el.addEventListener("animationend", onEnd)
    settles.set(el, {onEnd, timer})
  }

  // One settle per element: a second request while one is armed re-uses it
  // instead of stacking a second listener/timer, and reduced motion (where no
  // animationend will ever arrive) completes in this task.
  const beginSettle = el => {
    if (settles.has(el)) return
    if (settleWaitsForAnimation(states.get(el), reducedMotion())) armSettle(el)
    else finishSettle(el)
  }

  const apply = el => {
    const want = wantedOpen(readAttr(el, PANEL_WANT_ATTR))
    if (!states.has(el)) states.set(el, initialPanelState(want).state)
    const plan = planPanelChange(states.get(el), want)

    if (plan.state !== states.get(el)) {
      // A re-plan always cancels what was armed: a re-entrant open while
      // closing continues from its live interpolated frame, so it needs no
      // starting frame and no second entry.
      clearSettle(el)
      states.set(el, plan.state)
    }

    setHidden(el, plan.hidden)
    setState(el, plan.state)
    // An unchanged state never re-arms (the armed settle, or the completed
    // one, stays exactly as it is); a fresh entry/exit arms ONE settle.
    if (plan.state === PANEL_OPENING || plan.state === PANEL_CLOSING) beginSettle(el)
    return plan
  }

  return {
    apply,
    destroy() {
      for (const el of [...settles.keys()]) clearSettle(el)
      states.clear()
    },
  }
}

// end MotionPanel DOM writer

// The LiveView hook: ONE writer per hook instance, re-applied on every patch
// because `data-motion-want` is the server's intent and may have flipped.
const MotionPanel = {
  mounted() {
    this.writer = createPanelWriter(() => prefersReducedMotion())
    this.writer.apply(this.el)
  },

  updated() {
    if (this.writer) this.writer.apply(this.el)
  },

  destroyed() {
    if (!this.writer) return
    this.writer.destroy()
    this.writer = null
  },
}

export {createPanelWriter}
export default MotionPanel
