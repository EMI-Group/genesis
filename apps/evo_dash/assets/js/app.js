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
// highlight.js + language packs. The vendored core is the FULL 11.11.1
// default build, which bundles the ~35-language common set. The cdnjs
// language packs below are IIFEs that self-register on the GLOBAL `hljs`
// (no ES exports), so highlight_setup.js must evaluate BEFORE the pack
// imports (ESM evaluation is depth-first in import order) — it exposes the
// imported instance as `window.hljs`. The packs then register their
// languages on that same instance, which the DiffViewer hook also imports
// (bundler dedup → one shared instance).
//
// Tier-2 set (16 languages) covers the "second tier" of server-stamped lumis
// names: 15 official cdnjs 11.11.1 packs (nix, erlang, haskell, clojure,
// scala, julia, nim, crystal, elm, groovy, powershell, ocaml, fsharp, lisp,
// scheme) + zig from the third-party highlightjs-zig grammar adapted to the
// same self-registering IIFE form (no official zig grammar exists). All stay
// after ./highlight_setup.js; order among them is irrelevant.
import hljs from "../vendor/highlight.min.js"
import "./highlight_setup.js"
import "../vendor/highlight-elixir.min.js"
import "../vendor/highlight-dart.min.js"
import "../vendor/highlight-dockerfile.min.js"
import "../vendor/highlight-nix.min.js"
import "../vendor/highlight-zig.min.js"
import "../vendor/highlight-erlang.min.js"
import "../vendor/highlight-haskell.min.js"
import "../vendor/highlight-clojure.min.js"
import "../vendor/highlight-scala.min.js"
import "../vendor/highlight-julia.min.js"
import "../vendor/highlight-nim.min.js"
import "../vendor/highlight-crystal.min.js"
import "../vendor/highlight-elm.min.js"
import "../vendor/highlight-groovy.min.js"
import "../vendor/highlight-powershell.min.js"
import "../vendor/highlight-ocaml.min.js"
import "../vendor/highlight-fsharp.min.js"
import "../vendor/highlight-lisp.min.js"
import "../vendor/highlight-scheme.min.js"
import SidebarCollapse from "./hooks/sidebar_collapse.js"
import Workbench, {WorkbenchSection, WorkbenchWindow} from "./hooks/workbench.js"
import NodeSwitchFade from "./hooks/node_switch_fade.js"
import AdaptiveInput from "./hooks/adaptive_input.js"
import LegendTooltip from "./hooks/legend_tooltip.js"
import DiffViewer from "./hooks/diff_viewer.js"
import CommitGraph from "./hooks/commit_graph.js"
import CapsulePanel from "./hooks/capsule_panel.js"
import AssistantDisclosure from "./hooks/assistant_disclosure.js"
import AssistantComposer from "./hooks/assistant_composer.js"
import InspectorMessages from "./hooks/inspector_messages.js"
import DisclosureMotion from "./hooks/disclosure_motion.js"
import BrowserNotifications from "./browser_notifications.js"
import DialogModal from "./dialog_modal.js"
import DirectoryPicker from "./hooks/directory_picker.js"
import FilePicker from "./hooks/file_picker.js"
import StatePersistence from "./hooks/state_persistence.js"
import AgentHistoryAutoScroll from "./hooks/agent_history_scroll.js"
import {DesktopQuit, DesktopQuitConfirm} from "./hooks/desktop_quit.js"
import UpdateStatus from "./hooks/update_status.js"
import Guide, {guideClientId} from "./hooks/guide.js"

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
    // Focus on mount so the address-bar input is ready to type immediately when
    // LiveView morphs it in on entering edit mode (morphs don't re-apply the
    // `autofocus` attribute). No `updated()` focus — that would steal focus
    // while the user is typing elsewhere.
    this.el.focus();
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

// TauriDetect hook: pushes tauri_detected event on mount
const TauriDetect = {
  mounted() {
    // In Tauri v2 with withGlobalTauri: true, window.__TAURI__ exposes the
    // core global. window.__TAURI_OS_INTERNALS__ is a secondary detection
    // signal present in the Tauri webview. Check both for robustness.
    const isTauri = !!(window.__TAURI__ || window.__TAURI_OS_INTERNALS__);
    this.pushEvent("tauri_detected", {tauri: isTauri});
  }
};

