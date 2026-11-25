import {projectPreview} from "./workbench_project_preview"
import {closeAnimated} from "./disclosure_motion.js"
import {createPanelHost} from "./workbench_panel_dom"
import {initialPanelState, PANEL_OPEN} from "./workbench_panel"
import {closeTab as closeTabIn, restore as restoreTabs, safeHref as safeHrefBase} from "./workbench_tabs"
import {link, railMethods, TAB_KEY} from "./workbench_rail"
import {defaultDraftHref, exactHref, historyKey, navigationState, sameTabClick} from "./workbench_navigation"

const ACCENT_KEY = "genesis-workbench.accent"
const SIDEBAR_WIDTHS_KEY = "genesis-workbench.sidebar-widths"
const HISTORY_KEY = "genesis-workbench.history"
const GIT_KEY = "genesis-workbench.git"
const SIDEBAR_WIDTHS = {
  left: {default: 256, min: 192, max: 480},
  right: {default: 336, min: 264, max: 640},
}
const CENTER_MIN_WIDTH = 480
let projectSidebarScrollTop = 0
function applyAccent(el) {
  el.dataset.accentColor = read(localStorage, ACCENT_KEY, "") || el.dataset.workbenchAccentDefault
}
const WIDE = "(min-width: 1280px)"
const route = (path, node, params = {}) => {
  const query = new URLSearchParams(params)
  if (node) query.set("node", node)
  return query.size ? path + "?" + query : path
}
const id = () => Array.from(crypto.getRandomValues(new Uint8Array(12)), byte =>
  byte.toString(16).padStart(2, "0")).join("")

function read(storage, key, fallback) {
  try { return JSON.parse(storage.getItem(key)) ?? fallback } catch { return fallback }
}

function write(storage, key, data) {
  try { storage.setItem(key, JSON.stringify(data)) } catch { /* use current page state */ }
}

const currentHref = () => exactHref(location)
const navigation = navigationState()
let mountedWorkbench
let navigationBound = false
const repaintPending = () => mountedWorkbench?.paintPending()

// LiveView can destroy the outgoing hook before it emits the navigation commit
// and mounts the destination. One document-level observer bridges that gap.
function bindNavigation() {
  if (navigationBound) return
  navigationBound = true
  const traverse = () => { navigation.traverse(currentHref()); repaintPending() }
  if (performance.getEntriesByType("navigation")[0]?.type === "back_forward") traverse()
  window.addEventListener("popstate", traverse, true)
  window.addEventListener("pageshow", event => { if (event.persisted) traverse() })
  window.addEventListener("hashchange", () => mountedWorkbench?.onNavigation())
  window.addEventListener("phx:before-navigate", event => {
    if (event.detail?.pop || !event.detail?.href) return
    const href = exactHref(new URL(event.detail.href, location.href))
    const revision = navigation.revision
    queueMicrotask(() => {
      if (!event.defaultPrevented && navigation.revision === revision && href !== currentHref()) {
        navigation.start(href, repaintPending, true)
        repaintPending()
      }
    })
  })
  window.addEventListener("phx:page-loading-start", ({detail}) => {
    if (!["patch", "redirect"].includes(detail?.kind) || !detail.to) return
    navigation.start(exactHref(new URL(detail.to, location.href)), repaintPending)
    repaintPending()
  })
  window.addEventListener("phx:navigate", ({detail}) => {
    if (!detail?.href || exactHref(new URL(detail.href, location.href)) !== currentHref()) return
    if (!detail.pop) navigation.commit(currentHref())
    repaintPending()
    mountedWorkbench?.onNavigation()
  })
}

// A persisted href may only be followed inside THIS dashboard; the rule itself
// is the tab store's (`workbench_tabs.js`), bound here to the live origin.
const safeHref = value => safeHrefBase(value, location.origin)

// --- Workbench: pure sync probe --------------------------------------------
// Decides whether `sync()` — the shell sweep — has to re-run after a LiveView
// patch. EVERY patch in the shell reaches `updated()`, while `sync()` is a set
// of full-subtree `querySelectorAll` walks plus per-row writes (the rail, every
// history row's current marker, the panel states, the sidebar widths, the Git
// label, the create menu), so running it per patch made CONTENT updates pay for
// the whole shell. `updated()` probes first: the `state` object below is built
// from property reads only (no `querySelectorAll`, no geometry) and compared
// with the state recorded after the last sweep. Everything here is DOM-free, so
// the planner is testable (hooks/workbench.test.cjs slices this block).

// The dataset fields `captureTab()` derives the current tab from — its key, href
// and title. A navigation changing ANY of them must sweep: the rail, the per-row
// current markers and the preview handoff all follow the current tab.
const SYNC_DATASET_KEYS = [
  "workbenchNode", "workbenchProject", "workbenchTask", "workbenchSession",
  "workbenchDraft", "workbenchDraftProject", "workbenchPage", "workbenchTitle",
  "workbenchDefaultDraft", "workbenchGitBranch", "workbenchStartingCommit",
]

// One normalised string per input: `undefined`, `null` and a missing field read
// the same, so no probe result depends on key order or `dataset` vs a literal.
function probeText(value) {
  return value === undefined || value === null ? "" : String(value)
}

