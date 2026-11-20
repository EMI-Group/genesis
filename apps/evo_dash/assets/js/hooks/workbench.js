import {projectPreview} from "./workbench_project_preview"

const TAB_KEY = "genesis-workbench.tabs.v1"
const ACCENT_KEY = "genesis-workbench.accent"
const SIDEBAR_WIDTHS_KEY = "genesis-workbench.sidebar-widths"
const SIDEBAR_WIDTHS = {
  left: {default: 256, min: 192, max: 480},
  right: {default: 336, min: 264, max: 640},
}
const CENTER_MIN_WIDTH = 480
const GIT_DIFF_TAB = "workbench-git-diff"
let projectSidebarScrollTop = 0
const TAB_ICONS = {
  task: "hero-clipboard-document",
  chat: "hero-chat-bubble-left",
  draft: "hero-chat-bubble-left",
  assistant: "hero-chat-bubble-left",
  project: "hero-folder",
  diff: "hero-document-text",
}
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

function element(tag, className, label) {
  const el = document.createElement(tag)
  if (className) el.className = className
  if (label) el.textContent = label
  return el
}

function link(href, label, className) {
  const anchor = element("a", className, label)
  anchor.href = href
  anchor.dataset.phxLink = "redirect"
  anchor.dataset.phxLinkState = "push"
  return anchor
}

function safeHref(value) {
  if (typeof value !== "string" || !value.startsWith("/") || value.startsWith("//")) return false
  const url = new URL(value, location.origin)
  return url.origin === location.origin &&
    (/^\/(projects|tasks|assistant)$/.test(url.pathname) || url.pathname.startsWith("/review/"))
}

