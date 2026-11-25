// The pure tab-store half of the workbench tab rail: the persisted open-tab
// list and every decision about it (restore, preview replacement, pin, close,
// eviction, cycling). The DOM half lives in workbench.js, which owns the
// storage, the anchor validator's origin and the rendering; everything between
// the markers below is total and side-effect free — no document, window,
// location, sessionStorage, clipboard or timers — so
// `workbench_tabs.test.cjs` can run THIS source through node:vm with `URL` as
// its only global (the workbench_panel.test.cjs convention).

// --- WorkbenchTabs: pure tab store
// One tab is a plain, string-valued record:
//   {key, kind, id, node, projectPath, project, title, location, href,
//    preview?, active?}
// `key` is `JSON.stringify([node, projectPath, kind, id])`, so it encodes the
// scope: tabs of different projects (or BEAM nodes) never collide and never see
// each other.
const MAX_TABS_PER_PROJECT = 40
// Only used to resolve a RELATIVE persisted href into `.pathname`/`.search`;
// the origin is never read back and never compared against a real page.
const TAB_BASE_URL = "https://workbench.invalid"

// `draft` (an unsent conversation), `project` (a project's task form),
// `assistant` (the unscoped chat) and the client-only Git `diff` view are ALWAYS
// pinned: each is a place the user deliberately parked, so a preview — a mere
// look at a task or conversation — must never replace one.
function alwaysPinned(kind) {
  return kind === "draft" || kind === "project" || kind === "assistant" || kind === "diff"
}

// One normalised string per field: `undefined`, `null` and a missing field all
// read the same, so no decision depends on how a record was produced.
function probe(value) {
  return value === undefined || value === null ? "" : String(value)
}

function safeList(value) {
  return Array.isArray(value) ? value : []
}

// A fresh, caller-owned array of fresh records: no exported function below ever
// mutates its input.
function copyList(tabs) {
  return safeList(tabs)
    .filter(entry => entry && typeof entry === "object")
    .map(entry => ({...entry}))
}

function tabKey(node, projectPath, kind, id) {
  return JSON.stringify([probe(node), probe(projectPath), probe(kind), probe(id)])
}

function sameScope(left, right) {
  return probe(left?.node) === probe(right?.node) &&
    probe(left?.projectPath) === probe(right?.projectPath)
}

// An href is only ever followed when it stays inside this dashboard: an
// absolute path to one of the four destinations (or a review deep link) on the
// SAME origin. A persisted href is untrusted input, so everything else is
// dropped instead of navigated to.
function safeHref(value, origin) {
  if (typeof value !== "string" || !value.startsWith("/") || value.startsWith("//")) return false
  try {
    const url = new URL(value, origin || TAB_BASE_URL)
    const base = new URL(origin || TAB_BASE_URL)
    return url.origin === base.origin &&
      (/^\/(projects|tasks|assistant)$/.test(url.pathname) || url.pathname.startsWith("/review/"))
  } catch {
    return false
  }
}

function defaultHref(value) {
  return typeof value === "string" && value.startsWith("/") && !value.startsWith("//")
}

// One project's tabs, in rail order.
function tabsForProject(tabs, node, projectPath) {
  const scoped = {node, projectPath}
  return safeList(tabs).filter(tab => tab && sameScope(tab, scoped))
}

// Restore the persisted list. `raw` is whatever `JSON.parse` produced — a list,
// a JSON string, or garbage — and `validate(href)` decides whether a persisted
// href may be followed (the hook passes `safeHref` bound to its own origin).
// Every entry is re-normalised from its OWN href, then RE-KEYED from its fields
// so a stale or hand-edited key can never address the wrong tab, and duplicates
// collapse last-wins (the persisted list is append-ordered).
function restore(raw, validate) {
  let list = raw
  if (typeof list === "string") {
    try {
      list = JSON.parse(list)
    } catch {
      return []
    }
  }
  const accept = typeof validate === "function" ? validate : defaultHref
  const restored = new Map()
  for (const entry of safeList(list)) {
    const tab = normaliseStored(entry, accept)
    if (tab) restored.set(tab.key, tab)
  }
  return [...restored.values()]
}

