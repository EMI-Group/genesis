// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/evo_dash"
import topbar from "../vendor/topbar"

// Compute the longest common prefix among an array of strings
function longestCommonPrefix(strings) {
  if (strings.length === 0) return "";
  let prefix = strings[0];
  for (let i = 1; i < strings.length; i++) {
    while (!strings[i].startsWith(prefix)) {
      prefix = prefix.slice(0, -1);
      if (prefix === "") return "";
    }
  }
  return prefix;
}

// PathAutocomplete hook: shell-like Tab completion and real-time auto-complete from datalist suggestions
const PathAutocomplete = {
  mounted() {
    const input = this.el;
    let prevValue = input.value;

    // Tab-key: complete to longest common prefix among all matching datalist options.
    // Always consumes the Tab event when there are matches, so focus stays in the input.
    input.addEventListener("keydown", (e) => {
      if (e.key === "Tab" && input.value.length > 0) {
        const listId = input.getAttribute("list");
        if (!listId) return;
        const datalist = document.getElementById(listId);
        if (!datalist) return;
        const options = Array.from(datalist.querySelectorAll('option'));
        const matches = options.filter(opt => opt.value.toLowerCase().startsWith(input.value.toLowerCase()));
        if (matches.length === 0) return;
        // Always prevent default so Tab doesn't navigate away from the input
        e.preventDefault();
        const lcp = longestCommonPrefix(matches.map(opt => opt.value));
        if (lcp !== input.value) {
          input.value = lcp;
        } else if (matches.length > 0) {
          // LCP equals current input but there are multiple diverging matches.
          // Complete to the first match so the user can cycle by pressing Tab again
          // (the new value will then have a different LCP among remaining matches).
          input.value = matches[0].value;
        }
      }
    });

    // Real-time auto-complete: if there's exactly one matching prefix, fill it in.
    // Only auto-fills when the user is NOT deleting (i.e., the new value is not a
    // shorter prefix of the previous value), so Backspace works correctly.
    input.addEventListener("input", () => {
      const curValue = input.value;
      if (curValue.length === 0) {
        prevValue = curValue;
        return;
      }
      const listId = input.getAttribute("list");
      if (!listId) { prevValue = curValue; return; }
      const datalist = document.getElementById(listId);
      if (!datalist) { prevValue = curValue; return; }

      // Detect deletion: the new value is a strict prefix of the previous value
      const isDeleting = prevValue.startsWith(curValue) && curValue.length < prevValue.length;
      prevValue = curValue;

      if (isDeleting) return;

      const options = Array.from(datalist.querySelectorAll('option'));
      const matches = options.filter(opt => opt.value.toLowerCase().startsWith(curValue.toLowerCase()));
      if (matches.length === 1 && matches[0].value !== curValue) {
        const oldValue = curValue;
        input.value = matches[0].value;
        // Select the portion that was auto-completed so the user can keep typing
        input.setSelectionRange(oldValue.length, matches[0].value.length);
        prevValue = matches[0].value;
      }
    });
  }
};

// DirectoryPicker hook: native directory picker via Tauri dialog, browser API, or fallback
const DirectoryPicker = {
  mounted() {
    // Detect if browser is on the same machine as the server
    const hostname = window.location.hostname;
    this.el.dataset.isLocal =
      hostname === "localhost" ||
      hostname === "127.0.0.1" ||
      hostname === "[::1]"
        ? "true"
        : "false";

    this.el.addEventListener("click", async () => {
      // 1. Tauri native dialog (desktop app)
      if (window.__TAURI__) {
        try {
          let selected;
          if (window.__TAURI__.dialog && window.__TAURI__.dialog.open) {
            selected = await window.__TAURI__.dialog.open({directory: true});
          } else {
            selected = await window.__TAURI__.core.invoke('plugin:dialog|open', {directory: true});
          }
          if (selected) {
            // Tauri returns the full path
            this.fillInput(selected);
          }
        } catch (_err) {
          // User cancelled or dialog failed — silently ignore
        }
        return;
      }

      // 2. Browser File System Access API (Chromium browsers)
      if (typeof window.showDirectoryPicker === "function") {
        try {
          const handle = await window.showDirectoryPicker();
          this.fillInput(handle.name);
          return;
        } catch (_err) {
          // User cancelled or API failed — fall through to prompt
        }
      }

      // 3. Fallback: text input prompt (non-Chromium browsers without Tauri)
      // The input is already visible and editable, so no action needed
    });
  },

  fillInput(value) {
    const container = this.el.closest(".picker-container") ||
      this.el.closest(".form-control") ||
      this.el.closest(".relative") ||
      this.el.parentElement;
    if (container) {
      const input = container.querySelector('input[type="text"]');
      if (input) {
        input.value = value;
        input.dispatchEvent(new Event("input", {bubbles: true}));
      }
    }
  }
};

