import {alwaysPinned, openTab, pinTab, cycleTab, tabKey, tabGroup,
  tabsForProject} from "./workbench_tabs"
import {exactHref, historyKey, routeTab} from "./workbench_navigation"

export const TAB_KEY = "genesis-workbench.tabs.v1"
const GIT_DIFF_TAB = "workbench-git-diff"
const TAB_ICONS = {
  task: "hero-clipboard-document", chat: "hero-chat-bubble-left", draft: "hero-chat-bubble-left",
  assistant: "hero-chat-bubble-left", project: "hero-folder", diff: "hero-document-text",
}

function element(tag, className, label) {
  const el = document.createElement(tag)
  el.className = className
  if (label) el.textContent = label
  return el
}

export function link(href, label, className) {
  const anchor = element("a", className, label)
  anchor.href = href
  anchor.dataset.phxLink = "redirect"
  anchor.dataset.phxLinkState = "push"
  return anchor
}

function markTab(el, tab, previous) {
  const group = tabGroup(tab.kind)
  el.dataset.tabGroup = group
  if (previous && tabGroup(previous.kind) !== group) el.dataset.tabGroupStart = "true"
}

function markPending(item, anchor, pending) {
  if (pending) {
    item.dataset.tabPending = "true"
    anchor?.setAttribute("aria-busy", "true")
  } else if (item.dataset.tabPending || anchor?.hasAttribute("aria-busy")) {
    delete item.dataset.tabPending
    anchor?.removeAttribute("aria-busy")
  }
}

