// LiveView replaces the page on cross-route navigation. Keep the last rendered
// window of each project for the visual handoff while its live view mounts.
const windows = new Map()
const scope = ({node, projectPath}) => JSON.stringify([node, projectPath])

let overlay
let stylesReady = false
let pending

function previewHost() {
  if (overlay) return overlay

  overlay = document.createElement("div")
  overlay.id = "workbench-project-preview"
  overlay.hidden = true
  overlay.inert = true
  overlay.setAttribute("aria-hidden", "true")
  const shadow = overlay.attachShadow({mode: "open"})
  const styles = [...document.head.querySelectorAll('link[rel="stylesheet"]')]
  Promise.all(styles.map(style => new Promise(resolve => {
    const link = style.cloneNode()
    link.addEventListener("load", () => resolve(true), {once: true})
    link.addEventListener("error", () => resolve(false), {once: true})
    shadow.append(link)
  }))).then(loaded => { stylesReady = loaded.every(Boolean) })
  document.body.append(overlay)
  return overlay
}

function clear() {
  if (!pending) return
  clearTimeout(pending.timer)
  overlay.hidden = true
  document.body.removeAttribute("data-workbench-project-switching")
  pending.content.remove()
  pending = null
}

function position(scroll) {
  const bounds = scroll.getBoundingClientRect()
  Object.assign(overlay.style, {
    top: bounds.top + "px",
    left: bounds.left + "px",
    width: bounds.width + "px",
    height: bounds.height + "px",
  })
}

export const projectPreview = {
  remember(layout, tab) {
    if (pending || !tab?.projectPath) return
    const scroll = layout.querySelector("#main-scroll")
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
    snapshot.classList.remove("node-switch-fade")
    snapshot.querySelectorAll("dialog, iframe, script, video, audio").forEach(node => node.remove())
    wrapper.append(snapshot)
    surface.append(wrapper)
    frame.append(surface)
    windows.set(scope(tab), {key: tab.key, frame, surface, top: scroll.scrollTop})
  },

  show(layout, tab, onTimeout) {
    clear()
    if (!tab || !stylesReady) return
    const saved = windows.get(scope(tab))
    const scroll = layout.querySelector("#main-scroll")
    if (saved?.key !== tab.key || !scroll) return

    const host = previewHost()
    position(scroll)
    host.shadowRoot.append(saved.frame)
    host.hidden = false
    document.body.setAttribute("data-workbench-project-switching", "")
    saved.surface.scrollTop = saved.top
    pending = {tab, content: saved.frame, timer: setTimeout(() => {
      clear()
      onTimeout()
    }, 2000)}
  },

  sync(layout, currentTab) {
    if (!pending) return null
    const {tab} = pending
    if (currentTab === tab.key && layout.dataset.workbenchProject === tab.projectPath) {
      clear()
      return null
    }
    this.reposition(layout)
    return tab
  },

  reposition(layout) {
    const scroll = pending && layout.querySelector("#main-scroll")
    if (scroll) position(scroll)
  },

  forget(tab) {
    const key = scope(tab)
    if (windows.get(key)?.key === tab.key) windows.delete(key)
  },
}
