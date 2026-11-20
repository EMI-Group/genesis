// The shared MOTION FOUNDATION for the dashboard's exits: one opt-in
// <details> hook plus the reusable close primitive every `:if`-mounted or
// <dialog> performer reuses.
//
// Native <details> cannot animate its exit. Removing `open` — which is what a
// summary click does — tears the content out of the layout in the SAME frame,
// so there is nothing left to animate. This hook is the only thing that defers
// that removal: it sets data-disclosure-state="closing" (the attribute
// assets/css/motion.css gates the 120 ms exit keyframes off), then removes
// `open` once the exit finished — on `animationend` for the panel itself, or on
// the bounded fallback when no animation ever fires.
//
// No CSS and no motion timing lives here: durations, easings and keyframes are
// motion.css's; JS only decides WHEN an exit is over. Opening stays the
// CSS-only path (`details.motion-disclosure[open] > :not(summary)` animates
// entry from the attribute the browser already toggles).

// --- DisclosureMotion: pure close decisions (unit-tested)
// Bounded fallback: an unrendered / zero-content panel fires no animationend at
// all (and an OS or browser that suppresses animations fires none either), so
// the close still has to complete. 0 < x <= 500 keeps it invisible beside the
// 120 ms exit keyframes and the 220 ms slow token.
const DISCLOSURE_CLOSE_FALLBACK_MS = 200
// The attribute the exit keyframes are gated on. Attribute (not class) on
// purpose: a closing panel can still receive re-renders, and morphdom merges
// classes but leaves an attribute the server never renders alone until a patch
// rewrites the element.
const DISCLOSURE_STATE_ATTR = "data-disclosure-state"
const DISCLOSURE_CLOSING = "closing"

// ONE guarded matchMedia call for the whole dashboard (assets/js/dialog_modal.js
// reaches this same helper through the bridge at the bottom of this file). An
// environment without matchMedia — including the node:vm slices the unit tests
// run in — has no reduced-motion preference.
function prefersReducedMotion(win = globalThis.window) {
  return typeof win?.matchMedia === "function"
    ? win.matchMedia("(prefers-reduced-motion: reduce)").matches
    : false
}

// Only an animationend whose TARGET is the panel itself may finish an exit: a
// child element's animation (a nested disclosure, a spinner) bubbles its own
// animationend up, and a native dialog's ::backdrop animation is dispatched at
// the dialog, not at the .modal-box panel. Either could otherwise cut the exit
// short — or finish a close that has not started.
function isPanelAnimationEnd(state, eventTarget, panel) {
  return state === DISCLOSURE_CLOSING && Boolean(panel) && eventTarget === panel
}

// Wait for the exit animation only when there IS one to wait for: reduced
// motion removes it, a missing/blank panel renders nothing to animate, and a
// close that is already running is completed instead of re-armed.
function closeWaitsForAnimation({reduced, panelPresent, closing} = {}) {
  return !reduced && Boolean(panelPresent) && !closing
}
// DisclosureMotion: DOM orchestration + hook

// ONE close per root: a second request while the exit runs completes the SAME
// close (and adds its completion callback) instead of arming a second listener
// and timer, so exactly ONE teardown ever happens however many clicks, events
// or timers arrive.
const pendingCloses = new WeakMap()

// Native close() is what emits a <dialog>'s own "close" event, so a window whose
// listener resets state on close must go through it; everything else (a
// <details>, a plain element) just loses the attribute.
function releaseOpen(root) {
  if (root.open === true && typeof root.close === "function") {
    try {
      root.close()
    } catch (_error) {
      // Broken/partial WebView dialog API: dropping `open` still releases it.
    }
  }
  if (typeof root.removeAttribute === "function") root.removeAttribute("open")
}