function normaliseStored(entry, accept) {
  if (!entry || typeof entry !== "object") return null
  const kind = probe(entry.kind)
  if (!kind) return null
  if (!accept(entry.href)) return null
  let url
  try {
    url = new URL(entry.href, TAB_BASE_URL)
  } catch {
    return null
  }
  // `wb_workspace` was a legacy single-project scope param: it only ever scoped
  // the view, so dropping it keeps the href addressable.
  const legacy = url.searchParams.has("wb_workspace")
  url.searchParams.delete("wb_workspace")
  const tab = {
    kind,
    id: probe(entry.id),
    node: url.searchParams.get("node") || "",
    projectPath: typeof entry.projectPath === "string" ? entry.projectPath : "",
    project: probe(entry.project),
    title: probe(entry.title),
    location: probe(entry.location),
    href: url.pathname + url.search,
    preview: entry.preview === true,
    active: entry.active === true,
  }
  if (kind === "project") {
    // A project tab is ONE project's task form: it carries no id and its scope
    // lives in the href itself, so a stored projectPath is not trusted.
    if (url.searchParams.get("wb_task") !== "1") return null
    const project = url.searchParams.get("project")
    if (!project) return null
    tab.id = ""
    tab.projectPath = project
    if (legacy) tab.title = tab.project || tab.title
  } else if (kind === "draft") {
    // A draft belongs to the project it was started FROM, which the href knows.
    tab.projectPath = url.searchParams.get("wb_project") || ""
  }
  tab.key = tabKey(tab.node, tab.projectPath, tab.kind, tab.id)
  if (alwaysPinned(tab.kind)) tab.preview = false
  return tab
}

// Mark ONE tab active within its own project (the rail's "current" marker is
// derived per page, so the store only remembers where a project was left).
function markActive(list, key) {
  const target = list.find(entry => entry?.key === key)
  if (!target) return list
  for (const entry of list) if (sameScope(entry, target)) delete entry.active
  target.active = true
  return list
}

function activate(tabs, key) {
  return markActive(copyList(tabs), key)
}

// Trim ONE project down to MAX_TABS_PER_PROJECT. The eviction order IS the
// contract:
//   1. the project's OLDEST preview tab — the reuse slot is disposable, a
//      pinned tab is a deliberate choice;
//   2. else the OLDEST tab that is neither the ACTIVE tab nor a `draft`;
//   3. else the OLDEST tab that is not the ACTIVE tab (a draft, when there is
//      nothing else left to give);
//   4. else nothing: the ACTIVE tab is never evicted, so a project holding
//      nothing but its active tab stays over the cap.
function trimProject(list, scope) {
  let trimmed = list
  while (true) {
    const mine = tabsForProject(trimmed, scope.node, scope.projectPath)
    if (mine.length <= MAX_TABS_PER_PROJECT) return trimmed
    const victim = evictionVictim(mine)
    if (!victim) return trimmed
    trimmed = trimmed.filter(entry => entry !== victim)
  }
}

function evictionVictim(projectTabs) {
  const disposable = projectTabs.filter(tab => tab.active !== true)
  if (!disposable.length) return null
  return disposable.find(tab => tab.preview === true) ||
    disposable.find(tab => tab.kind !== "draft") ||
    disposable[0]
}