// ClipboardCopy hook: copies data-content to clipboard on click
//
// Copy strategy, in order:
//   1. navigator.clipboard.writeText(content) — secure contexts only (https,
//      localhost/127.0.0.1, file:). On rejection we fall through to the fallback
//      instead of swallowing the error.
//   2. Legacy fallback — a temporary hidden textarea + document.execCommand("copy").
//      Works in non-secure contexts (plain HTTP served at a LAN IP / non-localhost
//      hostname) and most webviews because it runs inside the user-gesture click
//      handler. The user's prior text selection is restored afterwards.
// On success the "copied" event is pushed (the server flashes "Copied to clipboard")
// and the button's first svg is briefly tinted text-success. If BOTH paths fail the
// failure is surfaced via console.warn — never a silent no-op.
const ClipboardCopy = {
  // Success handling shared by every copy path: push "copied" + brief icon tint
  markCopied() {
    this.pushEvent("copied", {});
    const iconEl = this.el.querySelector("svg");
    if (iconEl) {
      const origClass = iconEl.getAttribute("class");
      iconEl.setAttribute("class", origClass + " text-success");
      setTimeout(() => {
        iconEl.setAttribute("class", origClass);
      }, 2000);
    }
  },

  // Legacy fallback: hidden textarea + execCommand("copy"); returns true on success
  copyViaExecCommand(content) {
    const textarea = document.createElement("textarea");
    textarea.value = content;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "absolute";
    textarea.style.left = "-9999px";
    document.body.appendChild(textarea);

    // Save the user's current selection so we can restore it afterwards
    const selection = document.getSelection();
    const prevRange = selection && selection.rangeCount > 0 ? selection.getRangeAt(0) : null;

    textarea.select();
    textarea.setSelectionRange(0, textarea.value.length);
    let ok = false;
    try {
      ok = document.execCommand("copy");
    } catch (err) {
      console.warn("ClipboardCopy: execCommand('copy') threw", err);
    }
    document.body.removeChild(textarea);

    if (selection && prevRange) {
      selection.removeAllRanges();
      selection.addRange(prevRange);
    }
    return ok;
  },

  mounted() {
    this.el.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const content = this.el.dataset.content;
      if (!content) return; // nothing meaningful to copy — no-op

      const copyWithFallback = () => {
        if (this.copyViaExecCommand(content)) {
          this.markCopied();
        } else {
          console.warn("ClipboardCopy: copy failed — navigator.clipboard unavailable and execCommand('copy') returned false");
        }
      };

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(content)
          .then(() => this.markCopied())
          .catch((err) => {
            console.warn("ClipboardCopy: navigator.clipboard.writeText rejected, trying execCommand fallback", err);
            copyWithFallback();
          });
      } else {
        copyWithFallback();
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

// PlatformDetect hook: pushes platform_info event on mount
const PlatformDetect = {
  mounted() {
    const p = navigator.platform || "";
    let platform;
    if (p.includes("Mac")) {
      platform = "mac";
    } else if (p.includes("Linux")) {
      platform = "linux";
    } else if (p.includes("Win")) {
      platform = "windows";
    } else {
      platform = "linux";
    }
    this.pushEvent("platform_info", {platform: platform});
  }
};

// FocusInput hook: focuses an input element on mount. Used by the command
// palette search box to auto-focus when the palette opens. Also re-focuses
// on update if the element is the palette search input (prevents focus loss
// during LiveView re-renders while typing in the search).
const FocusInput = {
  mounted() {
    this.el.focus();
  },
  updated() {
    // Only keep focus on the search input — not on path inputs or other fields
    if (this.el.classList.contains("focus-on-update") !== false) {
      this.el.focus();
    }
  }
};

// PaletteList hook: scrolls the currently [data-selected] item into view
// whenever the list re-renders (after keyboard navigation).
const PaletteList = {
  mounted() {
    this.scrollToSelected();
  },
  updated() {
    this.scrollToSelected();
  },
  scrollToSelected() {
    const selected = this.el.querySelector('[data-selected="true"]');
    if (selected) {
      selected.scrollIntoView({ block: "nearest", behavior: "smooth" });
    }
  }
};

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken, guide_client_id: guideClientId},
  hooks: {...colocatedHooks, TauriDetect, DesktopQuit, DesktopQuitConfirm, UpdateStatus, PlatformDetect, PathAutocomplete, DirectoryPicker, FilePicker, Guide, StatePersistence, BrowserNotifications, AutoClearFlash, ClipboardCopy, AgentHistoryAutoScroll, DialogModal, SidebarCollapse, Workbench, WorkbenchSection, WorkbenchWindow, NodeSwitchFade, AdaptiveInput, LegendTooltip, FocusInput, PaletteList, DiffViewer, CommitGraph, CapsulePanel, InspectorMessages, AssistantDisclosure, AssistantComposer, DisclosureMotion},
})

// Show progress bar on live navigation and form submits
// Adwaita: topbar paints a <canvas> (ctx.strokeStyle / ctx.shadowColor in
// vendor/topbar.js), and canvas color strings cannot resolve CSS variables —
// so these stay fixed literals. "#29d" is the accent blue, approximating
// --color-primary (#3584e4); the rgba(0,0,0,.3) shadow is a soft drop glow
// kept subtle enough to read on both light and dark surfaces.
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
