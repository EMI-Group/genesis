// Desktop title bar hook: drives the strip a Tauri window shows above the
// dashboard (`#desktop-titlebar`), which the server only renders when it
// detected desktop mode.
//
// The CLIENT is never the visibility authority: the strip is always visible and
// `data-desktop` on `#app-layout` is never touched, because a missing Tauri
// handle must not leave a chrome-less desktop window (that regression hid the
// strip while the shell had already dropped its native decorations). A missing
// handle keeps the strip visible but INERT and logs loudly.
//
// DOM contract (the Elixir side owns the markup; this hook only reads it):
//   * the hook mounts on `#desktop-titlebar[data-os="macos|windows|linux|unknown"]`;
//     there is NO `data-tauri-drag-region` any more — the hook owns dragging
//     (one `pointerdown` → `startDragging()`, one `dblclick` → `toggleMaximize()`)
//     for every non-interactive target, which naturally covers the
//     `.desktop-titlebar-drag` spacer as a child of the strip.
//   * `#desktop-titlebar-minimize`, `#desktop-titlebar-maximize` (carrying the
//     `.desktop-titlebar-glyph-maximize` / `.desktop-titlebar-glyph-restore`
//     SVGs, the restore one starting with the `hidden` class) and
//     `#desktop-titlebar-close` are rendered on EVERY OS except macOS, an
//     unknown OS included — macOS keeps its native traffic lights.
//   * close calls the window's `close()`: the Rust shell intercepts
//     `CloseRequested` and hides to the tray, so it is NEVER a quit.
//   * frameless chrome is requested by the DASHBOARD, only after the strip is
//     live: `set_custom_titlebar {active: true}` once the handle is acquired and
//     every listener is bound, and `{active: false}` on `pagehide`,
//     `beforeunload` or teardown so native OS chrome comes back.
// The OS comes from the server-rendered `data-os`; `window.__TAURI__.os` is not
// available in the dashboard and must never be used.

// --- DesktopTitlebar: pure chrome decision
// The ONE place the OS/window-state → chrome decision lives. Total and
// side-effect free so `desktop_titlebar.test.cjs` can run this block through
// node:vm.
//   * `visible` is ALWAYS true: the server only renders the strip in desktop
//     mode, so hiding it (and dropping `data-desktop`, and with it the reserved
//     `--shell-titlebar-h`) from the client is the regression, never a fix.
//   * `interactive` says whether window IPC is available (`isTauri === true`,
//     strictly — no truthiness coercion).
//   * `controls` is minimize / maximize-or-restore / close for EVERY OS that is
//     not exactly "macos" (an unknown or missing OS is a windowed OS, never a
//     control-less one); macOS keeps its native traffic lights, so it gets none.
//   * `maxLabel` mirrors the middle control ("maximize" or "restore"), the
//     English label the server also renders.
const INTERACTIVE_TAGS = ["A", "BUTTON", "INPUT", "SELECT", "TEXTAREA", "LABEL", "SUMMARY"]
const INTERACTIVE_ROLES = ["button", "link", "menuitem", "tab", "checkbox", "radio", "switch", "option"]

function chromeState(state = {}) {
  const {isTauri, os, isMaximized} = state || {}
  const visible = true
  const interactive = isTauri === true
  const middle = isMaximized === true ? "restore" : "maximize"
  const controls = os === "macos" ? [] : ["minimize", middle, "close"]
  return {visible, interactive, controls, maxLabel: middle}
}

// Pure: should a primary-button press on `el` start a window drag? True only
// when neither `el` nor ANY ancestor is interactive, so a press on a control
// (or on a link/input inside the strip) keeps its native behaviour. Duck-typed
// on purpose — it runs in node:vm with no DOM.
function isDragTarget(el) {
  if (!el || typeof el !== "object" || !el.tagName) return false
  let node = el
  while (node && node.tagName) {
    if (INTERACTIVE_TAGS.includes(String(node.tagName).toUpperCase())) return false
    if (node.isContentEditable === true) return false
    if (typeof node.getAttribute === "function") {
      const contentEditable = node.getAttribute("contenteditable")
      if (contentEditable !== null && contentEditable !== undefined && String(contentEditable).toLowerCase() !== "false") {
        return false
      }
      const tabindex = node.getAttribute("tabindex")
      if (tabindex !== null && tabindex !== undefined) {
        const value = String(tabindex).trim() === "" ? 0 : Number(tabindex)
        if (!Number.isNaN(value) && value >= 0) return false
      }
      const role = node.getAttribute("role")
      if (role !== null && role !== undefined && INTERACTIVE_ROLES.includes(String(role).toLowerCase())) return false
    }
    node = node.parentElement
  }
  return true
}
// DesktopTitlebar hook:

