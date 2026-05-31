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

// DirectoryPicker hook: native directory picker via browser API or server fallback
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

    // Listen for picker_result events pushed from the server
    this.handleEvent("picker_result", ({path}) => {
      if (path) {
        // Find the nearest text input (sibling or parent-sibling) and set its value
        const container = this.el.closest(".form-control, .relative");
        if (container) {
          const input = container.querySelector('input[type="text"]');
          if (input) {
            input.value = path;
            // Trigger input event so LiveView picks up the change
            input.dispatchEvent(new Event("input", {bubbles: true}));
          }
        }
      }
    });

    this.el.addEventListener("click", async () => {
      // In desktop mode, go straight to server-side picker
      if (this.el.dataset.isDesktop === "true") {
        this.pushEvent("pick_directory", {});
        return;
      }

      // Try the browser File System Access API (Chromium, secure context)
      if (typeof window.showDirectoryPicker === "function") {
        try {
          const handle = await window.showDirectoryPicker();
          this.pushEvent("directory_picked", {path: handle.name});
          return;
        } catch (_err) {
          // User cancelled or API failed — fall through to server-side fallback
        }
      }

      // Fallback: ask the server to open a native OS dialog
      this.pushEvent("pick_directory", {});
    });
  },
};

// BottomSheet hook: manages open/close with backdrop
const BottomSheet = {
  mounted() {
    this.handleBackdropClick = (e) => {
      if (e.target === this.el) {
        this.pushEvent("close_bottom_sheet", {});
      }
    };
    this.el.addEventListener("click", this.handleBackdropClick);
  },
  destroyed() {
    this.el.removeEventListener("click", this.handleBackdropClick);
  }
};

// SlideOver hook: right-panel slide with backdrop dismiss
const SlideOver = {
  mounted() {
    this.handleBackdropClick = (e) => {
      if (e.target === this.el) {
        this.pushEvent("close_slide_over", {});
      }
    };
    this.el.addEventListener("click", this.handleBackdropClick);
  },
  destroyed() {
    this.el.removeEventListener("click", this.handleBackdropClick);
  }
};

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, PathAutocomplete, DirectoryPicker, BottomSheet, SlideOver},
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
