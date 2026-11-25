import {safeHref, tabKey, TAB_BASE_URL} from "./workbench_tabs"

const localNode = node => node === "local" ? "" : node || ""
const projectsPage = path => path === "/projects" || path === "/"

function sameProjectEntry(from, to) {
  const old = new URL(from, TAB_BASE_URL)
  const next = new URL(to, TAB_BASE_URL)
  return projectsPage(old.pathname) && projectsPage(next.pathname) &&
    localNode(old.searchParams.get("node")) === localNode(next.searchParams.get("node")) &&
    old.searchParams.get("project") === next.searchParams.get("project")
}

export const exactHref = url => url.pathname + url.search + url.hash

// A patch can replace the route metadata BEFORE LiveView updates history.
// Only a matching URL and layout may capture a tab or confirm activation.
export function routeTab(url, data, compose) {
  const params = url.searchParams
  const node = data.workbenchNode || ""
  if (localNode(node) !== localNode(params.get("node"))) return undefined
  const page = data.workbenchPage
  const review = /^\/review\/([^/]+)(?:\/commit\/[^/]+)?$/.exec(url.pathname)
  const queryTaskPage = url.pathname === "/agents" ? "agents" : url.pathname === "/tasks" ? "tasks" : null
  const task = queryTaskPage ? params.get("task") : decoded(review?.[1])
  const session = params.get("session")
  const draft = params.get("wb_draft")
  const project = params.get("wb_project")
  const href = exactHref(url)
  if (task) {
    if (page === (review ? "review" : queryTaskPage) && task === data.workbenchTask) {
      return {kind: "task", id: task, href, title: data.workbenchTitle}
    }
    return undefined
  }
  if (data.workbenchTask || review) return undefined
  // The global inspector is not a task view, even when an agent is selected.
  if (url.pathname === "/agents") return page === "agents" ? null : undefined
  if (url.pathname === "/assistant") {
    if (page !== "assistant") return undefined
    if (session || data.workbenchSession) {
      if (session && session === data.workbenchSession) return {kind: "chat", id: session, href}
      return undefined
    }
    if (draft || data.workbenchDraft) {
      if (draft && draft === data.workbenchDraft && project) {
        return {kind: "draft", id: draft, href, title: data.workbenchNewChat, draftScope: project}
      }
      return undefined
    }
    return {kind: "assistant", id: "", href, title: data.workbenchChats}
  }
  if (projectsPage(url.pathname)) {
    if (page !== "dashboard" || data.workbenchSession || data.workbenchDraft) return undefined
    const composeIntent = !params.has("wb_home") && (params.get("wb_task") === "1" ||
      params.get("resume_from")?.trim() || params.get("starting_commit")?.trim())
    if (Boolean(composeIntent) !== compose) return undefined
    if (compose) {
      const requested = params.get("project")
      if (!requested || (requested !== data.workbenchProject && !requested.startsWith("vct:///workspaces/"))) return undefined
      return {kind: "project", id: "", href: url.pathname === "/" ? "/projects" + url.search + url.hash : href,
        title: data.workbenchNewTask, projectScope: requested}
    }
  }
  return null
}

function decoded(segment) {
  if (!segment) return null
  try { return decodeURIComponent(segment) } catch { return null }
}

export function historyKey(node, row) {
  return tabKey(node, "", row.workbenchItem, row.itemId)
}