const MAXIMIZE_DEBOUNCE_MS = 50

const CUSTOM_TITLEBAR_COMMAND = "set_custom_titlebar"

// The English labels the server renders on the maximize control; the hook only
// swaps between these two, never to a translated string (gettext lives in HEEx).
const CONTROL_LABELS = {maximize: "Maximize", restore: "Restore"}

const CONTROL_IDS = {
  minimize: "desktop-titlebar-minimize",
  maximize: "desktop-titlebar-maximize",
  close: "desktop-titlebar-close"
}

const MAXIMIZE_GLYPH = ".desktop-titlebar-glyph-maximize"
const RESTORE_GLYPH = ".desktop-titlebar-glyph-restore"
const HIDDEN_CLASS = "hidden"
const BOUND_FLAG = "titlebarBound"

const DesktopTitlebar = {
  mounted() {
    if (!this.el) return
    this._inactive = false
    // Idempotent across LiveView re-mounts and patch-driven re-renders: the
    // dataset flag is the ONLY guard, so handlers are never double-bound.
    if (this.el.dataset[BOUND_FLAG] === "true") {
      // An earlier instance already owns this element: stay inert instead of
      // double-binding or clobbering its maximized reflection.
      this._inactive = true
      return
    }

    this._listeners = []
    this._unlisten = null
    this._unlistenPromise = null
    this._maxTimer = null
    this._win = null
    this._os = this.el.dataset.os || "unknown"
    this._maximized = false
    this._disposed = false
    this._chromeRequested = false
    this._pageHideHandler = null

    const win = this._currentWindow()
    if (!win) {
      // NEVER hide the strip and NEVER drop `data-desktop`: without a handle the
      // window keeps its native decorations, and a hidden strip would leave the
      // user with no chrome at all (an unclosable, unmovable desktop window).
      console.error(
        "[desktop-titlebar] no Tauri window handle: the title bar strip stays visible but inert and the native OS chrome remains (stale shell build?). " +
          "Rebuild the desktop shell to get a frameless title bar with window controls."
      )
      return
    }

    const state = chromeState({isTauri: true, os: this._os, isMaximized: false})
    this._win = win
    this.el.dataset[BOUND_FLAG] = "true"

    // Only the controls this OS actually renders are wired; a missing button is
    // a no-op, and the middle control is ONE toggle button either way.
    if (state.controls.includes("minimize")) {
      this._bindControl("minimize", () => this._win.minimize())
    }
    if (state.controls.includes("maximize")) {
      this._bindControl("maximize", () => this._win.toggleMaximize())
    }
    if (state.controls.includes("close")) {
      this._bindControl("close", () => this._win.close())
    }

    // The hook owns window dragging now (the markup carries no
    // `data-tauri-drag-region`).
    this._bindDrag()

    this._watchResized()
    this._refreshMaximized()
    // Frameless chrome is requested by the dashboard, and only once the strip is
    // live — a failure here leaves the native title bar in place (safe).
    this._requestFrameless()
    this._bindPageHide()
  },
  updated() {
    if (!this.el || this._inactive) return
    // A patch can rewrite the server-rendered markup (the glyph classes,
    // data-maximized, aria-label/title); re-assert the last known state instead
    // of re-binding anything.
    if (this.el.dataset[BOUND_FLAG] !== "true") return
    this._applyMaximized(this._maximized)
  },
  destroyed() {
    if (this._inactive) return
    this.teardown()
  },

  _currentWindow() {
    // Same detection as the TauriDetect hook (app.js) and DesktopQuit.
    const isTauri = !!(window.__TAURI__ || window.__TAURI_OS_INTERNALS__)
    if (!isTauri) return null
    const tauriWindow = window.__TAURI__ && window.__TAURI__.window
    const getCurrentWindow = tauriWindow && tauriWindow.getCurrentWindow
    if (typeof getCurrentWindow !== "function") {
      console.error("[desktop-titlebar] window.__TAURI__.window.getCurrentWindow unavailable")
      return null
    }
    try {
      return getCurrentWindow.call(tauriWindow) || null
    } catch (err) {
      console.error("[desktop-titlebar] failed to acquire the current window handle:", err)
      return null
    }
  },

  // ONE place that registers a DOM listener, so teardown releases every one.
  _listen(target, type, handler) {
    if (!target || typeof target.addEventListener !== "function") return
    target.addEventListener(type, handler)
    this._listeners.push({target, type, handler})
  },

  _bindControl(name, call) {
    const button = this.el.querySelector(`#${CONTROL_IDS[name]}`)
    if (!button) return
    const handler = (event) => {
      if (event) event.preventDefault()
      this._invoke(name, call)
    }
    this._listen(button, "click", handler)
  },

  // Dragging and double-click-to-zoom both live on the strip root so the
  // `.desktop-titlebar-drag` spacer is covered as a child; `isDragTarget/1`
  // keeps interactive descendants out of both. No `preventDefault()` on the
  // press — that would break text selection in inputs.
  _bindDrag() {
    this._listen(this.el, "pointerdown", (event) => {
      if (!event || event.button !== 0) return
      if (!isDragTarget(event.target)) return
      this._invoke("startDragging", () => this._win.startDragging())
    })
    this._listen(this.el, "dblclick", (event) => {
      if (!event || !isDragTarget(event.target)) return
      this._invoke("toggleMaximize", () => this._win.toggleMaximize())
    })
  },

  // Every IPC call is wrapped: a rejection or a synchronous throw is logged
  // loudly instead of becoming a silent dead button.
  _invoke(name, call) {
    let result
    try {
      result = call()
    } catch (err) {
      console.error(`[desktop-titlebar] ${name} threw:`, err)
      return
    }
    if (result && typeof result.then === "function") {
      result.then(undefined, (err) => console.error(`[desktop-titlebar] ${name} failed:`, err))
    }
  },

  // `set_custom_titlebar {active: true}` tells the Rust shell to go frameless;
  // without the command (stale shell build) the native title bar simply stays —
  // never throw, never retry.
  _invokeChrome(active) {
    const core = window.__TAURI__ && window.__TAURI__.core
    const invoke = core && core.invoke
    if (typeof invoke !== "function") {
      console.error(
        `[desktop-titlebar] window.__TAURI__.core.invoke unavailable: cannot request ${CUSTOM_TITLEBAR_COMMAND} (active: ${active}) — stale shell build? The native title bar stays.`
      )
      return
    }
    this._invoke(`core.invoke ${CUSTOM_TITLEBAR_COMMAND}`, () => invoke.call(core, CUSTOM_TITLEBAR_COMMAND, {active}))
  },

  // Only ever one `true` request per instance; `_chromeRequested` is what makes
  // teardown / pagehide send `false` at most once, and only after a real `true`.
  _requestFrameless() {
    if (this._chromeRequested) return
    this._chromeRequested = true
    this._invokeChrome(true)
  },

  _releaseFrameless() {
    if (!this._chromeRequested) return
    this._chromeRequested = false
    this._invokeChrome(false)
  },

  // The shell must restore native OS chrome when the page goes away, otherwise
  // the next window can be left frameless with no dashboard to ask again.
  _bindPageHide() {
    if (typeof window.addEventListener !== "function") return
    const handler = () => this._releaseFrameless()
    this._pageHideHandler = handler
    window.addEventListener("pagehide", handler)
    window.addEventListener("beforeunload", handler)
  },

  _watchResized() {
    if (typeof this._win.onResized !== "function") {
      console.error("[desktop-titlebar] window.onResized unavailable: maximized state will not follow window resizes")
      return
    }
    let promise
    try {
      promise = this._win.onResized(() => this._scheduleMaximizeRefresh())
    } catch (err) {
      console.error("[desktop-titlebar] failed to subscribe to window resize events:", err)
      return
    }
    this._unlistenPromise = promise
    if (!promise || typeof promise.then !== "function") return
    promise.then(
      (unlisten) => {
        // If the hook was destroyed before the promise resolved, unlisten right
        // away; otherwise keep the unlisten for teardown().
        if (this._unlistenPromise) {
          this._unlisten = unlisten
        } else if (typeof unlisten === "function") {
          unlisten()
        }
      },
      (err) => console.error("[desktop-titlebar] failed to subscribe to window resize events:", err)
    )
  },

  // ~50 ms trailing debounce: a drag-resize fires a burst of onResized events.
  _scheduleMaximizeRefresh() {
    if (this._disposed) return
    if (this._maxTimer) clearTimeout(this._maxTimer)
    this._maxTimer = setTimeout(() => {
      this._maxTimer = null
      this._refreshMaximized()
    }, MAXIMIZE_DEBOUNCE_MS)
  },

  _refreshMaximized() {
    if (this._disposed || !this._win) return
    let result
    try {
      result = this._win.isMaximized()
    } catch (err) {
      console.error("[desktop-titlebar] isMaximized() threw:", err)
      return
    }
    if (result && typeof result.then === "function") {
      result.then(
        (value) => {
          if (!this._disposed) this._applyMaximized(value === true)
        },
        (err) => console.error("[desktop-titlebar] isMaximized() failed:", err)
      )
    } else {
      this._applyMaximized(result === true)
    }
  },

  // Reflects the maximized state on `#desktop-titlebar-maximize`: ONE toggle
  // button whose two glyphs and label swap. Defensive throughout — a missing
  // button or glyph leaves the rest untouched.
  _applyMaximized(isMaximized) {
    this._maximized = isMaximized === true
    const state = chromeState({isTauri: true, os: this._os, isMaximized: this._maximized})
    const button = this.el && this.el.querySelector(`#${CONTROL_IDS.maximize}`)
    if (!button) return

    const restoring = state.maxLabel === "restore"
    const maximizeGlyph = button.querySelector(MAXIMIZE_GLYPH)
    if (maximizeGlyph) maximizeGlyph.classList.toggle(HIDDEN_CLASS, restoring)
    const restoreGlyph = button.querySelector(RESTORE_GLYPH)
    if (restoreGlyph) restoreGlyph.classList.toggle(HIDDEN_CLASS, !restoring)

    button.dataset.maximized = restoring ? "true" : "false"
    const label = CONTROL_LABELS[state.maxLabel] || CONTROL_LABELS.maximize
    button.setAttribute("aria-label", label)
    button.setAttribute("title", label)
  },

  teardown() {
    this._disposed = true
    if (this._maxTimer) {
      clearTimeout(this._maxTimer)
      this._maxTimer = null
    }
    ;(this._listeners || []).forEach(({target, type, handler}) => {
      if (target && typeof target.removeEventListener === "function") {
        target.removeEventListener(type, handler)
      }
    })
    this._listeners = []
    // Safe if the resize subscription has not resolved yet: nulling the
    // promise makes its then-callback unlisten immediately instead of storing.
    this._unlistenPromise = null
    if (this._unlisten) {
      this._unlisten()
      this._unlisten = null
    }
    if (this._pageHideHandler && typeof window !== "undefined" && typeof window.removeEventListener === "function") {
      window.removeEventListener("pagehide", this._pageHideHandler)
      window.removeEventListener("beforeunload", this._pageHideHandler)
    }
    this._pageHideHandler = null
    // Native chrome comes back only when a `true` request actually went out.
    this._releaseFrameless()
    if (this.el && this.el.dataset[BOUND_FLAG] === "true") {
      delete this.el.dataset[BOUND_FLAG]
    }
    this._win = null
  }
}

export {DesktopTitlebar, chromeState, isDragTarget}
export default DesktopTitlebar
