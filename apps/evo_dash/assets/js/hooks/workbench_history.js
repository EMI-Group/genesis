// The handoff spans adjacent LiveView shells in this document, not projects or
// browser history entries. It contains only a dock node and a scroll offset.
let handoff

const scopePending = el => el.dataset.workbenchHistoryScopePending === "true"
const rowsSelector = "#workbench-history-rows"
const filtersSelector = "#workbench-history-filters"
const scrollKeys = new Set(["ArrowDown", "ArrowUp", "PageDown", "PageUp", "Home", "End", " "])

const viewKey = (el, node, project) => {
  const form = el.querySelector(filtersSelector)
  if (!form) return null
  const kind = form.querySelector("[data-history-kind]")?.dataset.historyKind
  if (!kind) return null
  return JSON.stringify([node, project, kind, form.elements.project.value,
    form.elements.status.value, form.elements.query.value])
}

export function createHistoryScroll(el, entry) {
  let scroller, track
  let waiting = Boolean(entry?.top)

  const onScroll = ({target}) => {
    if (!track || target !== scroller) return
    const top = Math.max(0, scroller.scrollTop)
    if (waiting && !top) return // e.g. a browser clamp while resetting the list
    waiting = false
    entry.top = top
  }
  const onInput = ({target, type, key}) => {
    if (type === "input" || type === "change" || type === "submit" || type === "click") {
      const kindChange = type === "click" && target.closest('[data-workbench-kind][aria-pressed="false"]')
      if (entry && target.closest(filtersSelector) && (kindChange || (type !== "click" &&
          viewKey(el, entry.node, entry.project) !== entry.key))) {
        waiting = track = false
        entry.top = 0
      }
    } else if (waiting && scroller && target.closest(rowsSelector) === scroller) {
      if (type === "pointerdown" && target !== scroller) return // links and Load more are not scrollbar input
      if (type === "keydown" && (!scrollKeys.has(key) || (key === " " && target.closest("button, a")))) return
      // Yield even at scrollTop=0 (wheel, touch, scrollbar or keyboard intent).
      waiting = false
      entry.top = Math.max(0, scroller.scrollTop)
    }
  }
  const inputEvents = ["input", "change", "submit", "click", "wheel", "touchmove", "pointerdown", "keydown"]
  el.addEventListener("scroll", onScroll, true)
  for (const type of inputEvents) el.addEventListener(type, onInput, true)

  return {
    sync({node, project, pending, visible}) {
      track = false
      if (pending) {
        if (entry?.node !== node) entry = null
        waiting = Boolean(entry?.top)
        scroller = null
        return
      }
      const rows = project && el.querySelector(rowsSelector)
      const key = rows && viewKey(el, node, project)
      if (!key) {
        entry = scroller = null
        waiting = false
        return
      }
      if (entry?.key !== key) {
        if (entry) rows.scrollTop = 0
        entry = {node, project, key, top: 0}
        waiting = false
      } else if (scroller !== rows || rows.dataset.loading === "true") {
        waiting = Boolean(entry.top)
      }
      scroller = rows
      track = visible && rows.dataset.loading !== "true"
      if (!track || !waiting || !rows.clientHeight) return
      const max = Math.max(0, rows.scrollHeight - rows.clientHeight)
      // Do not clamp to the current page's bottom while older pages remain.
      // Normal server-owned paging can make the offset reachable later.
      if (max < entry.top && rows.querySelector("[data-workbench-more]")) return
      rows.scrollTop = Math.min(max, entry.top)
      entry.top = rows.scrollTop
      waiting = false
    },
    snapshot() {
      // A scroll may have changed position just before teardown, without its
      // scroll event being delivered. Detached elements can no longer tell us.
      if (track && !waiting && scroller.isConnected) onScroll({target: scroller})
      return entry?.top ? {...entry} : null
    },
    destroy() {
      el.removeEventListener("scroll", onScroll, true)
      for (const type of inputEvents) el.removeEventListener(type, onInput, true)
    },
  }
}

export const historyMethods = {
  mountHistory(outgoing) {
    const previous = outgoing?.historyTransfer() || handoff
    this.historyDockNode = previous?.dockNode ?? null
    this.historyScroll = createHistoryScroll(this.el, previous?.scroll)
    handoff = null
  },

  historyTransfer() {
    return {dockNode: this.historyDockNode, scroll: this.historyScroll.snapshot()}
  },

  destroyHistory(ownsShell) {
    if (ownsShell) handoff = this.historyTransfer()
    this.historyScroll.destroy()
  },

  syncHistoryScroll() {
    const panel = this.el.querySelector("#workbench-history")
    this.historyScroll.sync({node: this.node || "", project: this.project,
      pending: scopePending(this.el), visible: panel?.dataset.panelState === "open" && !panel.inert})
  },

  syncHistoryPanel(animate = true) {
    const panel = this.el.querySelector("#workbench-history")
    if (!panel) {
      this.historyDockNode = null
      this.syncHistoryScroll()
      return
    }
    const node = this.node || ""
    const pending = scopePending(this.el)
    const wide = this.media.matches
    const git = this.el.querySelector("#workbench-git")
    const gitOpen = Boolean(git && this.gitOpen && this.project && !pending)
    if (pending && !wide) this.historyOpen = false // do not open an unrequested overlay when scope arrives
    const reserved = pending && wide && this.historyDockNode === node
    const available = !pending && Boolean(this.project)
    const open = this.historyOpen && !gitOpen && (available || reserved)
    this.historyDockNode = open && wide ? node : null

    const toggle = this.el.querySelector("#workbench-history-toggle")
    const resizer = this.el.querySelector("#workbench-right-resize")
    const active = document.activeElement
    const moveFocus = (!open || pending) && (panel.contains(active) ||
      (resizer && active === resizer && !gitOpen) || (pending && toggle && active === toggle))

    // Reuse the regular open geometry (including the separator) but never
    // keep outgoing History content visible or interactive under an unknown scope.
    const content = this.el.querySelector("#workbench-history-content")
    const visibility = available ? "" : "hidden"
    if (content && content.style.visibility !== visibility) content.style.visibility = visibility
    panel.inert = !open || pending || Boolean(this.previewTab)
    this.panelHost.apply(panel, open, animate)
    if (git) this.panelHost.apply(git, gitOpen, animate)
    const drawerOpen = (open || gitOpen) && !wide
    if (resizer) {
      resizer.hidden = drawerOpen || !(open || gitOpen)
      resizer.inert = pending
    }
    const overlay = this.el.querySelector("#workbench-history-overlay")
    if (overlay) overlay.hidden = !drawerOpen
    const center = this.el.querySelector(".workbench-center")
    if (center) center.inert = drawerOpen || Boolean(this.previewTab)
    if (git) git.inert = pending || Boolean(this.previewTab)
    const attribute = "data-workbench-history-drawer-open"
    if (drawerOpen !== this.el.hasAttribute(attribute)) {
      this.el.toggleAttribute(attribute, drawerOpen)
      this.el.dispatchEvent(new Event("workbench:history-drawer"))
    }
    if (toggle) {
      toggle.inert = pending
      toggle.setAttribute("aria-expanded", String(open && available))
    }
    this.el.querySelector("#workbench-git-toggle")?.setAttribute("aria-expanded", String(gitOpen))
    if (moveFocus && !center?.inert) {
      const fallback = (available && toggle) || this.el.querySelector("#workbench-create-toggle")
      fallback?.focus({preventScroll: true})
    }
    this.syncHistoryScroll()
  },
}