export function defaultDraftHref(url, data, occupied) {
  const href = data.workbenchDefaultDraft
  if (occupied || !safeHref(href, url.origin) ||
      data.workbenchPage !== "dashboard" || data.workbenchTask || data.workbenchSession || data.workbenchDraft ||
      !projectsPage(url.pathname) || localNode(data.workbenchNode) !== localNode(url.searchParams.get("node")) ||
      ["wb_home", "wb_task", "resume_from", "starting_commit", "task", "session", "wb_draft"].some(name => url.searchParams.has(name))) return null
  const draft = new URL(href, url.origin)
  const selected = url.searchParams.get("project")
  const scope = draft.searchParams.get("wb_project")
  const project = data.workbenchProject
  const names = [...draft.searchParams.keys()]
  if (draft.pathname !== "/assistant" || draft.hash || !scope ||
      (selected && selected !== scope && selected !== project) ||
      (project && scope !== project && scope !== selected && !scope.startsWith("vct:///workspaces/")) ||
      !/^[0-9a-f]{24}$/.test(draft.searchParams.get("wb_draft") || "") ||
      localNode(draft.searchParams.get("node")) !== localNode(data.workbenchNode) ||
      new Set(names).size !== names.length || names.some(name => !["wb_project", "wb_draft", "node"].includes(name))) return null
  return href
}

// State lives across LiveView remounts, not history entries or browser tabs.
// A loading-stop event is never used as evidence that an activation arrived.
export function navigationState({timeout = 10000, setTimer = setTimeout, clearTimer = clearTimeout} = {}) {
  let pending, moving, traversal, attempted, timer, revision = 0
  const superseded = new Set()
  // A close can't abort LiveView's request. Keep its exact route suppressed
  // across late commits and remounts, until a new user intent for that route.
  const closed = new Map()
  const clear = () => {
    clearTimer(timer)
    pending = moving = null
    revision++
  }
  const advance = (href, repaint) => {
    if (moving && moving !== href) superseded.add(moving)
    superseded.delete(href)
    clear()
    moving = href
    timer = setTimer(() => { clear(); superseded.clear(); repaint() }, timeout)
  }
  return {
    get pending() { return pending },
    get moving() { return moving },
    get revision() { return revision },
    isClosed(href, key) { return closed.get(href) === key },
    reopenCurrent(href) {
      if (!closed.delete(href)) return false
      clear()
      return true
    },
    cancelPending(key) {
      if (!pending || pending.key !== key) return
      closed.set(pending.href, key)
      clear()
    },
    disconnect: clear,
    request(href, key, focus, repaint) {
      const reopened = closed.delete(href)
      advance(href, repaint)
      pending = {href, key, focus}
      return reopened
    },
    start(href, repaint, announced = false) {
      if (announced) closed.delete(href)
      if (closed.has(href) || moving === href || (!announced && superseded.has(href))) return
      advance(href, repaint)
    },
    commit(href) {
      if (closed.has(href)) return
      const target = moving || pending?.href
      if (target && href !== target) {
        if (superseded.has(href)) return
        // A server redirect/patch can legitimately supersede our request
        // without a loading-start. Its actual URL wins, but not our focus.
        clear()
      }
      // A server-only canonical patch (e.g. equivalent query encoding) is
      // still the Back landing, not a new user entry eligible for auto-open.
      if (traversal && href !== traversal) traversal = !moving && sameProjectEntry(traversal, href) ? href : null
      if (attempted && href !== attempted.href) {
        attempted = !moving && sameProjectEntry(attempted.href, href) ? {...attempted, href} : null
      }
      moving = null
      superseded.clear()
      if (!pending) clearTimer(timer)
    },
    traverse(href) {
      if (moving && moving !== href) superseded.add(moving)
      closed.delete(href)
      clear()
      traversal = href
    },
    confirm(href, key) {
      if (moving || !pending || pending.href !== href || pending.key !== key) return null
      const confirmed = pending
      clear()
      return confirmed
    },
    claimDefault(href, scope) {
      if (moving || pending || traversal === href || (attempted?.href === href && attempted.scope === scope)) return false
      attempted = {href, scope}
      return true
    },
  }
}

export function sameTabClick(event, anchor) {
  return !event.defaultPrevented && event.button === 0 && !event.altKey && !event.ctrlKey &&
    !event.metaKey && !event.shiftKey && (!anchor.target || anchor.target === "_self") && !anchor.hasAttribute("download")
}