// Open (or re-open) one tab; returns a NEW list, never mutating the input.
//
// `options.preview` marks a tab a LATER preview may replace in place (the hook
// passes it for `task`/`chat`); the always-pinned kinds ignore it. The order of
// decisions is the VS Code model:
//   1. an already-open KEY is UPDATED in place and selected — never duplicated
//      and never re-flagged, so pinning survives every later navigation;
//   2. the same HREF under another key is the same view: select that one
//      instead of adding a twin;
//   3. a new PREVIEW replaces the project's existing preview AT ITS POSITION,
//      so the reuse slot never walks along the strip; anything else APPENDS;
//   4. the project is trimmed to MAX_TABS_PER_PROJECT.
function openTab(tabs, tab, options) {
  const list = copyList(tabs)
  if (!tab || typeof tab !== "object") return list
  const next = scopedTab(tab, options)
  if (!next.key || !next.kind) return list

  const index = list.findIndex(entry => entry.key === next.key)
  if (index >= 0) {
    list[index] = {...list[index], ...next, key: list[index].key, preview: list[index].preview === true}
    return markActive(list, list[index].key)
  }

  const twin = list.findIndex(entry =>
    entry.kind === next.kind && entry.href === next.href && sameScope(entry, next))
  if (twin >= 0) {
    list[twin] = {...list[twin], ...next, key: list[twin].key, preview: list[twin].preview === true}
    return markActive(list, list[twin].key)
  }

  if (next.preview) {
    const slot = list.findIndex(entry =>
      entry.preview === true && !alwaysPinned(entry.kind) && sameScope(entry, next))
    if (slot >= 0) {
      list[slot] = next
      markActive(list, next.key)
      return trimProject(list, next)
    }
  }

  list.push(next)
  markActive(list, next.key)
  return trimProject(list, next)
}

function scopedTab(tab, options) {
  return {
    ...tab,
    key: probe(tab.key) || tabKey(tab.node, tab.projectPath, tab.kind, tab.id),
    kind: probe(tab.kind),
    id: probe(tab.id),
    node: probe(tab.node),
    projectPath: probe(tab.projectPath),
    project: probe(tab.project),
    title: probe(tab.title),
    location: probe(tab.location),
    href: probe(tab.href),
    preview: options?.preview === true && !alwaysPinned(tab.kind),
  }
}

// Pinning is ONE-WAY: a pinned tab loses its preview flag and is then never a
// replacement target again. Nothing unpins a tab — closing it is the way back.
function pinTab(tabs, key) {
  const list = copyList(tabs)
  const tab = list.find(entry => entry.key === key)
  if (!tab || tab.preview !== true) return list
  tab.preview = false
  return list
}

// Close ONE tab and say where the user's attention goes next: the RIGHT
// neighbour in the same project, else the LEFT one, else `null` (the caller
// falls back to the project home). Closing is a view operation only — it never
// cancels the task or ends the session behind the tab.
function closeTab(tabs, key) {
  const list = copyList(tabs)
  const index = list.findIndex(entry => entry.key === key)
  if (index < 0) return {tabs: list, closed: null, focus: null}
  const closed = list[index]
  const position = tabsForProject(list, closed.node, closed.projectPath)
    .findIndex(entry => entry.key === key)
  const remaining = list.filter((entry, at) => at !== index)
  const siblings = tabsForProject(remaining, closed.node, closed.projectPath)
  return {tabs: remaining, closed, focus: siblings[position] || siblings[position - 1] || null}
}

// Alt+Arrow tab cycling: PROJECT-scoped (the rail only ever shows one project)
// and wrapping. `direction` is 1 for next and -1 for previous; an empty project
// yields `null`, and an unknown current key starts at the near end.
function cycleTab(tabs, node, projectPath, currentKey, direction) {
  const mine = tabsForProject(tabs, node, projectPath)
  if (!mine.length) return null
  const step = direction < 0 ? -1 : 1
  const index = mine.findIndex(tab => tab.key === currentKey)
  if (index < 0) return step > 0 ? mine[0] : mine[mine.length - 1]
  return mine[(index + step + mine.length) % mine.length]
}
// WorkbenchTabs hook: workbench.js owns the DOM, the storage and the validator
// binding; the functions above own every tab decision.

export {MAX_TABS_PER_PROJECT, TAB_BASE_URL, alwaysPinned, sameScope, tabKey,
  tabsForProject, safeHref, restore, openTab, pinTab, closeTab, cycleTab, activate}
