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
// highlight.js + language packs. The cdnjs language packs are IIFEs that
// self-register on the GLOBAL `hljs` (no ES exports), so highlight_setup.js
// must evaluate BEFORE the pack import below (ESM evaluation is depth-first
// in import order) — it exposes the imported instance as `window.hljs`.
// The pack then registers "elixir" on that same instance, which the
// DiffViewer hook also imports (bundler dedup → one shared instance).
import hljs from "../vendor/highlight.min.js"
import "./highlight_setup.js"
import "../vendor/highlight-elixir.min.js"
import SidebarCollapse from "./hooks/sidebar_collapse.js"
import NodeSwitchFade from "./hooks/node_switch_fade.js"
import AdaptiveInput from "./hooks/adaptive_input.js"
import LegendTooltip from "./hooks/legend_tooltip.js"
import DiffViewer from "./hooks/diff_viewer.js"

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

// DirectoryPicker hook: native directory picker via a server-side wx dialog
//
// The picker buttons ("Browse" on the project, new-project, and foreign-repo
// pickers) carry phx-hook="DirectoryPicker". Clicking a button pushes a
// "directory_pick" event to the server (ProjectsLive), which — when the
// current node is local — runs a native wx directory dialog
// (EvoDash.DirectoryPicker GenServer, wxDirDialog) and pushes the result back
// to the client as a "picker_result:<picker_id>" event. Payloads:
//
//   {path: "/absolute/path"} → a directory was picked (wx returns absolute
//                              paths only)
//   {cancelled: true}        → the user dismissed the dialog — no-op
//   {unavailable: true}      → wx is unavailable (headless server, remote
//                              node, OTP built without wx) — fall back to
//                              manual entry
//
// There is deliberately NO JS-side timeout: the native dialog may legitimately
// stay open for minutes while the user navigates the filesystem, and the
// server owns the dialog lifecycle. On a successful pick the path is filled
// into the adjacent input; the project and new-project pickers additionally
// auto-submit their enclosing form (the server validates via Path.expand +
// File.dir?, so auto-submitting a stale/bad selection is safe), while the
// foreign-repo picker only fills the input (a settings form field). wx picks
// are always absolute; the absolute-path guard below is defense in depth — a
// non-absolute result is never fed into the input (the server would cwd-join
// it) and routes to the manual-entry fallback instead.
const DirectoryPicker = {
  mounted() {
    this.el.addEventListener("click", () => {
      // Re-entrancy guard: the native wx dialog is modal, so a second click
      // while a pick is in flight would stack another dialog. The result
      // handler (or a reconnect, see reconnected()) re-arms the button.
      if (this._picking) return;
      this._picking = true;
      this.pushEvent("directory_pick", {picker_id: this.el.dataset.pickerId});
    });

    // Register in mounted() (not only on connect) so the listener survives
    // reconnects: handleEvent listeners live until the hook is destroyed, and
    // mounted() re-runs whenever the hook is re-created.
    this.handleEvent("picker_result:" + this.el.dataset.pickerId, ({path, cancelled, unavailable}) => {
      this._picking = false; // the dialog is closed — re-arm the button

      if (unavailable) {
        // Headless server, remote node, or OTP built without wx — never leave
        // the user with a silent dead click.
        this.markManualFallback();
        return;
      }
      if (cancelled) return; // user dismissed the native dialog — not an error

      if (path) {
        // Defense-in-depth: wx picks are always absolute, but never feed a
        // non-absolute result into the input (the server would cwd-join it) —
        // warn and fall through to the manual-entry fallback instead.
        if (!/^[a-zA-Z]:[\\/]|^[\\/]|^\\\\/.test(path)) {
          console.warn(
            "[DirectoryPicker] Picker returned a non-absolute path (\"" + path + "\") — please type the full path."
          );
          this.markManualFallback();
          return;
        }
        this.fillInput(path);
        // wx picks return a full absolute path — auto-confirm the project and
        // new-project pickers by submitting the enclosing form directly. (The
        // browse button lives inside that form; the foreign-repo picker is a
        // settings form field that still needs manual input.)
        if (this.el.dataset.pickerId === "project" ||
            this.el.dataset.pickerId === "new-project") {
          this.el.closest("form")?.requestSubmit();
        }
        return;
      }

      // Defensive: a result with no path and no flags is unusable — fall back
      // to manual entry rather than silently doing nothing.
      this.markManualFallback();
    });
  },

  // If the connection drops while the native dialog is open, the server-side
  // pick is gone — re-arm the button so the user can try again once the
  // reconnect completes.
  reconnected() {
    this._picking = false;
  },

  // Resolves the container element that wraps the browse button + path input
  // (same lookup order fillInput always used).
  containerEl() {
    return this.el.closest(".picker-container") ||
      this.el.closest(".form-control") ||
      this.el.closest(".relative") ||
      this.el.parentElement;
  },

  pickerInput() {
    const container = this.containerEl();
    if (!container) return null;
    return container.querySelector('input[type="text"]');
  },

  fillInput(value) {
    const input = this.pickerInput();
    if (input) {
      input.value = value;
      input.dispatchEvent(new Event("input", {bubbles: true}));
    }
    this.clearManualFallback();
  },

  // Surfaces a visible "type the path manually" fallback: marks the picker row
  // (styled via [data-picker-error="manual"] in css/app.css) and focuses the
  // path input so manual entry is one keystroke away.
  markManualFallback() {
    const container = this.containerEl();
    if (container) {
      container.dataset.pickerError = "manual";
      this.pickerInput()?.focus();
    } else {
      this.el.dataset.pickerError = "manual";
    }
    console.warn(
      "[DirectoryPicker] Native picker unavailable — the path input remains editable for manual entry"
    );
  },

  clearManualFallback() {
    const container = this.containerEl();
    if (container) container.removeAttribute("data-picker-error");
  }
};