// Plays an element's CSS exit (gated on `attr="closing"`) and then releases it.
// Idempotent: the completion runs once, synchronously when there is nothing to
// wait for (reduced motion, no panel, a close already running).
function closeAnimated(root, {panel, attr = DISCLOSURE_STATE_ATTR,
  fallbackMs = DISCLOSURE_CLOSE_FALLBACK_MS, onComplete} = {}) {
  if (!root) return

  const running = pendingCloses.get(root)
  if (running) {
    if (typeof onComplete === "function") running.completers.push(onComplete)
    running.complete()
    return
  }

  const target = panel && typeof panel.addEventListener === "function" ? panel : null
  const closing = typeof root.getAttribute === "function" && root.getAttribute(attr) === DISCLOSURE_CLOSING
  let timer = null
  let onEnd = null

  const close = {completers: typeof onComplete === "function" ? [onComplete] : []}
  close.complete = () => {
    if (pendingCloses.get(root) !== close) return // Already finished / superseded.
    pendingCloses.delete(root)
    if (timer !== null) {
      clearTimeout(timer)
      timer = null
    }
    if (target && onEnd) target.removeEventListener("animationend", onEnd)
    onEnd = null
    if (typeof root.removeAttribute === "function") root.removeAttribute(attr)
    releaseOpen(root)
    for (const done of close.completers) done()
    close.completers = []
  }

  // Registered BEFORE any synchronous completion so `complete` finds itself.
  pendingCloses.set(root, close)

  if (!closeWaitsForAnimation({
    reduced: prefersReducedMotion(),
    panelPresent: Boolean(target),
    closing,
  })) {
    close.complete() // Same task: no animationend will ever arrive.
    return
  }

  if (typeof root.setAttribute === "function") root.setAttribute(attr, DISCLOSURE_CLOSING)
  onEnd = event => {
    if (isPanelAnimationEnd(DISCLOSURE_CLOSING, event && event.target, target)) close.complete()
  }
  target.addEventListener("animationend", onEnd)
  timer = setTimeout(() => close.complete(), Math.max(0, fallbackMs))
}

const DisclosureMotion = {
  mounted() {
    this.onClick = event => this.handleClick(event)
    this.el.addEventListener("click", this.onClick)
  },

  // LiveView patches re-render the <details>. `open` belongs to the browser (and
  // to the server's markup), never to this hook, so a patch is left alone: no
  // re-arming, no re-assertion, nothing that could fight the user's toggle.
  updated() {},

  destroyed() {
    if (!this.el) return
    this.el.removeEventListener("click", this.onClick)
    this.onClick = null
    // Release a running exit (its listener and its timer) with the element — it
    // is leaving the DOM, so the close simply completes now.
    if (this.el.getAttribute(DISCLOSURE_STATE_ATTR) === DISCLOSURE_CLOSING) {
      closeAnimated(this.el, {panel: this.panel(), fallbackMs: 0})
    }
  },

  // Only a click on the element's OWN summary while it is open is intercepted.
  // Opening stays native (the CSS entry keyframes key off `[open]`), a nested
  // disclosure's summary keeps its own toggle, and the browser's keyboard
  // activation of a summary arrives here as the same click — so Enter/Space
  // still close, they just close animated.
  handleClick(event) {
    const summary = event?.target?.closest?.("summary")
    if (!summary || summary !== this.rootSummary()) return
    if (!this.el.open) return
    if (this.el.getAttribute(DISCLOSURE_STATE_ATTR) === DISCLOSURE_CLOSING) return
    event.preventDefault()
    closeAnimated(this.el, {panel: this.panel()})
  },

  rootSummary() {
    return this.el.querySelector(":scope > summary")
  },

  panel() {
    return this.el.querySelector(":scope > :not(summary)") || this.el
  }
}

// ONE shared motion bridge: assets/js/dialog_modal.js is unit-tested through
// node:vm, which parses its source as a CLASSIC script, so that module cannot
// statically import this one. Publishing the helpers here (the same documented
// side-effect contract highlight_setup.js uses for window.hljs, and evaluated
// before any host markup runs because app.js imports this module) keeps the
// matchMedia guard defined exactly once.
if (typeof globalThis !== "undefined") {
  globalThis.genesisMotion = {prefersReducedMotion, closeAnimated}
}

export {DISCLOSURE_CLOSE_FALLBACK_MS, DISCLOSURE_STATE_ATTR, DISCLOSURE_CLOSING,
  prefersReducedMotion, isPanelAnimationEnd, closeWaitsForAnimation, closeAnimated}
export default DisclosureMotion