// One workbench/sidebar list's shape: its name, child count, and the head and
// tail row identities (property reads, never a sweep).
// WHY count + head + tail is sufficient: the project sidebar is RECENCY-ordered
// (a mounted project is inserted or moved at the HEAD) and the ONE
// `[data-workbench-item]` history list is PAGED (append at the TAIL, a filter
// or kind change replaces the whole list), so a mid-list-only change keeping all
// three identical cannot occur; a history row's only hook-owned state is its
// current marker, which derives from {kind, item id}.
function probeListShape(list) {
  if (!list) return ["", "", "", ""]
  return [probeText(list.name), probeText(list.count),
    probeText(list.head), probeText(list.tail)]
}

// Everything `sync()` reads, as one comparable string: the layout dataset, the
// Git pane's own inputs (the diff title that creates the diff tab, the branch
// label, the scope `syncGitStatus` refreshes on), the sidebar flags
// `syncEmptyState` reads, the JS-written re-render marker, and the list shapes.
// THE RESET MARKER: `applyAccent` writes `data-accent-color` on this element (the
// server renders the accent too, so the two differ exactly when localStorage
// carries an override) and `renderTabs` writes `data-signature` on the rail,
// which the server never renders — and the rail is `phx-update="ignore"`, so a
// missing marker means a NEW element (a re-rendered header), exactly the case
// the sweep has to repaint.
function syncStateSignature(state) {
  if (!state) return ""
  const data = state.dataset || {}
  const git = state.git || {}
  const lists = Array.isArray(state.lists) ? state.lists : []
  return JSON.stringify([
    SYNC_DATASET_KEYS.map(key => probeText(data[key])),
    probeText(git.diff), probeText(git.head), probeText(git.scope),
    probeText(git.target),
    probeText(state.projectsLoading), probeText(state.historyEmpty),
    probeText(state.accent), probeText(state.tabsMarked),
    lists.map(probeListShape),
  ])
}

// The planner `updated()` uses. `applied` is the state recorded at the end of the
// last sweep, so a first mount is always dirty, exactly like `sidebar_collapse.js`.
// Total: a missing state is "nothing to fix" and never throws.
function workbenchSyncNeeded(state, applied) {
  if (!state) return false
  if (!applied) return true
  return syncStateSignature(state) !== syncStateSignature(applied)
}
// Workbench hook: the DOM half below only READS those inputs and executes the
// sweep — every decision stays in the pure block above.

