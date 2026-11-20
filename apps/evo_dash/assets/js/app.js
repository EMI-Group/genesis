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
import ListEnter from "./hooks/list_enter.js"
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

// The ONE reduced-motion read for app.js. hooks/disclosure_motion.js publishes
// its guarded matchMedia helper on globalThis.genesisMotion (dialog_modal.js
// reaches it the same way), so a missing bridge — tests, an unusual embed —
// means "no preference" instead of a crash.
function prefersReducedMotion() {
  return globalThis.genesisMotion?.prefersReducedMotion?.() === true;
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

// AutoClearFlash hook: auto-dismisses flash messages after 4 seconds.
//
// The flash element is rendered by core_components.ex with
// `animate-toast-enter` and a close button whose phx-click chains
// JS.push("lv:clear-flash") |> hide("##{@id}") — so clicking it removes the node
// in the same frame and the toast vanished with NO exit frame. That is exactly
// what app.css's `animate-toast-exit` (250ms `toast-exit` keyframes, `both`
// fill) exists for, so the auto-clear path plays it first and only then clicks
// the close button.
const AutoClearFlash = {
  mounted() {
    const ignoredIDs = ["client-error", "server-error"];
    if (ignoredIDs.includes(this.el.id)) return;

    let cleared = false;
    // ONE dismissal per toast: a user clicking the close button during the exit
    // removes the node, and the bounded fallback below must not fire a second
    // click at the server.
    const clear = () => {
      if (cleared) return;
      cleared = true;
      clearTimeout(this.exitFallbackTimer);
      const closeBtn = this.el.querySelector("button[aria-label='close']")
      if (closeBtn) {
        closeBtn.click()
      } else {
        this.el.click()
      }
    };

    this.autoClearTimer = setTimeout(() => {
      // Reduced motion (or an environment without animations) gets the plain
      // immediate dismissal — never a delayed one.
      if (prefersReducedMotion()) return clear();

      // Only the toast's OWN animation may finish the exit: a child element's
      // animationend bubbles up here too.
      const onEnd = (event) => {
        if (event.target !== this.el) return;
        this.el.removeEventListener("animationend", onEnd);
        clear();
      };
      this.el.classList.remove("animate-toast-enter");
      this.el.classList.add("animate-toast-exit");
      this.el.addEventListener("animationend", onEnd);
      // Bounded fallback just above the 250ms exit, in case no animation ever
      // fires (a hidden or zero-height toast, animations disabled at the OS
      // level, a detached node).
      this.exitFallbackTimer = setTimeout(clear, 400);
    }, 4000);
  },
  destroyed() {
    clearTimeout(this.autoClearTimer);
    clearTimeout(this.exitFallbackTimer);
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
  hooks: {...colocatedHooks, TauriDetect, DesktopQuit, DesktopQuitConfirm, UpdateStatus, PlatformDetect, PathAutocomplete, DirectoryPicker, FilePicker, Guide, StatePersistence, BrowserNotifications, AutoClearFlash, ClipboardCopy, AgentHistoryAutoScroll, DialogModal, SidebarCollapse, Workbench, WorkbenchSection, WorkbenchWindow, NodeSwitchFade, AdaptiveInput, LegendTooltip, FocusInput, PaletteList, DiffViewer, CommitGraph, CapsulePanel, InspectorMessages, AssistantDisclosure, AssistantComposer, DisclosureMotion, ListEnter},
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

// Per-patch view transition: cross-DOCUMENT view transitions only cover full
// page loads (the <meta name="view-transition"> in root.html.heex), so a
// live_patch route change inside ONE LiveView — switching project, or
// /projects → /tasks on a patched link — used to snap.
//
// The window is the phx:page-loading pair LiveView already dispatches for a
// link patch: `pushHistoryPatch` dispatches page-loading-start(kind: "patch")
// BEFORE it pushes the patch URL, and the matching page-loading-stop is
// dispatched from pushLinkPatch's callback, AFTER `applyPendingUpdates()` has
// morphed the reply's diff into the DOM. So starting the transition on START
// snapshots the OLD frame and resolving its update callback on STOP snapshots
// the NEW one, with the server round-trip in between.
//
// The `dom: {onDocumentPatch}` route was verified and rejected: the patch's
// diff reaches that callback while the pending link is still set, so its
// `update()` only QUEUES the diff (View.update → pendingDiffs) and the DOM
// change lands later, inside applyPendingUpdates — outside any
// startViewTransition callback, which would cross-fade the old frame onto
// itself and then snap. It is also the only route that sees every event-driven
// diff (stream tick, form submit, phx-click), which must never be snapshotted.
//
// Known gap: a SERVER-initiated push_patch dispatches no page-loading events,
// so it still snaps (covering it would need the queued-diff awareness above).
const PATCH_TRANSITION_TIMEOUT_MS = 600
let patchTransitionInFlight = false

window.addEventListener("phx:page-loading-start", (event) => {
  if (event.detail?.kind !== "patch") return
  if (patchTransitionInFlight) return
  if (typeof document.startViewTransition !== "function") return
  if (prefersReducedMotion()) return

  let settle
  const settled = new Promise((resolve) => { settle = resolve })
  const finish = () => {
    window.removeEventListener("phx:page-loading-stop", onStop)
    clearTimeout(timeout)
    settle()
  }
  const onStop = (event) => {
    // withPageLoading hands the SAME info object to both events, so an
    // unrelated element-level page loading must not settle this patch.
    if (event.detail?.kind === "patch") finish()
  }
  // Safety net: a failed patch falls back to a full navigation, where "stop" is
  // never dispatched — the transition must never be left hanging.
  const timeout = setTimeout(finish, PATCH_TRANSITION_TIMEOUT_MS)
  window.addEventListener("phx:page-loading-stop", onStop)

  patchTransitionInFlight = true
  // Single flight: the flag is released only when this transition has finished
  // (and immediately, as a fallback, on an implementation without `finished`).
  const release = () => { patchTransitionInFlight = false }
  try {
    const transition = document.startViewTransition(() => settled)
    if (transition?.finished?.then) {
      transition.finished.then(release, release)
    } else {
      release()
    }
  } catch (_error) {
    finish()
    release()
  }
})

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