// FilePicker hook: attach a file to the objective editor
//
// The "+" button (data-picker-id="objective_file") pushes a "file_pick" event
// with the CURRENT textarea value; ProjectsLive (local node only) runs a
// native file dialog server-side (EvoDash.DirectoryPicker :file mode) and
// pushes the result back as "picker_result:<picker_id>". Payloads:
//   {prompt: "...", block: "...", attached: true, name: "..."} → success —
//     `prompt` is the full new objective (base prompt + attached-file
//     Markdown block); `block` is the appended Markdown block alone (used
//     when the user typed between click and result, so their typing is never
//     clobbered).
//   {cancelled: true}  → user dismissed the dialog — no-op
//   {unavailable: true} → dialog unavailable (remote node, picker disabled) —
//     reveals the manual path input rendered next to the button
//     (".file-manual", task_form_components.ex); typing a path and pressing
//     Enter (or the confirm button) pushes "file_pick_manual" and the server
//     replies with the SAME picker_result payloads (success → write textarea
//     + close, error → inline error + keep open, unavailable/cancelled →
//     close).
//   {error: true}      → server failed to read the file — console.warn, no-op
const FilePicker = {
  mounted() {
    this._basePrompt = null;
    this._picking = false;             // native dialog in flight (re-entrancy guard)
    this._manualSubmitted = false;     // manual path submission in flight
    this._manualEl = this.el.parentElement?.querySelector(".file-manual");
    this._manualInput = this._manualEl?.querySelector(".file-manual-input");
    this._manualError = this._manualEl?.querySelector(".file-manual-error");

    this.el.addEventListener("click", () => {
      if (this._manualEl && !this._manualEl.hidden) {
        // Manual input is open — never re-fire file_pick; just focus it.
        this._manualInput?.focus();
        return;
      }
      if (this._picking) return;       // re-entrancy guard, DirectoryPicker pattern
      const textarea = this.promptTextarea();
      if (!textarea) return;
      this._basePrompt = textarea.value;
      this._picking = true;
      this.pushEvent("file_pick", {
        picker_id: this.el.dataset.pickerId,
        prompt: this._basePrompt
      });
    });

    if (this._manualEl && this._manualInput) {
      this._manualInput.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          e.preventDefault();          // inside the task form — never submit it
          this.submitManual();
        } else if (e.key === "Escape") {
          e.preventDefault();
          this.closeManual();
        }
      });
      this._manualEl.querySelector(".file-manual-confirm")
        ?.addEventListener("click", () => this.submitManual());
      this._manualEl.querySelector(".file-manual-cancel")
        ?.addEventListener("click", () => this.closeManual());
    }

    this.handleEvent("picker_result:" + this.el.dataset.pickerId, (payload) => {
      if (this._manualSubmitted) {
        // Result of a manual path submission — mirror the native semantics:
        // success closes the input and writes the prompt below; error keeps
        // the input open with an inline message; unavailable/cancelled close.
        this._manualSubmitted = false;
        if (payload.error) {
          this.showManualError(payload.reason || null);
          return;
        }
        if (!payload.attached) {
          this.closeManual();          // unavailable / cancelled
          return;
        }
        this.closeManual();            // success — fall through to the write
      } else {
        this._picking = false;         // dialog closed — re-arm the button
        if (payload.unavailable) {
          this.openManual();           // native picker unavailable — manual fallback
          return;
        }
        if (payload.cancelled) return; // not an error
        if (payload.error) {
          console.warn("[FilePicker] Failed to attach the file");
          return;
        }
      }
      if (typeof payload.prompt !== "string") return;         // defensive
      const textarea = this.promptTextarea();
      if (!textarea) return;
      const block = typeof payload.block === "string" ? payload.block : "";
      if (textarea.value === this._basePrompt) {
        // Prompt unchanged since the click — apply the server-computed value.
        textarea.value = payload.prompt;
      } else if (block) {
        // User typed meanwhile — append ONLY the file block, never clobber.
        textarea.value = textarea.value + block;
      } else {
        return; // no block info and value changed — do not clobber
      }
      textarea.dispatchEvent(new Event("input", {bubbles: true}));
      textarea.dispatchEvent(new Event("change", {bubbles: true}));
    });
  },

  reconnected() {
    this._picking = false;             // server-side pick is gone after reconnect
    this._manualSubmitted = false;
  },

  promptTextarea() {
    // The task-form textarea; find within the enclosing form first.
    return this.el.closest("form")?.querySelector('textarea[name="prompt"]') ||
      document.querySelector('textarea[name="prompt"]');
  },

  // --- Manual path fallback (revealed when the native picker is unavailable) ---

  openManual() {
    if (!this._manualEl) return;
    this._manualEl.hidden = false;
    // Fresh open: no stale value, no stale error. The pop/slide expansion
    // animation (app.css @keyframes file-manual-expand) restarts whenever
    // the widget becomes visible again.
    if (this._manualInput) this._manualInput.value = "";
    this.clearManualError();
    this._manualInput?.focus();
    console.warn(
      "[FilePicker] Native picker unavailable — the path input next to the attach button remains editable for manual entry"
    );
  },

  submitManual() {
    if (this._manualSubmitted) return; // one submission in flight
    const textarea = this.promptTextarea();
    if (!textarea) return;
    const path = this._manualInput?.value ?? "";
    this._basePrompt = textarea.value;
    this._manualSubmitted = true;
    this.clearManualError();
    this.pushEvent("file_pick_manual", {
      picker_id: this.el.dataset.pickerId,
      path: path,
      prompt: this._basePrompt
    });
  },

  closeManual() {
    if (!this._manualEl) return;
    this._manualEl.hidden = true;
    this.clearManualError();
    if (this._manualInput) this._manualInput.value = "";
  },

  showManualError(reason) {
    if (!this._manualEl || !reason) return;
    if (this._manualError) {
      this._manualError.textContent = reason;
      this._manualError.hidden = false;
    }
    this._manualInput?.focus();
    this._manualInput?.select();
  },

  clearManualError() {
    if (this._manualError) {
      this._manualError.textContent = "";
      this._manualError.hidden = true;
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
        // Directly restore the prompt textarea value in the DOM since
        // phx-update="ignore" prevents the server from setting it during re-renders
        const promptEl = this.el.querySelector('[name="prompt"]');
        if (promptEl && state.task_prompt) {
          promptEl.value = state.task_prompt;
        }
      } catch (e) {}
    }

    // Listen for save requests from the server (still needed for task_mode changes, project switches, task starts)
    this.handleEvent("persist_state", (state) => {
      // The server no longer receives per-keystroke prompt updates (the
      // task_prompt_change phx-change event was removed), so its task_prompt
      // in the persist payload can be stale. The DOM is the source of truth
      // for the prompt — override it before persisting. (The client-side
      // input watcher below, persistFormState, is the prompt's persistence
      // path; this override protects it from stale server pushes triggered
      // by OTHER events, e.g. mode/model select changes.)
      state.task_prompt = this.el.querySelector('[name="prompt"]')?.value || '';
      sessionStorage.setItem('dashboard_state', JSON.stringify(state));
    });

    // Client-side form field watching — debounced persistence to sessionStorage
    let debounceTimer;
    const persistFormState = () => {
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        const project = this.el.dataset.project || '';
        const taskMode = this.el.dataset.taskMode || '';
        // Merge with existing state to preserve server-managed fields (e.g. foreign_repos)
        let existing = {};
        try { existing = JSON.parse(sessionStorage.getItem('dashboard_state') || '{}'); } catch (e) {}
        const state = Object.assign({}, existing, {
          project: project,
          task_mode: taskMode,
          node: this.el.dataset.nodeId || "local",
          task_prompt: this.el.querySelector('[name="prompt"]')?.value || '',
          task_node_path: this.el.querySelector('[name="node_path"]')?.value || '',
          task_seeds: this.el.querySelector('[name="seeds"]')?.value || '',
          task_starting_commit: this.el.querySelector('[name="starting_commit"]')?.value || '',
          selected_model_id: this.el.querySelector('[name="model_id"]')?.value || '',
        });
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

    // Watch select elements for change events (model_id, etc.)
    this.el.addEventListener('change', (e) => {
      const name = e.target.getAttribute('name');
      if (['model_id'].includes(name)) {
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
          // Push event so the LiveView shows a flash message
          this.pushEvent("copied", {});
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

// AgentHistoryAutoScroll hook: auto-scrolls chat history when user is at the bottom.
//
// Uses requestAnimationFrame to wait for browser layout before reading scrollHeight,
// and a custom rAF-based ease-out scroll animation instead of native smooth scrolling.
// Native smooth scroll is interrupted when scrollTo is called again mid-animation,
// causing stutter when messages arrive rapidly. The custom animation restarts cleanly
// from the current position to the latest target on every update.
//
// A `_isAnimating` flag suppresses the scroll listener while the programmatic
// animation runs. Each frame writes `el.scrollTop`, which fires a `scroll` event;
// mid-animation we're still partway down, so that event would otherwise flip
// `isAtBottom` to false and make the next message skip scrolling — getting stuck.
// Once the animation completes we re-affirm `isAtBottom = true`.
const AgentHistoryAutoScroll = {
  mounted() {
    this.isAtBottom = true;
    this._scheduleRAF = null;
    this._animRAF = null;
    this._isAnimating = false;

    // Scroll to bottom after initial layout completes
    requestAnimationFrame(() => {
      this.el.scrollTop = this.el.scrollHeight;
    });

    // Track whether user has scrolled away from bottom
    this.el.addEventListener("scroll", () => {
      if (this._isAnimating) return;  // ignore scroll events from our own animation
      this.isAtBottom =
        this.el.scrollTop + this.el.clientHeight >= this.el.scrollHeight - 30;
    }, { passive: true });
  },

  updated() {
    if (!this.isAtBottom) return;

    // Coalesce rapid same-frame updates: cancel any pending rAF and schedule
    // a fresh one. Only the last update in a burst triggers a scroll, and
    // it reads scrollHeight AFTER all DOM mutations from that burst are laid out.
    if (this._scheduleRAF !== null) {
      cancelAnimationFrame(this._scheduleRAF);
    }
    this._scheduleRAF = requestAnimationFrame(() => {
      this._scheduleRAF = null;
      this._smoothScrollTo(this.el.scrollHeight);
    });
  },

  // Custom smooth scroll using requestAnimationFrame + scrollTop.
  // Uses a short easeOutCubic curve (200ms). When called mid-animation
  // (rapid message arrivals), it cancels the current animation and restarts
  // from wherever we are to the new target — no jump, no stuck mid-way.
  _smoothScrollTo(target) {
    if (this._animRAF !== null) {
      cancelAnimationFrame(this._animRAF);
      this._animRAF = null;
    }

    this._isAnimating = true;

    const start = this.el.scrollTop;
    const distance = target - start;
    if (Math.abs(distance) < 1) {
      this._isAnimating = false;
      return;
    }

    const duration = 200; // ms — short enough to keep up with streaming, long enough to feel smooth
    const startTime = performance.now();

    const animate = (now) => {
      const elapsed = now - startTime;
      const progress = Math.min(elapsed / duration, 1);
      // easeOutCubic
      const eased = 1 - Math.pow(1 - progress, 3);
      this.el.scrollTop = start + distance * eased;

      if (progress < 1) {
        this._animRAF = requestAnimationFrame(animate);
      } else {
        this._animRAF = null;
        this._isAnimating = false;
        this.isAtBottom = true;
      }
    };

    this._animRAF = requestAnimationFrame(animate);
  },

  destroyed() {
    if (this._scheduleRAF !== null) {
      cancelAnimationFrame(this._scheduleRAF);
    }
    if (this._animRAF !== null) {
      cancelAnimationFrame(this._animRAF);
    }
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

// DesktopQuit hook: listens for the Tauri shell's "quit-requested" event
// (tray "Quit Genesis" item) and forwards it to the server as
// desktop_quit_requested, which opens the confirm dialog on whichever page is
// being viewed (the hook is mounted on a wrapper around the app layout's
// <main>, so it is re-established on every page navigation). A complete no-op
// outside the Tauri shell (normal browsers) since window.__TAURI__ is absent.
const DesktopQuit = {
  mounted() {
    // Same detection as TauriDetect (see above).
    const isTauri = !!(window.__TAURI__ || window.__TAURI_OS_INTERNALS__);
    if (!isTauri) {
      return;
    }
    this._unlisten = null;
    this._unlistenPromise = window.__TAURI__.event.listen("quit-requested", () => {
      this.pushEvent("desktop_quit_requested", {});
    });
    this._unlistenPromise.then((unlisten) => {
      // If the hook was destroyed before the promise resolved, unlisten right
      // away; otherwise keep the unlisten for destroyed().
      if (this._unlistenPromise) {
        this._unlisten = unlisten;
      } else {
        unlisten();
      }
    });
  },
  destroyed() {
    // Safe if the listen promise hasn't resolved yet: nulling _unlistenPromise
    // makes the then-callback unlisten immediately instead of storing.
    this._unlistenPromise = null;
    if (this._unlisten) {
      this._unlisten();
      this._unlisten = null;
    }
  }
};

// DesktopQuitConfirm hook: the desktop quit dialog's red Quit button. Invokes
// the Tauri `begin_quit` command first — the shell sets its
// intentional-shutdown flag so its watchdog won't restart the backend — and
// then pushes desktop_quit_confirmed to the server. A begin_quit failure must
// still proceed: the confirm event still needs to reach the server. Without
// Tauri (browser testing path) the event is pushed directly.
const DesktopQuitConfirm = {
  mounted() {
    this.el.addEventListener("click", (event) => {
      event.preventDefault();
      this.confirmQuit();
    });
  },
  async confirmQuit() {
    const isTauri = !!(window.__TAURI__ || window.__TAURI_OS_INTERNALS__);
    if (isTauri) {
      try {
        await window.__TAURI__.core.invoke("begin_quit");
      } catch (_error) {
        // Failure must still proceed — the server still needs the confirm.
      }
    }
    this.pushEvent("desktop_quit_confirmed", {});
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

// DialogModal hook: opens/closes <dialog class="modal"> elements in the
// browser's top layer, immune to parent CSS containing blocks (backdrop-filter,
// transform, etc.). Pushes "dialog_closed" when the dialog is dismissed via ESC
// or backdrop click so the server can sync state.
const DialogModal = {
  mounted() {
    this.el.showModal();
    this._onClose = () => this.pushEvent("dialog_closed", {});
    this.el.addEventListener("close", this._onClose);
  },
  destroyed() {
    if (this._onClose) {
      this.el.removeEventListener("close", this._onClose);
    }
    // If the dialog is still open when destroyed (e.g., server toggle while
    // modal is showing), close it so the top layer is released.
    if (this.el.open) {
      this.el.close();
    }
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
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, TauriDetect, DesktopQuit, DesktopQuitConfirm, PlatformDetect, PathAutocomplete, DirectoryPicker, FilePicker, StatePersistence, BrowserNotifications, AutoClearFlash, ClipboardCopy, AgentHistoryAutoScroll, DialogModal, SidebarCollapse, NodeSwitchFade, AdaptiveInput, LegendTooltip, FocusInput, PaletteList, DiffViewer},
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