// StatePersistence hook: saves/restores dashboard state via sessionStorage
const StatePersistence = {
  mounted() {
    // Restore saved state from sessionStorage
    const saved = sessionStorage.getItem('dashboard_state');
    if (saved) {
      try {
        const state = JSON.parse(saved);
        this.pushEvent("restore_state", state);
      } catch (e) {}
    }

    // Listen for save requests from the server (still needed for task_mode changes, project switches, task starts)
    this.handleEvent("persist_state", (state) => {
      // Also capture current DOM state for HTML-managed toggles
      const detailsEl = this.el.querySelector('details');
      if (detailsEl) {
        state.show_project_settings = detailsEl.open;
      }
      sessionStorage.setItem('dashboard_state', JSON.stringify(state));
    });

    // Client-side form field watching — debounced persistence to sessionStorage
    let debounceTimer;
    const persistFormState = () => {
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        const project = this.el.dataset.project || '';
        const taskMode = this.el.dataset.taskMode || '';
        const state = {
          project: project,
          task_mode: taskMode,
          task_prompt: this.el.querySelector('[name="prompt"]')?.value || '',
          task_node_path: this.el.querySelector('[name="node_path"]')?.value || '',
          task_seeds: this.el.querySelector('[name="seeds"]')?.value || '',
          task_starting_commit: this.el.querySelector('[name="starting_commit"]')?.value || '',
        };
        // Also capture project settings toggle state
        const detailsEl = this.el.querySelector('details');
        if (detailsEl) {
          state.show_project_settings = detailsEl.open;
        }
        sessionStorage.setItem('dashboard_state', JSON.stringify(state));
      }, 300);
    };

    // Watch all form fields for input events
    this.el.addEventListener('input', (e) => {
      const name = e.target.getAttribute('name');
      if (['prompt', 'node_path', 'seeds', 'starting_commit'].includes(name)) {
        persistFormState();
      }
    });
  }
};

// BrowserNotifications hook: shows browser notifications when tasks complete
const BrowserNotifications = {
  mounted() {
    this._permission = Notification.permission;
    if (this._permission === "default") {
      Notification.requestPermission().then(perm => { this._permission = perm; });
    }
    this.handleEvent("task_notification", ({title, body}) => {
      if (this._permission === "granted") {
        new Notification(title, {body: body, icon: "/favicon.ico"});
      }
    });
  }
};

// ClipboardCopy hook: copies data-content to clipboard on click
const ClipboardCopy = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const content = this.el.dataset.content;
      if (content && navigator.clipboard) {
        navigator.clipboard.writeText(content).then(() => {
          // Visual feedback: briefly show checkmark icon
          const iconEl = this.el.querySelector("svg");
          if (iconEl) {
            const origClass = iconEl.getAttribute("class");
            iconEl.setAttribute("class", origClass + " text-success");
            setTimeout(() => {
              iconEl.setAttribute("class", origClass);
            }, 2000);
          }
        }).catch(() => {});
      }
    });
  }
};

// AutoClearFlash hook: auto-dismisses flash messages after 4 seconds
const AutoClearFlash = {
  mounted() {
    const ignoredIDs = ["client-error", "server-error"];
    if (ignoredIDs.includes(this.el.id)) return;

    setTimeout(() => {
      const closeBtn = this.el.querySelector("button[aria-label='close']")
      if (closeBtn) {
        closeBtn.click()
      } else {
        this.el.click()
      }
    }, 4000);
  }
};

// ScrollToFile hook: scrolls the diff viewer to the selected file section
const ScrollToFile = {
  mounted() {
    this.handleEvent("scroll_to_file", ({target_id}) => {
      setTimeout(() => {
        const target = document.getElementById(target_id);
        if (!target) return;

        const fullscreenLayout = target.closest('.diff-fullscreen-layout');
        if (fullscreenLayout) {
          // Fullscreen mode — scroll the page to the target
          const rect = target.getBoundingClientRect();
          window.scrollTo({
            top: window.scrollY + rect.top - 116, // 108px sticky offset + 8px padding
            behavior: "smooth"
          });
        } else {
          // Normal mode — scroll within the diff container
          const container = target.closest('.diff-main-content');
          if (container) {
            const containerRect = container.getBoundingClientRect();
            const targetRect = target.getBoundingClientRect();
            const scrollOffset = targetRect.top - containerRect.top + container.scrollTop;
            container.scrollTo({
              top: scrollOffset - 8,
              behavior: "smooth"
            });
          } else {
            target.scrollIntoView({ behavior: "smooth", block: "start" });
          }
        }
      }, 50);
    });
  }
};

// AgentHistoryAutoScroll hook: auto-scrolls chat history when user is at the bottom
const AgentHistoryAutoScroll = {
  mounted() {
    this.isAtBottom = true;
    
    // Scroll to bottom initially
    this.el.scrollTop = this.el.scrollHeight;
    
    // Track whether user has scrolled away from bottom
    this.el.addEventListener("scroll", () => {
      this.isAtBottom = this.el.scrollTop + this.el.clientHeight >= this.el.scrollHeight - 30;
    }, { passive: true });
  },
  
  updated() {
    if (this.isAtBottom) {
      this.el.scrollTo({
        top: this.el.scrollHeight,
        behavior: "smooth"
      });
    }
  }
};

// WelcomeCheck hook: detects first visit and shows welcome modal
const WelcomeCheck = {
  mounted() {
    if (!localStorage.getItem("evogit:welcomed")) {
      // Small delay to let the page render first
      setTimeout(() => this.pushEvent("show_welcome", {}), 500);
    }
    this.handleEvent("welcome_dismissed", () => {
      localStorage.setItem("evogit:welcomed", "true");
    });
  }
};

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, PathAutocomplete, DirectoryPicker, StatePersistence, BrowserNotifications, AutoClearFlash, ScrollToFile, ClipboardCopy, AgentHistoryAutoScroll, WelcomeCheck},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
