// Desktop title bar hook: drives the strip a Tauri window shows above the
// dashboard (`#desktop-titlebar`), which the server only renders when it
// detected desktop mode. A normal browser never reaches the controls: the strip
// is hidden and `data-desktop` is dropped from `#app-layout`, so
// `--shell-titlebar-h` falls back to 0 and the fixed chrome offsets keep their
// browser values.
//
// DOM contract (the Elixir side owns the markup; this hook only reads it):
//   * the hook mounts on `#desktop-titlebar[data-os="macos|windows|linux|unknown"]`;
//     the strip itself is the Tauri drag region and double-click-to-maximize
//     comes free from the shell, so the hook never wires dragging.
//   * `#desktop-titlebar-minimize`, `#desktop-titlebar-maximize` (carrying the
//     `.desktop-titlebar-glyph-maximize` / `.desktop-titlebar-glyph-restore`
//     SVGs, the restore one starting with the `hidden` class) and
//     `#desktop-titlebar-close` exist on Windows/Linux only — macOS keeps its
//     native traffic lights, so there are no controls to bind there.
//   * close calls the window's `close()`: the Rust shell intercepts
//     `CloseRequested` and hides to the tray, so it is NEVER a quit.
// The OS comes from the server-rendered `data-os`; `window.__TAURI__.os` is not
// available in the dashboard and must never be used.

// --- DesktopTitlebar: pure chrome decision
// The ONE place the OS/window-state → chrome decision lives. Total and
// side-effect free so `desktop_titlebar.test.cjs` can run this block through
// node:vm. `visible` is false without the Tauri shell; macOS and an unknown OS
// get NO window controls (macOS keeps its native traffic lights); the middle
// control of a windows/linux strip is "maximize" or "restore" and `maxLabel`
// mirrors it (the English label the server also renders).
function chromeState(state = {}) {
  const {isTauri, os, isMaximized} = state || {}
  const visible = isTauri === true
  const windowed = os === "windows" || os === "linux"
  const middle = isMaximized === true ? "restore" : "maximize"
  const controls = visible && windowed ? ["minimize", middle, "close"] : []
  return {visible, controls, maxLabel: middle}
}
// DesktopTitlebar hook:

const MAXIMIZE_DEBOUNCE_MS = 50

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

    this._controls = []
    this._unlisten = null
    this._unlistenPromise = null
    this._maxTimer = null
    this._win = null
    this._os = this.el.dataset.os || "unknown"
    this._maximized = false
    this._hidden = false
    this._disposed = false

    const win = this._currentWindow()
    const state = chromeState({isTauri: win !== null, os: this._os, isMaximized: false})
    if (!state.visible) {
      this.hide()
      return
    }

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

    this._watchResized()
    this._refreshMaximized()
  },
  updated() {
    if (!this.el || this._inactive) return
    // A patch can rewrite the server-rendered markup (the glyph classes,
    // data-maximized, aria-label/title) and re-add data-desktop; re-assert the
    // last known state instead of re-binding anything.
    if (this._hidden) {
      this.hide()
      return
    }
    if (this.el.dataset[BOUND_FLAG] !== "true") return
    this._applyMaximized(this._maximized)
  },
  destroyed() {
    if (this._inactive) return
    this.teardown()
  },

  // Outside the shell (or without a usable window handle) the strip is hidden
  // WITHOUT removing it (LiveView keeps patching it) and `data-desktop` is
  // dropped so `--shell-titlebar-h` falls back to 0 — no leftover layout gap.
  hide() {
    this._hidden = true
    if (this.el) this.el.style.display = "none"
    const layout = document.getElementById("app-layout")
    if (layout) layout.removeAttribute("data-desktop")
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

  _bindControl(name, call) {
    const button = this.el.querySelector(`#${CONTROL_IDS[name]}`)
    if (!button) return
    const handler = (event) => {
      if (event) event.preventDefault()
      this._invoke(name, call)
    }
    button.addEventListener("click", handler)
    this._controls.push({button, handler})
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
    this._hidden = false
    if (this._maxTimer) {
      clearTimeout(this._maxTimer)
      this._maxTimer = null
    }
    ;(this._controls || []).forEach(({button, handler}) => {
      button.removeEventListener("click", handler)
    })
    this._controls = []
    // Safe if the resize subscription has not resolved yet: nulling the
    // promise makes its then-callback unlisten immediately instead of storing.
    this._unlistenPromise = null
    if (this._unlisten) {
      this._unlisten()
      this._unlisten = null
    }
    if (this.el && this.el.dataset[BOUND_FLAG] === "true") {
      delete this.el.dataset[BOUND_FLAG]
    }
    this._win = null
  }
}

export {DesktopTitlebar, chromeState}
export default DesktopTitlebar
