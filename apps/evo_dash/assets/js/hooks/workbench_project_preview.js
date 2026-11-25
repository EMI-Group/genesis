// LiveView replaces the page on cross-route navigation. Keep the last rendered
// window of each project for the visual handoff while its live view mounts.
//
// MEMORY: each cached entry holds a FULL `#main-content` clone, so the cache is
// BOUNDED (LRU, `MAX_WINDOWS` below) instead of growing with every project the
// user visits — the exact-key `forget()` alone only ever dropped one entry.
//
// TEARDOWN: `projectPreview.release()` is the teardown seam — it clears a
// pending handoff, empties the cache and removes the shadow-DOM host. The
// workbench shell (hooks/workbench.js) does not call it yet; it exists so a
// shell that unmounts can drop the snapshots and the host in one call.

// --- ProjectPreview: pure cache planning -----------------------------------
// Recency and eviction over the handoff cache, plain Map/string operations
// only (no DOM), so the LRU rules are directly testable.
//
// WHY bounded at all: the preview only ever hands off the project being LEFT,
// so ONE spare entry is enough; two tolerates a fast back-and-forth between two
// projects without re-snapshotting on every hop. Anything older is dead weight.
const MAX_WINDOWS = 2

// Makes `key` the most recently used entry and answers it (undefined on a
// miss). Map insertion order IS the recency order, so a hit is re-inserted at
// the end with delete + set.
function touch(windows, key) {
  if (!windows.has(key)) return undefined
  const entry = windows.get(key)
  windows.delete(key)
  windows.set(key, entry)
  return entry
}

// The keys an over-full cache must drop, oldest first. `keep` (the entry that
// was just made newest) is never among them, even if a stale-order cache would
// put it first — a live handoff is never evicted by its own insert.
function keysToEvict(windows, keep, limit = MAX_WINDOWS) {
  const excess = Math.max(0, windows.size - limit)
  if (!excess) return []
  return [...windows.keys()].filter(key => key !== keep).slice(0, excess)
}
// projectPreview: module state + the shadow-DOM handoff (all DOM, no decisions).

const windows = new Map()
const scope = ({node, projectPath}) => JSON.stringify([node, projectPath])

let overlay
let stylesReady = false
let pending

function previewHost() {
  if (overlay) return overlay

  // Held in a local so a resolved stylesheet chain can tell whether the host it
  // cloned the sheets for is still the mounted one (see `release()`).
  const host = document.createElement("div")
  host.id = "workbench-project-preview"
  host.hidden = true
  host.inert = true
  host.setAttribute("aria-hidden", "true")
  const shadow = host.attachShadow({mode: "open"})
  const styles = [...document.head.querySelectorAll('link[rel="stylesheet"]')]
  Promise.all(styles.map(style => new Promise(resolve => {
    const link = style.cloneNode()
    link.addEventListener("load", () => resolve(true), {once: true})
    link.addEventListener("error", () => resolve(false), {once: true})
    shadow.append(link)
  }))).then(loaded => {
    // A host released in the meantime must not resurrect its readiness.
    if (overlay === host) stylesReady = loaded.every(Boolean)
  })
  overlay = host
  document.body.append(host)
  return host
}

function clear() {
  if (!pending) return
  clearTimeout(pending.timer)
  if (overlay) overlay.hidden = true
  document.body.removeAttribute("data-workbench-project-switching")
  pending.content.remove()
  pending = null
}

function position(scroll) {
  if (!overlay) return
  const bounds = scroll.getBoundingClientRect()
  Object.assign(overlay.style, {
    top: bounds.top + "px",
    left: bounds.left + "px",
    width: bounds.width + "px",
    height: bounds.height + "px",
  })
}

// Drops one cache entry and releases its DOM. The frame of a handoff IN FLIGHT
// is never yanked: it is cleared (which removes it from the host) first.
function drop(key) {
  const entry = windows.get(key)
  if (!entry) return
  if (pending && pending.content === entry.frame) clear()
  entry.frame = null
  entry.surface = null
  windows.delete(key)
}

// Stores `entry` as the newest snapshot of `key`, evicting the oldest entries.
function store(key, entry) {
  drop(key)
  windows.set(key, entry)
  keysToEvict(windows, key).forEach(drop)
}

export const projectPreview = {
  // Exported teardown seam (see the header comment): a shell that unmounts can
  // drop a pending handoff, every cached snapshot and the shadow-DOM host. A
  // later `remember()` re-creates the host (and re-clones the stylesheets).
  release() {
    clear()
    windows.clear()
    if (overlay) {
      overlay.remove()
      overlay = undefined
    }
    // The in-flight stylesheet chain belongs to the removed host; its callback
    // is identity-guarded in `previewHost`, so only this reset is needed.
    stylesReady = false
  },

  remember(layout, tab) {
    if (pending || !tab?.projectPath) return
    const scroll = layout?.querySelector?.("#main-scroll")
    const content = scroll?.querySelector("#main-content")
    if (!content || layout.dataset.workbenchProject !== tab.projectPath) return

    previewHost()
    const frame = document.createElement("div")
    frame.id = layout.id
    frame.dataset.accentColor = layout.dataset.accentColor
    frame.style.height = "100%"
    const surface = scroll.cloneNode(false)
    surface.inert = false
    surface.style.height = "100%"
    const wrapper = content.parentElement.cloneNode(false)
    const snapshot = content.cloneNode(true)
    snapshot.querySelectorAll("dialog, iframe, script, video, audio").forEach(node => node.remove())
    wrapper.append(snapshot)
    surface.append(wrapper)
    frame.append(surface)
    store(scope(tab), {key: tab.key, frame, surface, top: scroll.scrollTop})
  },

  show(layout, tab, onTimeout) {
    clear()
    if (!tab || !stylesReady) return
    const key = scope(tab)
    // A hit whose stored tab differs is a STALE entry (the same project under a
    // new tab key): it is left for `forget()`/eviction, never re-inserted.
    const saved = windows.get(key)
    const scroll = layout?.querySelector?.("#main-scroll")
    if (saved?.key !== tab.key || !scroll) return
    const entry = touch(windows, key) || saved

    const host = previewHost()
    position(scroll)
    host.shadowRoot.append(entry.frame)
    host.hidden = false
    document.body.setAttribute("data-workbench-project-switching", "")
    entry.surface.scrollTop = entry.top
    pending = {tab, content: entry.frame, timer: setTimeout(() => {
      clear()
      onTimeout()
    }, 2000)}
  },

  sync(layout, currentTab) {
    if (!pending) return null
    const {tab} = pending
    if (currentTab === tab.key && layout?.dataset?.workbenchProject === tab.projectPath) {
      clear()
      return null
    }
    this.reposition(layout)
    return tab
  },

  reposition(layout) {
    const scroll = pending && layout?.querySelector?.("#main-scroll")
    if (scroll) position(scroll)
  },

  // Exact-key semantics: an entry stored under this scope for a DIFFERENT tab
  // key is not ours to remove (and must not be resurrected by an LRU touch).
  forget(tab) {
    const key = scope(tab)
    if (windows.get(key)?.key === tab.key) drop(key)
  },
}
