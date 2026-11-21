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
//
// `open` stays browser-native and this hook only OWNS it for the surfaces whose
// markup renders it from server state (the Settings provider account's
// "Advanced" disclosure). There a patch would otherwise morph the content away
// instantly, so `updated()` reconciles after every patch: it re-asserts the
// previous frame in the SAME task while our exit runs (or plays that exit when
// the server closed what we believe is open), and it drops a stale server
// `open` while the server catches up with the user's close.

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

// --- DisclosureMotion: pure server-`open` reconcile decisions (unit-tested)
// A `toggle` listener keeps `wantOpen` (the hook's own intent) current, so the
// plan below answers one question per patch: may this patch change `open`, or
// must the previous frame survive the task?
//   "none"            — server and hook agree, or a running exit already
//                       settled the intent (it removes `open` itself).
//   "readd"           — mid-exit and the patch already dropped `open`: keep the
//                       frame so the exit keyframe can finish.
//   "readd-and-close" — the server closed a disclosure the hook believes is
//                       open: re-assert `open`, then play the exit instead of
//                       snapping the content away.
//   "drop"            — a stale server `open` for a hook that is closed (the
//                       close round-trip has not landed yet): client intent wins
//                       until the server catches up.
// Pure and total: no DOM, no timers, missing/garbage input reads as "closed".
function planOpenReconcile({domOpen, wantOpen, closing} = {}) {
  const dom = domOpen === true
  const want = wantOpen === true

  // A running exit owns `open` until `closeAnimated` settles it — whatever the
  // patch rendered, the intent is already closed.
  if (closing === true) return {wantOpen: false, action: dom ? "none" : "readd"}

  if (dom === want) return {wantOpen: want, action: "none"}
  if (!want) return {wantOpen: false, action: "drop"}

  return {wantOpen: false, action: "readd-and-close"}
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
    // The hook's own intent, seeded from the rendered `open` (a server-owned
    // disclosure can arrive open) and then kept current by the two listeners.
    this.wantOpen = this.el.open === true
    this.onClick = event => this.handleClick(event)
    // A native change of `open` — the browser's toggle, keyboard activation, or
    // our own releaseOpen — is the intent's truth. Never while OUR exit runs:
    // closeAnimated settles that one itself.
    this.onToggle = () => {
      if (!pendingCloses.has(this.el)) this.wantOpen = this.el.open === true
    }
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("toggle", this.onToggle)
  },

  // LiveView patches re-render the <details>. For a browser-owned disclosure the
  // server never writes `open`, so the plan is always "none" and a patch can
  // never fight the user's toggle. Where the SERVER owns `open` (the Settings
  // provider "Advanced" disclosure) the patch is reconciled instead: a mid-exit
  // frame is re-asserted so the exit can finish, a server close is animated
  // rather than snapped, and a stale server re-open is dropped.
  updated() {
    const el = this.el
    // Leaving the DOM: nothing to keep a frame for (destroyed() releases it).
    if (!el || el.isConnected === false) return

    const plan = planOpenReconcile({
      domOpen: el.open === true,
      wantOpen: this.wantOpen === true,
      closing: el.getAttribute(DISCLOSURE_STATE_ATTR) === DISCLOSURE_CLOSING,
    })
    this.wantOpen = plan.wantOpen

    if (plan.action === "readd") {
      // SAME task, before paint: the computed style never sees the gap, so the
      // running exit keyframe continues undisturbed.
      el.open = true
    } else if (plan.action === "readd-and-close") {
      el.open = true
      // No second close is possible: `pendingCloses` holds ONE close per root,
      // and the `closing` state (which is false here) is what excludes this arm.
      closeAnimated(el, {panel: this.panel()})
    } else if (plan.action === "drop") {
      el.open = false
    }
  },

  destroyed() {
    if (!this.el) return
    this.el.removeEventListener("click", this.onClick)
    if (this.onToggle) this.el.removeEventListener("toggle", this.onToggle)
    this.onClick = null
    this.onToggle = null
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
  // still close, they just close animated. A click runs BEFORE the native
  // toggle, so setting the intent here closes the window in which a patch could
  // see a freshly toggled `open` against a stale intent.
  handleClick(event) {
    const summary = event?.target?.closest?.("summary")
    if (!summary || summary !== this.rootSummary()) return
    if (this.el.getAttribute(DISCLOSURE_STATE_ATTR) === DISCLOSURE_CLOSING) return
    if (!this.el.open) {
      this.wantOpen = true
      return
    }
    event.preventDefault()
    this.wantOpen = false
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
  prefersReducedMotion, isPanelAnimationEnd, closeWaitsForAnimation,
  planOpenReconcile, closeAnimated}
export default DisclosureMotion