const Workbench = {
  ...railMethods,

  mounted() {
    // The persisted list is untrusted input the store normalises and re-keys.
    this.navigation = navigation
    mountedWorkbench = this
    bindNavigation()
    this.tabs = restoreTabs(read(sessionStorage, TAB_KEY, []), safeHref)
    this.persistTabs()
    this.media = matchMedia(WIDE)
    this.reduceMotion = matchMedia("(prefers-reduced-motion: reduce)")
    this.panelHost = createPanelHost(() => Boolean(this.reduceMotion?.matches))
    this.panelReady = false
    // Only an explicit choice in THIS tab re-opens the panel; a fresh tab is closed.
    this.historyOpen = initialPanelState(read(sessionStorage, HISTORY_KEY, null)) === PANEL_OPEN
    this.gitOpen = initialPanelState(read(sessionStorage, GIT_KEY, null)) === PANEL_OPEN
    this.gitLoadedScope = null
    this.sidebarWidths = read(localStorage, SIDEBAR_WIDTHS_KEY, {})
    this.sidebarDrag = null
    this.onViewportResize = () => {
      this.syncSidebarWidths()
      projectPreview.reposition(this.el)
      this.positionCreateMenu()
      this.syncTabOverflow()
    }
    this.onResize = () => {
      // A narrower viewport makes the docked panel an overlay drawer — and that is not a remembered preference.
      if (!this.media.matches) {
        this.historyOpen = false
        this.gitOpen = false
      }
      this.syncHistoryPanel()
    }
    this.onClick = event => this.click(event)
    this.onPointerDown = event => {
      this.pressedBackdrop = event.target.matches("dialog.workbench-window[open]") ? event.target : null
      this.beginSidebarResize(event)
    }
    this.onPointerMove = event => this.moveSidebarResize(event)
    this.onPointerEnd = event => this.endSidebarResize(event)
    this.onCreateToggle = event => {
      if (event.target.id === "workbench-create" && event.target.open) this.positionCreateMenu()
      if (event.target.id === "workbench-tabs-overflow" && event.target.open) this.renderOverflowTabs()
    }
    this.onOutsideCreate = event => {
      const menu = this.el.querySelector("#workbench-create[open]")
      if (menu && !menu.contains(event.target)) menu.open = false
      const overflow = this.el.querySelector("#workbench-tabs-overflow[open]")
      if (overflow && !overflow.contains(event.target)) overflow.open = false
    }
    // Middle click PINS a preview tab (the only keep-open gesture): no autoscroll, no new tab.
    this.onTabMouseDown = event => {
      if (event.button === 1 && event.target.closest("#workbench-tabs .workbench-tab")) event.preventDefault()
    }
    this.onTabAuxClick = event => {
      const item = event.button === 1 && event.target.closest("#workbench-tabs .workbench-tab")
      if (!item?.dataset.tabKey) return
      event.preventDefault()
      event.stopPropagation()
      this.pinTab(item.dataset.tabKey)
    }
    this.onKey = event => {
      if (this.resizeSidebarWithKey(event)) return
      if (this.cycleTabWithKey(event)) return
      if (event.key === "Enter" && event.target.closest(".project-palette-overlay")) {
        const action = this.el.querySelector(".project-palette-item[data-selected='true'][data-workbench-project-window]")
        if (action) {
          event.preventDefault()
          event.stopPropagation()
          this.openProjectWindow(action)
          return
        }
      }
      if (event.key !== "Escape" || event.defaultPrevented) return
      const overflow = event.target.closest("#workbench-tabs-overflow[open]")
      if (overflow) {
        overflow.open = false
        overflow.querySelector("summary")?.focus()
        event.preventDefault()
        return
      }
      const create = event.target.closest("#workbench-create[open]")
      if (create) {
        create.open = false
        create.querySelector("summary")?.focus()
        event.preventDefault()
      } else if (this.gitDiff && !this.el.hasAttribute("data-workbench-history-drawer-open") &&
          !event.target.closest("dialog[open]")) {
        this.closeGitDiff()
        event.preventDefault()
      } else if (this.project && (this.gitOpen || this.historyOpen && !this.media.matches) &&
          !event.target.closest("dialog[open]")) {
        if (this.gitOpen) this.setGit(false, true)
        else this.setHistory(false, true)
        event.preventDefault()
      }
    }
    this.onNavigation = () => { if (this.el.isConnected) this.sync() }
    this.onStorage = event => {
      if (event.key === ACCENT_KEY) applyAccent(this.el)
      if (event.key === SIDEBAR_WIDTHS_KEY && !this.sidebarDrag) {
        this.sidebarWidths = read(localStorage, SIDEBAR_WIDTHS_KEY, {})
        this.syncSidebarWidths()
      }
    }
    this.projectSidebarNav = this.el.querySelector(".workbench-sidebar-nav")
    this.onProjectSidebarScroll = () => {
      projectSidebarScrollTop = this.projectSidebarNav.scrollTop
    }
    this.projectSidebarNav?.addEventListener("scroll", this.onProjectSidebarScroll)

    this.settingsWindow = this.el.querySelector("#workbench-settings-window")
    this.settingsFrame = this.el.querySelector("#workbench-settings-frame")
    this.onWindowMessage = event => {
      if (event.origin === location.origin && event.source === this.settingsFrame?.contentWindow &&
          event.data === "genesis:close-settings-window") this.closeWindow(this.settingsWindow)
    }
    this.onSettingsClose = () => {
      this.settingsFrame?.removeAttribute("src")
      // Every close edge (the close button, a backdrop click, Escape and the
      // iframe's postMessage) releases the <dialog> through closeAnimated -> its
      // own close(), so this ONE listener sees them all. A config save made here
      // is the only edge that also covers a REMOTE target (whose write never
      // reaches this BEAM's config PubSub), so the Projects task page re-runs its
      // model load — gated on `[data-task-draft-scope]`, the marker only that
      // page renders, so the event can never land as an unhandled one.
      if (this.el.querySelector("[data-task-draft-scope]")) {
        this.pushEvent("retry_model_selection", {})
      }
    }
    this.settingsWindow?.addEventListener("close", this.onSettingsClose)
    window.addEventListener("message", this.onWindowMessage)
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("mousedown", this.onTabMouseDown)
    this.el.addEventListener("auxclick", this.onTabAuxClick)
    this.el.addEventListener("pointerdown", this.onPointerDown)
    this.el.addEventListener("pointermove", this.onPointerMove)
    for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) this.el.addEventListener(type, this.onPointerEnd)
    this.el.addEventListener("toggle", this.onCreateToggle, true)
    window.addEventListener("resize", this.onViewportResize)
    document.addEventListener("click", this.onOutsideCreate)
    this.el.addEventListener("workbench:section", this.onNavigation)
    this.el.addEventListener("keydown", this.onKey)
    this.media.addEventListener("change", this.onResize)
    window.addEventListener("storage", this.onStorage)
    // Undefined until the sweep records it, so the probe reports "dirty" here.
    this.appliedSyncState = undefined
    this.sync()
    if (this.projectSidebarNav) this.projectSidebarNav.scrollTop = projectSidebarScrollTop
  },

  updated() {
    // Cheap probe FIRST: a CONTENT-only patch cannot change any sync input.
    if (workbenchSyncNeeded(this.syncState(), this.appliedSyncState)) this.sync()
  },

  destroyed() {
    this.projectSidebarNav?.removeEventListener("scroll", this.onProjectSidebarScroll)
    this.settingsWindow?.removeEventListener("close", this.onSettingsClose)
    window.removeEventListener("message", this.onWindowMessage)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("mousedown", this.onTabMouseDown)
    this.el.removeEventListener("auxclick", this.onTabAuxClick)
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    this.el.removeEventListener("pointermove", this.onPointerMove)
    for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) this.el.removeEventListener(type, this.onPointerEnd)
    this.el.removeEventListener("toggle", this.onCreateToggle, true)
    window.removeEventListener("resize", this.onViewportResize)
    document.removeEventListener("click", this.onOutsideCreate)
    this.el.removeEventListener("workbench:section", this.onNavigation)
    this.el.removeEventListener("keydown", this.onKey)
    this.media.removeEventListener("change", this.onResize)
    if (mountedWorkbench === this) mountedWorkbench = null
    window.removeEventListener("storage", this.onStorage)
    this.panelHost.destroy()
    // Release the preview snapshot cache + its shadow-DOM host — but NEVER mid
    // handoff: `release()` clears a pending handoff, and the host lives on
    // `document.body`, OUTSIDE this hook's element, so a project switch keeps
    // painting the old window. In flight ⟺ the body carries the marker (set by
    // `show()`, cleared by `clear()`/`sync()`).
    if (!document.body.hasAttribute("data-workbench-project-switching")) projectPreview.release()
  },

  sync() {
    applyAccent(this.el)
    const data = this.el.dataset
    this.node = data.workbenchNode
    this.project = data.workbenchProject
    this.gitDiff = this.el.querySelector("#workbench-git-content")?.dataset.workbenchGitDiff
    this.rows = Array.from(this.el.querySelectorAll("[data-workbench-item]"))
    const locations = this.el.querySelectorAll("[data-workbench-project][href]")
    const projectLink = Array.from(locations).find(anchor =>
      anchor.dataset.workbenchNode === this.node && anchor.dataset.workbenchProject === this.project)
    this.projectName = projectLink?.dataset.workbenchProjectName || this.project.split(/[\\/]/).filter(Boolean).at(-1)
    this.captureTab()
    this.previewTab = projectPreview.sync(this.el, this.currentTab)
    this.renderTabs()
    this.renderHistory()
    this.syncEmptyState()
    // The first sync only SEEDS the panel: no entrance animation on load.
    this.syncHistoryPanel(this.panelReady)
    this.panelReady = true
    this.syncSidebarWidths()
    this.syncGitStatus()
    this.syncGitDiffFocus()
    this.positionCreateMenu()
    // The probe's baseline, taken once every marker of this sweep is in place.
    this.appliedSyncState = this.syncState()
    this.settleActivation()
    this.maybeOpenDefaultDraft()
  },

  // The probe inputs for `updated()` (pure block above): property reads only —
  // one `querySelector` per marker family, and child count + head/tail per list.
  syncState() {
    const el = this.el
    const data = el.dataset || {}
    const dataset = {}
    for (const key of SYNC_DATASET_KEYS) dataset[key] = data[key]
    const git = el.querySelector("#workbench-git-content")?.dataset || {}
    const side = el.querySelector("#workbench-projects")?.dataset || {}
    const history = el.querySelector("#workbench-history-content")
    const lists = []
    // The paged history item list. Its children include the optional "Load
    // more" button, which is why the shape records the raw head/tail children
    // (a button carries no item id) — any page append or list replacement moves
    // the count or the tail.
    const rows = history?.querySelector("#workbench-history-rows")
    if (rows) {
      lists.push({
        name: "items", count: rows.childElementCount,
        head: rows.firstElementChild?.dataset.itemId,
        tail: rows.lastElementChild?.dataset.itemId,
      })
    }
    // The recency-ordered project sidebar list: `syncEmptyState` reads whether
    // it has rows.
    const projectList = el.querySelector(".workbench-project-list")
    if (projectList) {
      const path = row => row?.querySelector(".workbench-project-link")?.dataset.workbenchProject
      lists.push({
        name: "projects", count: projectList.childElementCount,
        head: path(projectList.firstElementChild),
        tail: path(projectList.lastElementChild),
      })
    }
    return {
      dataset,
      git: {
        diff: git.workbenchGitDiff, head: git.workbenchGitHead,
        scope: git.workbenchGitScope, target: git.workbenchGitTarget,
      },
      projectsLoading: side.workbenchProjectsLoading,
      historyEmpty: history?.dataset.workbenchHistoryEmpty,
      accent: data.accentColor,
      tabsMarked: el.querySelector("#workbench-tabs")?.dataset.signature,
      lists,
    }
  },

  positionCreateMenu() {
    const menu = this.el.querySelector("#workbench-create[open] .workbench-create-menu")
    if (!menu) return
    menu.style.removeProperty("--workbench-create-menu-shift")
    const {left, right} = menu.getBoundingClientRect()
    const margin = 8
    const center = this.el.querySelector(".workbench-center").getBoundingClientRect()
    const overflow = right - (center.right - margin)
    const shift = Math.max(center.left + margin - left, -Math.max(0, overflow))
    if (shift) menu.style.setProperty("--workbench-create-menu-shift", `${shift}px`)
  },

  sidebarBounds() {
    const {left, right} = SIDEBAR_WIDTHS
    const room = this.el.clientWidth - CENTER_MIN_WIDTH
    const leftMax = Math.min(left.max, room - (this.media.matches ? right.min : 0))
    const leftWidth = this.sidebarWidth("left", leftMax)
    const rightMax = this.media.matches ? Math.min(right.max, room - leftWidth) : right.max
    const rightWidth = this.sidebarWidth("right", rightMax)
    return {
      left: {
        width: leftWidth, min: left.min,
        max: Math.max(left.min, this.media.matches ? Math.min(left.max, room - rightWidth) : leftMax),
      },
      right: {width: rightWidth, min: right.min, max: Math.max(right.min, rightMax)},
    }
  },

  sidebarWidth(side, max) {
    const limits = SIDEBAR_WIDTHS[side]
    const saved = this.sidebarWidths[side]
    const width = Number.isFinite(saved) ? saved : limits.default
    return Math.max(limits.min, Math.min(max, Math.round(width)))
  },

  syncSidebarWidths() {
    for (const [side, {width, min, max}] of Object.entries(this.sidebarBounds())) {
      this.el.style.setProperty(`--workbench-${side}-width`, `${width}px`)
      const handle = this.el.querySelector(`#workbench-${side}-resize`)
      handle?.setAttribute("aria-valuemin", String(min))
      handle?.setAttribute("aria-valuemax", String(max))
      handle?.setAttribute("aria-valuenow", String(width))
    }
    // The rail lives in the center column, so every sidebar width (a drag, a
    // viewport resize, a sweep) can flip its overflow state.
    this.syncTabOverflow()
  },

  sidebarDirection(side) {
    const rtl = getComputedStyle(this.el).direction === "rtl"
    return (side === "left") !== rtl ? 1 : -1
  },

  beginSidebarResize(event) {
    const handle = event.target.closest("[data-workbench-resize]")
    if (!handle || event.button !== 0 || this.sidebarDrag) return
    const side = handle.dataset.workbenchResize
    event.preventDefault()
    handle.focus({preventScroll: true})
    handle.setPointerCapture(event.pointerId)
    this.sidebarDrag = {
      pointer: event.pointerId, side, origin: event.clientX,
      ...this.sidebarBounds()[side], direction: this.sidebarDirection(side),
    }
    this.el.dataset.workbenchResizing = side
  },

  moveSidebarResize(event) {
    const drag = this.sidebarDrag
    if (drag?.pointer !== event.pointerId) return
    const width = drag.width + (event.clientX - drag.origin) * drag.direction
    this.setSidebarWidth(drag.side, width, drag)
  },

  endSidebarResize(event) {
    if (this.sidebarDrag?.pointer !== event.pointerId) return
    this.sidebarDrag = null
    delete this.el.dataset.workbenchResizing
    write(localStorage, SIDEBAR_WIDTHS_KEY, this.sidebarWidths)
  },

  resizeSidebarWithKey(event) {
    const side = event.target.dataset.workbenchResize
    if (!side || !["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return false
    const bounds = this.sidebarBounds()[side]
    const direction = event.key === "ArrowRight" ? 1 : -1
    const width = event.key === "Home" ? bounds.min : event.key === "End" ? bounds.max :
      bounds.width + direction * this.sidebarDirection(side) * 16
    this.setSidebarWidth(side, width, bounds)
    write(localStorage, SIDEBAR_WIDTHS_KEY, this.sidebarWidths)
    event.preventDefault()
    return true
  },

  setSidebarWidth(side, width, {min, max}) {
    const {left, right} = this.sidebarBounds()
    this.sidebarWidths = {left: left.width, right: right.width, [side]: Math.max(min, Math.min(max, width))}
    this.syncSidebarWidths()
    this.positionCreateMenu()
  },

  syncEmptyState() {
    const idle = this.el.querySelector("#workbench-idle")
    const sidebar = this.el.querySelector("#workbench-projects")
    if (idle && sidebar) {
      const hasProject = Boolean(this.project || sidebar.querySelector("[data-workbench-project-row]"))
      idle.querySelector("[data-workbench-idle-projects]").hidden =
        hasProject || sidebar.dataset.workbenchProjectsLoading === "true"
      idle.querySelector("[data-workbench-idle-window]").hidden = !hasProject
    }
    const create = this.el.querySelector("#workbench-create-toggle")
    const emptyHistory = this.el.querySelector("#workbench-history-content")?.dataset.workbenchHistoryEmpty === "true"
    if (create) {
      if (this.project && !this.currentTab && !this.gitDiff && idle && emptyHistory) create.dataset.workbenchAttention = "true"
      else delete create.dataset.workbenchAttention
    }
  },

  // The per-panel state machine and the open/close start frames live in the
  // `panelHost` (workbench_panel_dom.js); every LiveView patch re-runs this, so
  // an unchanged state is a pure re-assert that never restarts a running close.
  syncHistoryPanel(animate = true) {
    const panel = this.el.querySelector("#workbench-history")
    if (!panel) return
    const git = this.el.querySelector("#workbench-git")
    const gitOpen = Boolean(git && this.gitOpen && this.project)
    const open = this.historyOpen && Boolean(this.project) && !gitOpen
    this.panelHost.apply(panel, open, animate)
    if (git) this.panelHost.apply(git, gitOpen, animate)
    const drawerOpen = (open || gitOpen) && !this.media.matches
    const resizer = this.el.querySelector("#workbench-right-resize")
    if (resizer) resizer.hidden = drawerOpen || !(open || gitOpen)
    const overlay = this.el.querySelector("#workbench-history-overlay")
    if (overlay) overlay.hidden = !drawerOpen
    const center = this.el.querySelector(".workbench-center")
    if (center) center.inert = drawerOpen || Boolean(this.previewTab)
    panel.inert = Boolean(this.previewTab)
    if (git) git.inert = Boolean(this.previewTab)
    const attribute = "data-workbench-history-drawer-open"
    if (drawerOpen !== this.el.hasAttribute(attribute)) {
      this.el.toggleAttribute(attribute, drawerOpen)
      this.el.dispatchEvent(new Event("workbench:history-drawer"))
    }
    this.el.querySelector("#workbench-history-toggle")?.setAttribute("aria-expanded", String(open))
    this.el.querySelector("#workbench-git-toggle")?.setAttribute("aria-expanded", String(gitOpen))
  },

  setHistory(open, focus = false) {
    this.historyOpen = open
    write(sessionStorage, HISTORY_KEY, open)
    this.syncHistoryPanel()
    if (focus) this.el.querySelector(open ? "[data-workbench-close-history]" : "#workbench-history-toggle")?.focus()
  },

  syncGitStatus() {
    const content = this.el.querySelector("#workbench-git-content")
    const label = this.el.querySelector("#workbench-git-toggle-label")
    if (!content || !label) {
      this.gitLoadedScope = null
      return
    }
    const branch = content.dataset.workbenchGitHead
    const title = branch ? `Git · ${branch}` : "Git"
    label.textContent = title
    label.parentElement.title = title
    const scope = JSON.stringify([content.dataset.workbenchGitScope, content.dataset.workbenchGitTarget])
    if (this.gitOpen && this.gitLoadedScope !== scope) {
      this.gitLoadedScope = scope
      this.pushEventTo(content, "git_refresh", {})
    }
  },

  setGit(open, focus = false) {
    this.gitOpen = open
    if (open && !this.gitDiff) this.gitLoadedScope = null
    write(sessionStorage, GIT_KEY, open)
    this.syncHistoryPanel()
    this.syncGitStatus()
    if (focus) this.el.querySelector(open ? "[data-workbench-close-git]" : "#workbench-git-toggle")?.focus()
  },

  closeGitDiff(restoreFocus) {
    this.afterGitDiff = restoreFocus || (() => {
      const control = this.el.querySelector("#workbench-tabs .is-current .workbench-tab-link") ||
        this.el.querySelector("#workbench-git-toggle")
      control?.focus({preventScroll: true})
    })
    this.pushEventTo("#workbench-git-content", "git_close_diff", {})
  },

  syncGitDiffFocus() {
    const title = this.el.querySelector("#workbench-git-diff-title")
    const content = this.el.querySelector("#main-scroll")
    if (content) content.inert = Boolean(this.gitDiff)
    if (!this.gitDiff && this.afterGitDiff) {
      const restore = this.afterGitDiff
      this.afterGitDiff = null
      queueMicrotask(restore)
    }
    if (this.gitDiff && title && this.focusGitDiff) {
      this.focusGitDiff = false
      title.focus({preventScroll: true})
    }
  },

  openProjectWindow(trigger) {
    const dialog = this.el.querySelector("#workbench-project-window")
    this.pushEventTo("#workbench-project-window-component", "prepare",
      {mode: trigger.dataset.workbenchProjectWindow},
      () => {
        if (!dialog?.isConnected || dialog.open) return
        if (trigger.closest("#project-omnibox")) this.pushEvent("close_project_palette", {})
        dialog.showModal()
      })
  },

  // The workbench windows (`#workbench-project-window`, `#workbench-settings-window`,
  // `#workbench-task-settings`) are plain <dialog class="workbench-window">s with
  // no native exit animation. The shared helper plays the CSS exit gated on
  // data-window-state="closing" (assets/css/motion.css) and only then releases the
  // window — through its own close(), so the existing "close" listeners (the
  // settings-frame reset) still fire, and synchronously under reduced motion.
  closeWindow(dialog) {
    if (!dialog) return
    closeAnimated(dialog, {panel: dialog, attr: "data-window-state"})
  },

  switchProject(tab) {
    const current = this.tabs.find(entry => entry.key === this.currentTab)
    const projectChanges = !tab || tab.node !== this.node || tab.projectPath !== this.project
    if (!projectChanges && !this.previewTab) return

    projectPreview.remember(this.el, current)
    projectPreview.show(this.el, tab, () => {
      const layout = document.getElementById("app-layout")
      layout?.dispatchEvent(new Event("workbench:section"))
    })
    this.previewTab = projectPreview.sync(this.el, this.currentTab)
    this.renderTabs()
    this.syncHistoryPanel()
  },

  click(event) {
    if (event.target === this.pressedBackdrop) {
      const dialog = this.pressedBackdrop
      this.pressedBackdrop = null
      this.closeWindow(dialog)
      return
    }
    const trigger = event.target.closest("button, a")
    if (!trigger) return
    const overflowKey = trigger.dataset.workbenchTabOverflowKey
    const tabLink = trigger.matches("a.workbench-tab-link") || Boolean(overflowKey)
    const historyRow = trigger.matches("a[data-workbench-open]") && trigger.closest("[data-workbench-item]")
    if ((tabLink || historyRow) && sameTabClick(event, trigger)) {
      const href = trigger.getAttribute("href")
      const key = overflowKey || (historyRow ? historyKey(this.node, historyRow.dataset) :
        trigger.closest("[data-tab-key]")?.dataset.tabKey)
      if (overflowKey) trigger.closest("#workbench-tabs-overflow").open = false
      if (key && safeHref(href)) {
        if (tabLink && key === this.currentTab && href === currentHref() && !navigation.moving) {
          event.preventDefault()
          event.stopPropagation()
          if (this.gitDiff) this.closeGitDiff()
          else if (overflowKey) this.focusTab(key)
        } else {
          this.indicateActivation(href, key, tabLink && (event.detail === 0 || Boolean(overflowKey)))
        }
      }
      return
    }
    if ("workbenchCloseGitDiff" in trigger.dataset) {
      this.closeGitDiff()
      return
    }
    if ("workbenchGitPreview" in trigger.dataset && !this.media.matches) {
      this.focusGitDiff = true
      this.setGit(false)
    }
    if (trigger.matches("a.workbench-project-link") &&
        !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
      const {workbenchNode, workbenchProject} = trigger.dataset
      const tabs = this.tabsForProject(workbenchNode, workbenchProject)
      const active = tabs.find(tab => tab.active) || tabs.at(-1)
      // A legacy conversation can be open without its server-side project.
      // Let an explicit project click open that project's home in this case.
      if (active && active.key === this.currentTab && !this.project) return
      const navigating = Boolean(this.previewTab)
      this.switchProject(active)
      if (active) {
        event.preventDefault()
        event.stopPropagation()
        if (active.key !== this.currentTab || navigating) this.navigate(active.href, {key: active.key})
        else if (this.gitDiff) this.closeGitDiff()
        return
      }
    }
    const create = trigger.closest("#workbench-create")
    if (create) create.open = false
    if ("workbenchNewConversation" in trigger.dataset) {
      this.navigate(route("/assistant", this.node, {wb_project: this.project, wb_draft: id()}))
      return
    }
    if ("workbenchNewTask" in trigger.dataset && this.el.dataset.workbenchPage === "dashboard") {
      const prompt = this.el.querySelector("#prompt")
      if (prompt) {
        event.preventDefault()
        if (this.gitDiff) {
          event.stopPropagation()
          this.closeGitDiff(() => prompt.focus())
        } else {
          prompt.focus()
        }
        return
      }
    }
    if (trigger.id === "workbench-git-toggle") this.setGit(!this.gitOpen, true)
    if (trigger.id === "workbench-history-toggle") {
      if (this.gitOpen) {
        this.setGit(false)
        this.setHistory(true, !this.media.matches)
      } else {
        this.setHistory(trigger.getAttribute("aria-expanded") !== "true", !this.media.matches)
      }
    }
    if (trigger.id === "workbench-history-overlay") {
      if (this.gitOpen) this.setGit(false, true)
      else this.setHistory(false, true)
    }
    if ("workbenchCloseHistory" in trigger.dataset) this.setHistory(false, true)
    if ("workbenchCloseGit" in trigger.dataset) this.setGit(false, true)
    if (trigger.dataset.workbenchSettings && this.settingsWindow && !this.settingsWindow.open &&
        !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
      event.preventDefault()
      this.settingsFrame.src = trigger.dataset.workbenchSettings
      this.settingsWindow.showModal()
    }
    if (trigger.dataset.workbenchProjectWindow) {
      event.preventDefault()
      event.stopPropagation()
      this.openProjectWindow(trigger)
    }
    if ("workbenchTaskSettings" in trigger.dataset) {
      const dialog = this.el.querySelector("#workbench-task-settings")
      if (dialog && !dialog.open) dialog.showModal()
    }
    if ("workbenchCloseWindow" in trigger.dataset) this.closeWindow(trigger.closest("dialog"))
    if ("workbenchCloseTab" in trigger.dataset) this.closeTab(trigger.dataset.workbenchCloseTab, event.detail === 0)
  },

  closeTab(key, restoreFocus) {
    // The store decides everything about a close, including where attention goes.
    const {tabs, closed, focus} = closeTabIn(this.tabs, key)
    if (!closed) return
    projectPreview.forget(closed)
    if (closed.kind === "draft") {
      this.pushEventTo("#workbench-projects", "discard_assistant_draft", {id: closed.id})
    }
    this.tabs = tabs
    this.persistTabs()
    this.renderTabs()

    if (key === this.currentTab) {
      const blank = closed.projectPath ? {wb_home: "1", project: closed.projectPath} : {wb_home: "1"}
      this.navigate(focus?.href || route("/projects", this.node, blank), {key: focus?.key || null, restoreFocus})
    } else if (restoreFocus) {
      this.focusTab(focus?.key)
    }
  },

  persistTabs() { write(sessionStorage, TAB_KEY, this.tabs) },

  focusTab(key) {
    const anchor = key && this.el.querySelector(`[data-tab-key="${CSS.escape(key)}"] .workbench-tab-link`)
    const control = anchor || this.el.querySelector("#workbench-create-toggle")
    control?.focus({preventScroll: true})
  },

  indicateActivation(href, key, restoreFocus) {
    navigation.request(href, key, restoreFocus ? document.activeElement : null, repaintPending)
    this.paintPending()
  },

  settleActivation() {
    if (!this.routeConfirmed) return
    const done = navigation.confirm(currentHref(), this.currentTab ?? null)
    if (!done) return
    this.paintPending()
    if (!done.focus) return
    const revision = navigation.revision
    requestAnimationFrame(() => {
      const focused = document.activeElement
      if (mountedWorkbench === this && this.el.isConnected && navigation.revision === revision &&
          currentHref() === done.href && (this.currentTab ?? null) === done.key &&
          (focused === document.body || focused === done.focus)) this.focusTab(done.key)
    })
  },

  maybeOpenDefaultDraft() {
    if (!this.routeConfirmed || this.currentTab || this.previewTab || this.gitDiff) return
    const url = new URL(location.href)
    const href = defaultDraftHref(url, this.el.dataset, this.visibleTabs().length > 0)
    if (!href) return
    const scope = new URL(href, url.origin).searchParams.get("wb_project")
    if (this.tabsForProject(this.node, scope).length) return
    const source = exactHref(url)
    const revision = navigation.revision
    queueMicrotask(() => {
      // A newer patch, user navigation or browser traversal may have won.
      if (mountedWorkbench !== this || !this.el.isConnected || currentHref() !== source ||
          navigation.revision !== revision || this.el.dataset.workbenchDefaultDraft !== href ||
          this.railTabs().length || this.tabsForProject(this.node, scope).length ||
          !navigation.claimDefault(source, JSON.stringify([this.node, scope]))) return
      this.navigate(href)
    })
  },

  navigate(href, {key, restoreFocus} = {}) {
    if (!safeHref(href)) return
    if (key !== undefined) {
      if (!navigation.moving && currentHref() === href && (this.currentTab ?? null) === key) {
        if (this.gitDiff) this.closeGitDiff()
        else if (restoreFocus) this.focusTab(key)
        return
      }
      this.indicateActivation(href, key, restoreFocus)
    }
    const anchor = link(href, "", "sr-only")
    this.el.append(anchor)
    anchor.click()
    anchor.remove()
  },

}

export default Workbench

export const WorkbenchSection = {
  mounted() { this.notifyParent() },
  updated() { this.notifyParent() },
  notifyParent() {
    this.el.dispatchEvent(new CustomEvent("workbench:section", {bubbles: true}))
  },
}

export const WorkbenchWindow = {
  mounted() {
    this.settingsNavOpen = false
    this.narrow = matchMedia("(max-width: 767.98px)")
    this.syncPreferences()
    this.onSettingsNavigation = event => {
      if (!this.narrow.matches) return
      if (event.target.closest("#workbench-settings-nav-toggle")) {
        this.setSettingsNav(!this.settingsNavOpen)
      } else if (event.target.closest('#workbench-settings-nav [phx-click="select_category"]')) {
        this.setSettingsNav(false, true)
      }
    }
    this.el.addEventListener("click", this.onSettingsNavigation)
    this.onPreferenceChange = event => {
      const control = event.target
      if (control.dataset.workbenchPreference === "theme") {
        control.dataset.phxTheme = control.value
        control.dispatchEvent(new CustomEvent("phx:set-theme", {bubbles: true}))
      }
      if (control.dataset.workbenchPreference === "locale") {
        window.dispatchEvent(new CustomEvent("phx:set-locale", {detail: {locale: control.value}}))
      }
      if (control.dataset.workbenchPreference === "accent") {
        write(localStorage, ACCENT_KEY, control.value)
        applyAccent(this.el)
      }
    }
    this.onPreferenceStorage = () => this.syncPreferences()
    this.el.addEventListener("change", this.onPreferenceChange)
    window.addEventListener("storage", this.onPreferenceStorage)
    this.forwardEscape = event => {
      if (event.key !== "Escape" || event.defaultPrevented || document.querySelector("dialog[open]")) return
      if (this.narrow.matches && this.settingsNavOpen) {
        this.setSettingsNav(false, true)
        event.preventDefault()
      } else {
        window.parent.postMessage("genesis:close-settings-window", location.origin)
      }
    }
    document.addEventListener("keydown", this.forwardEscape)
  },
  updated() {
    this.syncPreferences()
    this.setSettingsNav(this.settingsNavOpen)
  },
  setSettingsNav(open, focus = false) {
    this.settingsNavOpen = open
    this.el.toggleAttribute("data-settings-nav-open", open)
    const toggle = this.el.querySelector("#workbench-settings-nav-toggle")
    toggle?.setAttribute("aria-expanded", String(open))
    if (focus) toggle?.focus()
  },
  syncPreferences() {
    applyAccent(this.el)
    const theme = this.el.querySelector("#workbench-theme")
    const accent = this.el.querySelector("#workbench-accent")
    if (theme) theme.value = localStorage.getItem("phx:theme") || "system"
    if (accent) accent.value = read(localStorage, ACCENT_KEY, "")
  },
  destroyed() {
    this.el.removeEventListener("click", this.onSettingsNavigation)
    this.el.removeEventListener("change", this.onPreferenceChange)
    window.removeEventListener("storage", this.onPreferenceStorage)
    document.removeEventListener("keydown", this.forwardEscape)
  },
}