const Workbench = {
  mounted() {
    this.tabs = read(sessionStorage, TAB_KEY, [])
    if (!Array.isArray(this.tabs)) this.tabs = []
    const restored = new Map()
    for (const tab of this.tabs) {
      if (!tab || !safeHref(tab.href)) continue
      const url = new URL(tab.href, location.origin)
      const legacy = url.searchParams.has("wb_workspace")
      url.searchParams.delete("wb_workspace")
      tab.node = url.searchParams.get("node") || ""
      tab.projectPath = typeof tab.projectPath === "string" ? tab.projectPath : ""
      if (tab.kind === "project") {
        if (url.searchParams.get("wb_task") !== "1") continue
        const project = url.searchParams.get("project")
        if (!project) continue
        tab.id = ""
        tab.projectPath = project
        tab.key = JSON.stringify([tab.node, project, "project", ""])
        if (legacy) tab.title = tab.project || tab.title
      } else if (tab.kind === "draft") {
        tab.projectPath = url.searchParams.get("wb_project") || ""
      }
      tab.href = url.pathname + url.search
      restored.set(tab.key, tab)
    }
    this.tabs = [...restored.values()]
    write(sessionStorage, TAB_KEY, this.tabs)
    this.kind = "task"
    this.historyQuery = ""
    this.historySearchOpen = false
    this.scope = null
    this.historyPreference = read(sessionStorage, "genesis-workbench.history", null)
    this.media = matchMedia(WIDE)
    this.historyOpen = this.media.matches && this.historyPreference !== false
    this.gitOpen = this.media.matches && read(sessionStorage, "genesis-workbench.git", false)
    this.gitLoadedScope = null
    this.sidebarWidths = read(localStorage, SIDEBAR_WIDTHS_KEY, {})
    this.sidebarDrag = null
    this.onViewportResize = () => {
      this.syncSidebarWidths()
      projectPreview.reposition(this.el)
      this.positionCreateMenu()
    }
    this.onResize = () => {
      this.historyOpen = this.media.matches && this.historyPreference !== false
      this.syncHistoryPanel()
    }
    this.onClick = event => this.click(event)
    this.onInput = event => {
      if (event.target.id !== "workbench-history-search") return
      this.historyQuery = event.target.value
      this.renderHistory()
    }
    this.onPointerDown = event => {
      this.pressedBackdrop =
        event.target.matches("dialog.workbench-window[open]")
          ? event.target
          : null
      this.beginSidebarResize(event)
    }
    this.onPointerMove = event => this.moveSidebarResize(event)
    this.onPointerEnd = event => this.endSidebarResize(event)
    this.onCreateToggle = event => {
      if (event.target.id === "workbench-create" && event.target.open) this.positionCreateMenu()
    }
    this.onOutsideCreate = event => {
      const menu = this.el.querySelector("#workbench-create[open]")
      if (menu && !menu.contains(event.target)) menu.open = false
    }
    this.onKey = event => {
      if (this.resizeSidebarWithKey(event)) return
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
      const create = event.target.closest("#workbench-create[open]")
      if (create) {
        create.open = false
        create.querySelector("summary")?.focus()
        event.preventDefault()
      } else if (event.target.id === "workbench-history-search") {
        this.setHistorySearch(false, true)
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
    this.onNavigation = () => this.sync()
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
          event.data === "genesis:close-settings-window") this.settingsWindow?.close()
    }
    this.onSettingsClose = () => {
      this.settingsFrame?.removeAttribute("src")
      if (this.reloadTaskModels && this.el.querySelector("#task-model-setup")) {
        this.pushEvent("retry_model_selection", {})
      }
      this.reloadTaskModels = false
    }
    this.settingsWindow?.addEventListener("close", this.onSettingsClose)
    window.addEventListener("message", this.onWindowMessage)
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("pointerdown", this.onPointerDown)
    this.el.addEventListener("pointermove", this.onPointerMove)
    this.el.addEventListener("pointerup", this.onPointerEnd)
    this.el.addEventListener("pointercancel", this.onPointerEnd)
    this.el.addEventListener("lostpointercapture", this.onPointerEnd)
    this.el.addEventListener("toggle", this.onCreateToggle, true)
    window.addEventListener("resize", this.onViewportResize)
    document.addEventListener("click", this.onOutsideCreate)
    this.el.addEventListener("workbench:section", this.onNavigation)
    this.el.addEventListener("keydown", this.onKey)
    this.media.addEventListener("change", this.onResize)
    window.addEventListener("phx:page-loading-stop", this.onNavigation)
    window.addEventListener("storage", this.onStorage)
    this.sync()
    if (this.projectSidebarNav) this.projectSidebarNav.scrollTop = projectSidebarScrollTop
  },

  updated() {
    this.sync()
  },

  destroyed() {
    this.projectSidebarNav?.removeEventListener("scroll", this.onProjectSidebarScroll)
    this.settingsWindow?.removeEventListener("close", this.onSettingsClose)
    window.removeEventListener("message", this.onWindowMessage)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    this.el.removeEventListener("pointermove", this.onPointerMove)
    this.el.removeEventListener("pointerup", this.onPointerEnd)
    this.el.removeEventListener("pointercancel", this.onPointerEnd)
    this.el.removeEventListener("lostpointercapture", this.onPointerEnd)
    this.el.removeEventListener("toggle", this.onCreateToggle, true)
    window.removeEventListener("resize", this.onViewportResize)
    document.removeEventListener("click", this.onOutsideCreate)
    this.el.removeEventListener("workbench:section", this.onNavigation)
    this.el.removeEventListener("keydown", this.onKey)
    this.media.removeEventListener("change", this.onResize)
    window.removeEventListener("phx:page-loading-stop", this.onNavigation)
    window.removeEventListener("storage", this.onStorage)
  },

  sync() {
    applyAccent(this.el)
    const data = this.el.dataset
    const scope = JSON.stringify([data.workbenchNode, data.workbenchProject])
    if (scope !== this.scope) {
      this.scope = scope
      this.historyQuery = ""
      this.historySearchOpen = false
    }
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
    this.renderProjectWindows()
    this.renderHistory()
    this.syncEmptyState()
    this.syncHistoryPanel()
    this.syncSidebarWidths()
    this.syncGitStatus()
    this.syncGitDiffFocus()
    this.positionCreateMenu()
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

  captureTab() {
    const data = this.el.dataset
    const task = data.workbenchTask
    const session = data.workbenchSession
    const draft = data.workbenchDraft
    const draftProject = data.workbenchDraftProject || this.project
    let tab
    if (task) {
      const href = data.workbenchPage === "review" && location.pathname.startsWith("/review/")
        ? location.pathname + location.search
        : route("/tasks", this.node, {task})
      tab = {kind: "task", id: task, href, title: data.workbenchTitle}
    } else if (session) {
      tab = {kind: "chat", id: session, href: route("/assistant", this.node, {session})}
    } else if (draft) {
      if (!draftProject) {
        this.currentTab = null
        return
      }
      tab = {kind: "draft", id: draft, href: route("/assistant", this.node,
        {wb_draft: draft, wb_project: draftProject}), title: data.workbenchNewChat}
    } else if (data.workbenchPage === "assistant") {
      // A scoped assistant route may render before its session or draft is assigned.
      const url = new URL(location.href)
      if (url.searchParams.has("session") || url.searchParams.has("wb_draft")) {
        this.currentTab = this.tabs.find(entry => entry.href === url.pathname + url.search)?.key
        return
      }
      tab = {kind: "assistant", id: "", href: route("/assistant", this.node), title: data.workbenchChats}
    } else if (data.workbenchPage === "dashboard" && this.project &&
        this.el.querySelector('#dashboard-root[data-workbench-compose="true"] #task-form')) {
      const params = {project: this.project, wb_task: "1"}
      if (data.workbenchGitBranch && data.workbenchStartingCommit) {
        params.wb_git_branch = data.workbenchGitBranch
        params.starting_commit = data.workbenchStartingCommit
      }
      const href = route("/projects", this.node, params)
      tab = {kind: "project", id: "", href, title: data.workbenchNewTask}
    }

    if (!tab) {
      this.currentTab = null
      return
    }

    const tabProject = tab.kind === "draft" ? draftProject : tab.kind === "project" ? this.project : ""
    tab.key = JSON.stringify([this.node, tabProject, tab.kind, tab.id])
    tab.location = data.workbenchNodeName
    const previous = this.tabs.find(entry => entry.key === tab.key)
    tab.node = this.node
    // Focused tasks can render before their project is loaded asynchronously.
    tab.projectPath = (tab.kind === "draft" ? draftProject : this.project) || previous?.projectPath || ""
    tab.project = this.projectName || previous?.project
    const row = this.rows.find(row => row.dataset.workbenchItem === tab.kind && row.dataset.itemId === tab.id)
    tab.title = tab.title || row?.dataset.itemTitle || previous?.title || tab.id

    if (session && draft && draftProject) {
      const draftKey = JSON.stringify([this.node, draftProject, "draft", draft])
      this.tabs = this.tabs.filter(entry => entry.key !== draftKey)
    }

    this.currentTab = tab.key
    this.saveTab(tab)
  },

  tabsForProject(node, projectPath) {
    return this.tabs.filter(tab => tab.node === node && tab.projectPath === projectPath)
  },

  visibleTabs() {
    const current = this.tabs.find(tab => tab.key === this.currentTab)
    return this.tabsForProject(this.node, this.project || current?.projectPath || "")
  },

  saveTab(tab) {
    const projectTabs = this.tabsForProject(tab.node, tab.projectPath)
    const index = this.tabs.findIndex(entry => entry.key === tab.key)
    for (const entry of projectTabs) delete entry.active
    tab.active = true

    if (index < 0) {
      if (projectTabs.length >= 40) this.tabs = this.tabs.filter(entry => entry !== projectTabs[0])
      this.tabs.push(tab)
    } else {
      this.tabs[index] = tab
    }
    write(sessionStorage, TAB_KEY, this.tabs)
  },

  renderTabs() {
    const rail = this.el.querySelector("#workbench-tabs")
    if (!rail) return

    const activeKey = this.previewTab?.key || (this.gitDiff ? GIT_DIFF_TAB : this.currentTab)
    const preview = {key: GIT_DIFF_TAB, kind: "diff", title: this.gitDiff, project: this.projectName}
    const projectTabs = this.previewTab
      ? this.tabsForProject(this.previewTab.node, this.previewTab.projectPath) : this.visibleTabs()
    const tabs = this.gitDiff && !this.previewTab ? [...projectTabs, preview] : projectTabs
    const signature = JSON.stringify([activeKey, tabs])
    if (rail.dataset.signature === signature) return
    rail.dataset.signature = signature
    const focused = document.activeElement
    const focusedKey = rail.contains(focused) ? focused.closest("[data-tab-key]")?.dataset.tabKey : null
    const focusedClose = focused?.matches(".workbench-tab-close")
    rail.replaceChildren(...tabs.map(tab => {
      const item = element("div", "workbench-tab")
      item.dataset.tabKey = tab.key
      const current = tab.key === activeKey
      const anchor = tab.kind === "diff" ? element("span", "workbench-tab-link") : link(tab.href, "", "workbench-tab-link")
      const icon = element("span", `${TAB_ICONS[tab.kind] || TAB_ICONS.project} workbench-tab-icon`)
      icon.setAttribute("aria-hidden", "true")
      anchor.append(icon, element("span", "truncate", tab.title))
      const duplicates = tabs.some(other => other.key !== tab.key && other.title === tab.title)
      if (duplicates && tab.location) anchor.append(element("span", "workbench-tab-instance", tab.location))
      anchor.title = [tab.location, tab.project, tab.title].filter(Boolean).join(" / ")
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
      if (focusedKey === tab.key) queueMicrotask(() => (focusedClose ? close : anchor).focus({preventScroll: true}))
      return item
    }))
    rail.querySelector(".is-current")?.scrollIntoView({block: "nearest", inline: "nearest"})
  },

  renderProjectWindows() {
    const activeKey = this.previewTab?.key || this.currentTab
    const active = this.previewTab || {node: this.node, projectPath: this.project}
    this.el.querySelectorAll("[data-workbench-project-row]").forEach(row => {
      const projectLink = row.querySelector(".workbench-project-link")
      const project = projectLink.dataset
      const selected = active.node === project.workbenchNode && active.projectPath === project.workbenchProject
      if (selected) projectLink.setAttribute("aria-current", "page")
      else projectLink.removeAttribute("aria-current")
      projectLink.classList.toggle("is-current", selected)
      const windows = row.querySelector("[data-workbench-project-windows]")
      const tabs = this.tabsForProject(project.workbenchNode, project.workbenchProject)
      const openItems = new Set(tabs.map(tab => `${tab.kind}:${tab.id}`))
      row.querySelectorAll("[data-project-activity-id]").forEach(activity => {
        const {projectActivityKind, projectActivityId} = activity.dataset
        activity.hidden = openItems.has(`${projectActivityKind}:${projectActivityId}`)
      })
      const signature = JSON.stringify([tabs.some(tab => tab.key === activeKey) && activeKey, tabs])
      if (windows.dataset.signature === signature) return
      windows.dataset.signature = signature
      const focusedKey = windows.contains(document.activeElement) && document.activeElement.dataset.workbenchWindow
      windows.replaceChildren(...tabs.map(tab => {
        const anchor = link(tab.href, "", "workbench-row workbench-project-window-link")
        const icon = element("span", `${TAB_ICONS[tab.kind]} workbench-tab-icon`)
        icon.setAttribute("aria-hidden", "true")
        anchor.append(icon, element("span", "truncate", tab.title))
        anchor.dataset.workbenchWindow = tab.key
        anchor.dataset.workbenchOpen = ""
        anchor.title = tab.title
        if (tab.key === activeKey) {
          anchor.setAttribute("aria-current", "page")
          anchor.classList.add("is-current")
        }
        if (tab.key === focusedKey) queueMicrotask(() => anchor.focus({preventScroll: true}))
        return anchor
      }))
    })
  },

  setHistorySearch(open, focus = false) {
    this.historySearchOpen = open
    if (!open) this.historyQuery = ""
    this.renderHistory()
    if (focus) this.el.querySelector(open ? "#workbench-history-search" : "#workbench-history-search-toggle")?.focus()
  },

  renderHistory() {
    const project = this.el.querySelector("#workbench-history-project")
    if (project && project.textContent !== (this.projectName || "")) project.textContent = this.projectName || ""
    const search = this.el.querySelector("#workbench-history-search")
    if (search) {
      this.el.querySelector("#workbench-history-query").hidden = !this.historySearchOpen
      if (!this.historySearchOpen || document.activeElement !== search) search.value = this.historyQuery
    }
    this.el.querySelector("#workbench-history-search-toggle")
      ?.setAttribute("aria-expanded", String(this.historySearchOpen))
    const query = this.historyQuery.trim().toLocaleLowerCase()
    const more = this.el.querySelector("[data-workbench-more]")
    if (more) more.hidden = this.kind !== "task"
    this.el.querySelectorAll("[data-workbench-kind]").forEach(button =>
      button.setAttribute("aria-pressed", String(button.dataset.workbenchKind === this.kind)))
    let visible = 0
    for (const row of this.rows) {
      const kind = row.dataset.workbenchItem
      const matches = (row.dataset.itemTitle + " " + row.dataset.itemState).toLocaleLowerCase().includes(query)
      row.hidden = kind !== this.kind || !matches
      const current = this.currentTab === JSON.stringify([this.node, "", kind, row.dataset.itemId])
      row.querySelector("[data-workbench-open]")?.classList.toggle("is-current", current)
      if (!row.hidden) visible++
    }
    const empty = this.el.querySelector("[data-workbench-empty]")
    if (empty) empty.hidden = visible > 0 || empty.parentElement.dataset.loading === "true"
  },

  syncHistoryPanel() {
    const panel = this.el.querySelector("#workbench-history")
    if (!panel) return
    const git = this.el.querySelector("#workbench-git")
    const gitOpen = Boolean(git && this.gitOpen && this.project)
    const assistantDefault = this.el.dataset.workbenchPage === "assistant" &&
      this.media.matches && this.historyPreference === null
    const open = this.historyOpen && Boolean(this.project) && !gitOpen && !assistantDefault
    panel.hidden = !open
    if (git) git.hidden = !gitOpen
    const drawerOpen = (open || gitOpen) && !this.media.matches
    const resizer = this.el.querySelector("#workbench-right-resize")
    if (resizer) resizer.hidden = drawerOpen || !(open || gitOpen)
    this.el.querySelector("#workbench-history-overlay").hidden = !drawerOpen
    this.el.querySelector(".workbench-center").inert = drawerOpen || Boolean(this.previewTab)
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
    if (this.media.matches) {
      this.historyPreference = open
      write(sessionStorage, "genesis-workbench.history", open)
    }
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
    if (this.media.matches) write(sessionStorage, "genesis-workbench.git", open)
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
    this.renderProjectWindows()
    this.syncHistoryPanel()
  },

  click(event) {
    if (event.target === this.pressedBackdrop) {
      this.pressedBackdrop.close()
      return
    }
    const trigger = event.target.closest("button, a")
    if (!trigger) return
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
        if (active.key !== this.currentTab || navigating) this.navigate(active.href)
        else if (this.gitDiff) this.closeGitDiff()
        return
      }
    }
    if (trigger.dataset.workbenchWindow &&
        !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
      const tab = this.tabs.find(tab => tab.key === trigger.dataset.workbenchWindow)
      if (tab) {
        event.preventDefault()
        event.stopPropagation()
        if (!this.media.matches) this.setHistory(false)
        this.switchProject(tab)
        this.navigate(tab.href)
        return
      }
    }
    if (this.gitDiff && trigger.matches("a.workbench-tab-link") &&
        trigger.closest("[data-tab-key]")?.dataset.tabKey === this.currentTab &&
        !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
      event.preventDefault()
      event.stopPropagation()
      this.closeGitDiff()
      return
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
    if (trigger.id === "workbench-history-search-toggle") this.setHistorySearch(!this.historySearchOpen, true)
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
    if ("workbenchKind" in trigger.dataset) {
      this.kind = trigger.dataset.workbenchKind
      this.renderHistory()
    }
    if (trigger.dataset.workbenchSettings && this.settingsWindow && !this.settingsWindow.open &&
        !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
      event.preventDefault()
      this.reloadTaskModels = trigger.id === "task-model-setup"
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
    if ("workbenchCloseWindow" in trigger.dataset) trigger.closest("dialog")?.close()
    if ("workbenchOpen" in trigger.dataset && !this.media.matches) this.setHistory(false)
    if ("workbenchCloseTab" in trigger.dataset) this.closeTab(trigger.dataset.workbenchCloseTab, event.detail === 0)
  },

  closeTab(key, restoreFocus) {
    const tabs = this.visibleTabs()
    const index = tabs.findIndex(tab => tab.key === key)
    if (index < 0) return
    const closed = tabs[index]
    projectPreview.forget(closed)
    if (closed.kind === "draft") {
      this.pushEventTo("#workbench-projects", "discard_assistant_draft", {id: closed.id})
    }
    this.tabs = this.tabs.filter(tab => tab.key !== key)
    const next = tabs[index + 1] || tabs[index - 1]
    write(sessionStorage, TAB_KEY, this.tabs)
    this.renderTabs()
    this.renderProjectWindows()

    const focusNext = () => {
      const root = document.getElementById("app-layout")
      const tab = next && root?.querySelector(`[data-tab-key="${CSS.escape(next.key)}"] .workbench-tab-link`)
      const control = tab || root?.querySelector("#workbench-create-toggle")
      control?.focus()
    }
    if (key === this.currentTab) {
      const blank = closed.projectPath ? {wb_home: "1", project: closed.projectPath} : {wb_home: "1"}
      if (restoreFocus) {
        window.addEventListener("phx:page-loading-stop", () => requestAnimationFrame(focusNext), {once: true})
      }
      this.navigate(next?.href || route("/projects", this.node, blank))
    } else if (restoreFocus) {
      focusNext()
    }
  },

  navigate(href) {
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