export const railMethods = {
  captureTab() {
    const data = this.el.dataset
    const url = new URL(location.href)
    const compose = Boolean(this.el.querySelector('#dashboard-root[data-workbench-compose="true"] #task-form'))
    const tab = this.navigation.moving ? undefined : routeTab(url, data, compose)
    this.routeConfirmed = tab !== undefined
    if (!tab) {
      // The new layout may arrive before the URL does. Don't overwrite the
      // stored tab or mark the requested tab current based on that patch.
      if (tab === null || !this.tabs.some(entry => entry.key === this.currentTab && entry.href === exactHref(url))) {
        this.currentTab = null
      }
      return
    }

    tab.node = this.node
    const scope = tab.draftScope || tab.projectScope
    tab.key = tabKey(this.node, scope || "", tab.kind, tab.id)
    if (this.navigation.isClosed(exactHref(url), tab.key)) {
      this.currentTab = null
      return
    }
    const previous = this.tabs.find(entry => entry.key === tab.key)
    tab.projectPath = scope || this.project || previous?.projectPath || ""
    if (tab.kind === "task") {
      // A focused inspector may identify the task before its project loads.
      // Keep the alias in its known rail, but accept a confirmed project change
      // without reusing the old project's label on the new path.
      const knownProject = previous?.projectPath === tab.projectPath ? previous.project : ""
      tab.project = this.projectLabel || knownProject || this.projectName
    } else {
      tab.project = this.projectName || previous?.project
    }
    tab.location = data.workbenchNodeName || previous?.location
    const row = this.rows.find(row => historyKey(this.node, row.dataset) === tab.key)
    tab.title = tab.title || row?.dataset.itemTitle || previous?.title || tab.id

    if (tab.kind === "chat" && data.workbenchDraft) {
      const draftKey = tabKey(this.node, data.workbenchDraftProject || this.project, "draft", data.workbenchDraft)
      this.tabs = this.tabs.filter(entry => !(entry.kind === "draft" && entry.node === this.node &&
        entry.id === data.workbenchDraft && (entry.key === draftKey || entry.key === this.currentTab)))
    }
    delete tab.draftScope
    delete tab.projectScope
    this.currentTab = tab.key
    this.tabs = openTab(this.tabs, tab, {preview: !alwaysPinned(tab.kind)})
    this.persistTabs()
  },

  tabsForProject(node, path) { return tabsForProject(this.tabs, node, path) },

  // A scoped draft or composer opened from a workspace keeps its URL scope,
  // even when the layout shows the workspace's resolved member path.
  projectScopePath() {
    const requested = new URLSearchParams(location.search).get("project")
    return this.tabs.find(tab => tab.key === this.currentTab)?.projectPath ||
      (requested?.startsWith("vct:///workspaces/") ? requested : this.project || "")
  },

  visibleTabs() { return this.tabsForProject(this.node, this.projectScopePath()) },

  pinTab(key) {
    this.tabs = pinTab(this.tabs, key)
    this.persistTabs()
    this.renderTabs()
  },

  railActiveKey() {
    return this.previewTab ? null : this.gitDiff ? GIT_DIFF_TAB : this.currentTab
  },

  railTabs() {
    const tabs = this.previewTab
      ? this.tabsForProject(this.previewTab.node, this.previewTab.projectPath) : this.visibleTabs()
    if (!this.gitDiff || this.previewTab) return tabs
    return [...tabs, {key: GIT_DIFF_TAB, kind: "diff", title: this.gitDiff, project: this.projectName}]
  },

  renderTabs() {
    const rail = this.el.querySelector("#workbench-tabs")
    if (!rail) return
    const activeKey = this.railActiveKey()
    const tabs = this.railTabs()
    const signature = JSON.stringify([activeKey, tabs])
    if (rail.dataset.signature === signature) return
    rail.dataset.signature = signature
    const focused = document.activeElement
    const focusedKey = rail.contains(focused) ? focused.closest("[data-tab-key]")?.dataset.tabKey : null
    const hint = this.el.dataset.workbenchKeepOpen || "Keep this tab open"
    rail.replaceChildren(...tabs.map((tab, i) => {
      const current = tab.key === activeKey
      const item = element("div", "workbench-tab")
      item.dataset.tabKey = tab.key
      markTab(item, tab, tabs[i - 1])
      const anchor = tab.kind === "diff" ? element("span", "workbench-tab-link") : link(tab.href, "", "workbench-tab-link")
      const icon = element("span", `${TAB_ICONS[tab.kind] || TAB_ICONS.project} workbench-tab-icon`)
      icon.setAttribute("aria-hidden", "true")
      anchor.append(icon, element("span", "truncate", tab.title))
      const duplicates = tabs.some(other => other.key !== tab.key && other.title === tab.title)
      if (duplicates && tab.location) anchor.append(element("span", "workbench-tab-instance", tab.location))
      anchor.title = [tab.location, tab.project, tab.title].filter(Boolean).join(" / ")
      if (tab.preview === true) {
        item.dataset.preview = "true"
        anchor.title += ` · ${hint}`
        anchor.setAttribute("aria-description", hint)
      }
      if (current) anchor.setAttribute("aria-current", "page")
      const close = element("button", "workbench-tab-close")
      const closeIcon = element("span", "hero-x-mark")
      closeIcon.setAttribute("aria-hidden", "true")
      close.append(closeIcon)
      close.type = "button"
      if (tab.kind === "diff") close.dataset.workbenchCloseGitDiff = "true"
      else close.dataset.workbenchCloseTab = tab.key
      close.setAttribute("aria-label", this.el.dataset.workbenchClose + " " + tab.title)
      item.classList.toggle("is-current", current)
      item.append(anchor, close)
      if (focusedKey === tab.key) {
        const target = focused.matches(".workbench-tab-close") ? close : anchor
        const revision = this.navigation.revision
        queueMicrotask(() => {
          if (target.isConnected && revision === this.navigation.revision && document.activeElement === document.body) {
            target.focus({preventScroll: true})
          }
        })
      }
      return item
    }))
    rail.querySelector(".is-current")?.scrollIntoView({block: "nearest", inline: "nearest"})
    this.syncTabOverflow()
    this.syncTabRailHints()
    this.paintPending()
  },

  syncTabOverflow() {
    const rail = this.el.querySelector("#workbench-tabs")
    const overflow = this.el.querySelector("#workbench-tabs-overflow")
    if (!rail || !overflow) return
    const overflows = rail.children.length > 0 && rail.scrollWidth > rail.clientWidth + 1
    overflow.hidden = !overflows
    if (!overflows) overflow.open = false
    else if (overflow.open) this.renderOverflowTabs()
  },

  // The Git diff is not navigable, so the overflow only lists stored tabs.
  renderOverflowTabs() {
    const list = this.el.querySelector("#workbench-tabs-overflow-list")
    if (!list) return
    const activeKey = this.railActiveKey()
    const tabs = this.railTabs().filter(tab => tab.kind !== "diff")
    const signature = JSON.stringify([activeKey, tabs])
    if (list.dataset.signature === signature) return
    list.dataset.signature = signature
    list.replaceChildren(...tabs.map((tab, i) => {
      const anchor = link(tab.href, "", "workbench-row")
      const icon = element("span", `${TAB_ICONS[tab.kind] || TAB_ICONS.project} workbench-tab-icon`)
      icon.setAttribute("aria-hidden", "true")
      anchor.dataset.workbenchTabOverflowKey = tab.key
      markTab(anchor, tab, tabs[i - 1])
      anchor.title = [tab.location, tab.project, tab.title].filter(Boolean).join(" / ")
      if (tab.key === activeKey) anchor.setAttribute("aria-current", "page")
      anchor.append(icon, element("span", "truncate", tab.title))
      return anchor
    }))
    this.paintPending()
  },

  paintPending() {
    const key = this.navigation.pending?.key
    for (const item of this.el.querySelectorAll("#workbench-tabs [data-tab-key], [data-workbench-tab-overflow-key]")) {
      const pending = key === (item.dataset.tabKey || item.dataset.workbenchTabOverflowKey)
      const anchor = item.dataset.tabKey ? item.querySelector("a.workbench-tab-link") : item
      markPending(item, anchor, pending)
    }
    this.paintHistoryPending()
  },

  paintHistoryPending(request = this.navigation.pending) {
    // Keep only the clicked DOM row, not every history alias of the tab key.
    if (!this.pendingHistory) return
    const {row, anchor, activation} = this.pendingHistory
    const pending = request === activation && this.el.contains(row) && row.contains(anchor) &&
      historyKey(this.node, row.dataset) === activation.key && anchor.getAttribute("href") === activation.href
    markPending(row, anchor, pending)
    anchor.classList.toggle("cursor-progress", pending)
    if (!pending) this.pendingHistory = null
  },

  syncTabRailHints() {
    const hints = [this.el.dataset.workbenchNextTab, this.el.dataset.workbenchPrevTab].filter(Boolean)
    const rail = this.el.querySelector("#workbench-tabs")
    if (hints.length) rail?.setAttribute("aria-description", hints.join(" · "))
    else rail?.removeAttribute("aria-description")
  },

  cycleTabWithKey(event) {
    const step = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0
    if (!step || !event.altKey || event.ctrlKey || event.metaKey || event.shiftKey || event.defaultPrevented) return false
    if (!event.target.closest("#workbench-tabs, #workbench-tabs-overflow")) return false
    if (event.target.closest("input, textarea, select, [contenteditable]")) return false
    const next = cycleTab(this.tabs, this.node, this.projectScopePath(), this.navigation.pending?.key || this.currentTab, step)
    if (!next) return false
    event.preventDefault()
    event.stopPropagation()
    this.navigate(next.href, {key: next.key, restoreFocus: true})
    return true
  },

  renderHistory() {
    // Row hrefs may move from /tasks to /review as tasks finish. The viewed
    // task (including a commit) is still the SAME task on the SAME node.
    for (const row of this.rows) {
      const current = this.currentTab === historyKey(this.node, row.dataset)
      const anchor = row.querySelector("[data-workbench-open]")
      anchor?.classList.toggle("is-current", current)
      if (current) anchor?.setAttribute("aria-current", "page")
      else anchor?.removeAttribute("aria-current")
    }
    this.paintHistoryPending()
  },
}
